-- ============================================================
-- MIGRATION v8 → v9: CRM Automation Engine (outbound drain backend)
-- Campground OS — Multi-Tenant Guest Management & Revenue Intelligence
--
-- PURPOSE:
--   Build the SERVER-SIDE half of the CRM outbound automation layer so an
--   external orchestrator (N8N) can drain the webhook_events outbox into
--   GoHighLevel WITHOUT ever holding a secret, a table grant, or BYPASSRLS.
--
--     • webhook_events gains a claim/retry lifecycle (processing/skipped
--       statuses + next_attempt_at / locked_at / provider_contact_id /
--       error_class) and a claim hot-path index.
--     • Two NOLOGIN roles split the automation trust boundary:
--         crm_automation — N8N: EXECUTE claim/complete/requeue ONLY.
--         crm_resolver   — Edge Function: EXECUTE resolve/context ONLY.
--       Neither has table access or BYPASSRLS. Both granted to authenticator
--       so PostgREST can SET ROLE into them from a signed JWT.
--     • Four SECURITY DEFINER RPCs: claim_webhook_events, complete_webhook_event
--       (folds crm_contact_ids writeback + integration health, atomically),
--       requeue_webhook_event, get_crm_dispatch_context (non-secret routing).
--     • resolve_crm_secret (v8) gains an EXECUTE grant to crm_resolver.
--
-- LOCKED BLOCKERS IMPLEMENTED (Phase 3C):
--   B1 — status CHECK is widened by introspecting + dropping the existing
--        CHECK then re-adding (no in-place modify exists); rollback narrows
--        only AFTER backfilling non-original statuses.
--   B2 — crm_automation / crm_resolver granted TO authenticator + USAGE on
--        schema public (without this PostgREST cannot assume the role).
--   B3 — claim/complete/requeue derive org from the EVENT ROW, not the JWT,
--        so the EXECUTE grant is their ENTIRE security boundary. Each function
--        REVOKEs PUBLIC/anon/authenticated and grants exactly one role, in
--        THIS transaction. (Gate 0 verifies the negative case first.)
--   B4 — complete_webhook_event(outcome='sent') RAISES if contact_id is
--        null/blank — never writes a null crm_contact_ids value.
--   B5 — (Edge Function concern; this migration only supplies the non-secret
--        get_crm_dispatch_context so the Edge Function can derive routing
--        server-side instead of trusting body-supplied fields.)
--   B6 — claim auto-skips an event ONLY when the org has NO gohighlevel
--        integration row at all (existence, NOT status). An integration in
--        'error' keeps its events claimable so they resume after a fix.
--
-- ADOPTED RECOMMENDATIONS:
--   R1 private_token only (api_key/oauth2 deferred — enforced in the Edge
--      Function, not here). R2 get_crm_dispatch_context. R8 provider
--      Retry-After overrides backoff and is NOT capped by the 15m ceiling.
--
-- SAFETY CONTRACT:
--   • Additive only — no columns dropped, no rows deleted, no RLS redesign.
--   • Run as ONE transaction (explicit BEGIN/COMMIT) so there is never a
--     window where a function exists with its PUBLIC default grant still live.
--   • Roles are guarded (CREATE ROLE has no IF NOT EXISTS); columns use
--     ADD COLUMN IF NOT EXISTS; index uses IF NOT EXISTS; CHECK widening and
--     grants are idempotent (safe to re-run).
--
-- PRESERVES v7/v8 SECURITY MODEL:
--   • RPC-only writes; safe-view-only reads; secrets never browser-reachable.
--   • resolve_crm_secret body UNCHANGED (v9 only adds a grant).
--   • SECURITY DEFINER functions pin search_path = public.
--
-- DEPENDS ON (applied & verified):
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3 → migrate_v4
--   → migrate_v5 → migrate_v6 → migrate_v7 → migrate_v8
--
-- POST-COMMIT (operational, NOT part of this file):
--   • NOTIFY pgrst, 'reload schema';   (new RPCs 404 until PostgREST reloads)
--   • Mint crm_automation / crm_resolver JWTs (role + exp claims, HS256 with
--     the project JWT secret); store crm_resolver as a function secret, never
--     in code. Run Gate 0 BEFORE wiring any external component.
-- ============================================================

BEGIN;


-- ============================================================
-- STEP 0: Preconditions (self-guard) — fail fast, roll everything back
-- ============================================================

DO $precheck$
BEGIN
  IF to_regprocedure('public.resolve_crm_secret(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'v9 precondition failed: public.resolve_crm_secret(uuid) not found — apply migrate_v8 first';
  END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION
      'v9 precondition failed: vault.decrypted_secrets not found — supabase_vault / v8 missing';
  END IF;
  IF to_regclass('public.crm_integrations') IS NULL THEN
    RAISE EXCEPTION
      'v9 precondition failed: public.crm_integrations not found — apply migrate_v5 first';
  END IF;
END
$precheck$;


-- ============================================================
-- STEP 1: webhook_events claim/retry lifecycle (additive)
--
--   next_attempt_at     — backoff gate; NULL = claimable now (new events).
--   locked_at           — claim timestamp; backs the 5-min stale reaper.
--   provider_contact_id — audit of the GHL id a successful sync produced.
--   error_class         — machine-readable failure class (≠ human last_error).
--   (retry_count / last_error / processed_at already exist from v2.)
-- ============================================================

ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS next_attempt_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS locked_at           TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS provider_contact_id TEXT,
  ADD COLUMN IF NOT EXISTS error_class         TEXT;

COMMENT ON COLUMN public.webhook_events.next_attempt_at IS
  'Backoff gate for the N8N drain. NULL = eligible immediately. Set by complete_webhook_event on retry.';
COMMENT ON COLUMN public.webhook_events.locked_at IS
  'When claim_webhook_events moved the event to status=processing. Stale (>5 min) rows are reclaimed.';
COMMENT ON COLUMN public.webhook_events.provider_contact_id IS
  'CRM contact id produced by the successful sync (audit trail). Mirrors guest_org_profiles.crm_contact_ids.';
COMMENT ON COLUMN public.webhook_events.error_class IS
  'Machine-readable failure class: auth | forbidden | validation | rate_limit | transient | timeout | '
  'no_secret | no_integration | unsupported_event_type | max_attempts. Distinct from human-readable last_error.';

-- ── B1: widen the status CHECK ────────────────────────────────
-- A CHECK cannot be modified in place. Drop whatever CHECK currently
-- constrains webhook_events.status (name is system-generated), then add the
-- widened one under a stable, known name. Idempotent across re-runs.
DO $widen_status$
DECLARE
  v_conname TEXT;
BEGIN
  FOR v_conname IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'public.webhook_events'::regclass
      AND con.contype  = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.webhook_events DROP CONSTRAINT %I', v_conname);
  END LOOP;

  ALTER TABLE public.webhook_events
    ADD CONSTRAINT webhook_events_status_check
    CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'skipped'));
END
$widen_status$;

-- Claim hot-path index. Partial: only the rows the drain ever scans.
CREATE INDEX IF NOT EXISTS idx_webhook_events_claimable
  ON public.webhook_events (status, next_attempt_at)
  WHERE status IN ('pending', 'processing');


-- ============================================================
-- STEP 2: Automation roles (B2)
--
-- Two NOLOGIN roles split the trust boundary. Both are granted to
-- authenticator so PostgREST can SET ROLE into them from a signed JWT
-- (role claim). Neither gets table grants or BYPASSRLS — the SECURITY
-- DEFINER RPCs do all privileged work internally.
-- ============================================================

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_automation') THEN
    CREATE ROLE crm_automation NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_resolver') THEN
    CREATE ROLE crm_resolver NOLOGIN;
  END IF;
END
$roles$;

-- Without USAGE, EXECUTE on the functions is denied even with the grant.
GRANT USAGE ON SCHEMA public TO crm_automation, crm_resolver;

-- B2: PostgREST cannot assume a role it (authenticator) is not a member of.
GRANT crm_automation TO authenticator;
GRANT crm_resolver   TO authenticator;

COMMENT ON ROLE crm_automation IS
  'N8N drain identity. EXECUTE on claim/complete/requeue ONLY. No secret access, no table grants, no BYPASSRLS.';
COMMENT ON ROLE crm_resolver IS
  'crm-sync-dispatch Edge Function identity. EXECUTE on resolve_crm_secret + get_crm_dispatch_context ONLY.';


-- ============================================================
-- STEP 3: get_crm_dispatch_context() — NON-SECRET routing (R2 / B5)
--
-- Lets the Edge Function derive provider/account/auth_type/tags from the DB
-- by integration id, so it never trusts body-supplied routing fields. Returns
-- NO secret. EXECUTE to crm_resolver only.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_crm_dispatch_context(p_integration_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $get_ctx$
DECLARE
  v_ctx JSONB;
BEGIN
  SELECT jsonb_build_object(
    'provider',            ci.provider,
    'external_account_id', ci.external_account_id,
    'auth_type',           ci.auth_type,
    'status',              ci.status,
    'tag_prefix',          COALESCE(ci.config->>'tag_prefix', ''),
    'field_mappings',      COALESCE(ci.config->'field_mappings', '{}'::jsonb)
  )
  INTO v_ctx
  FROM public.crm_integrations ci
  WHERE ci.id = p_integration_id;

  RETURN v_ctx;   -- NULL when the integration id does not exist
END;
$get_ctx$;

COMMENT ON FUNCTION public.get_crm_dispatch_context(UUID) IS
  'Non-secret CRM routing context (provider, external_account_id, auth_type, status, tag_prefix, '
  'field_mappings) for the crm-sync-dispatch Edge Function. Returns NO secret. crm_resolver EXECUTE only.';

REVOKE ALL ON FUNCTION public.get_crm_dispatch_context(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_crm_dispatch_context(UUID) TO crm_resolver;


-- ============================================================
-- STEP 4: claim_webhook_events() — atomic batch claim (B6)
--
-- SECURITY DEFINER (owner postgres → bypasses RLS, no caller table grant).
-- 1) Sweep terminal auto-skips (idempotent, cheap on the partial index):
--      • unsupported event_type            → skipped / unsupported_event_type
--      • org has NO gohighlevel row at all  → skipped / no_integration  (B6)
-- 2) Claim the actionable batch with FOR UPDATE SKIP LOCKED, flip to
--    processing, stamp locked_at, return self-contained rows (+ integration_id).
--
-- B6: the no-integration skip checks EXISTENCE only — an integration in
-- 'error' (e.g. bad token) is NOT skipped, so its events keep retrying and
-- resume after the owner rotates the credential.
-- ============================================================

CREATE OR REPLACE FUNCTION public.claim_webhook_events(p_limit INT DEFAULT 25)
RETURNS TABLE (
  event_id        UUID,
  event_type      TEXT,
  organization_id UUID,
  property_id     UUID,
  integration_id  UUID,
  retry_count     INT,
  payload         JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $claim$
BEGIN
  -- ── Auto-skip 1: event types we do not sync (forward-safe; no-op today) ──
  UPDATE public.webhook_events we
     SET status       = 'skipped',
         error_class  = 'unsupported_event_type',
         processed_at = now()
   WHERE we.status = 'pending'
     AND we.event_type NOT IN (
       'reservation.created', 'reservation.checked_in', 'reservation.checked_out',
       'reservation.cancelled', 'reservation.no_show'
     );

  -- ── Auto-skip 2: org has NO gohighlevel integration row at all (B6) ──
  UPDATE public.webhook_events we
     SET status       = 'skipped',
         error_class  = 'no_integration',
         processed_at = now()
   WHERE we.status = 'pending'
     AND NOT EXISTS (
       SELECT 1 FROM public.crm_integrations ci
       WHERE ci.organization_id = we.organization_id
         AND ci.provider = 'gohighlevel'
     );

  -- ── Claim the actionable batch ──
  RETURN QUERY
  UPDATE public.webhook_events
     SET status    = 'processing',
         locked_at = now()
   WHERE id IN (
     SELECT we.id
     FROM public.webhook_events we
     WHERE (
             (we.status = 'pending'
              AND (we.next_attempt_at IS NULL OR we.next_attempt_at <= now()))
             OR
             (we.status = 'processing'
              AND we.locked_at < now() - INTERVAL '5 minutes')
           )
       AND we.event_type IN (
         'reservation.created', 'reservation.checked_in', 'reservation.checked_out',
         'reservation.cancelled', 'reservation.no_show'
       )
       AND EXISTS (
         SELECT 1 FROM public.crm_integrations ci
         WHERE ci.organization_id = we.organization_id
           AND ci.provider = 'gohighlevel'
       )
     ORDER BY we.created_at ASC
     LIMIT GREATEST(p_limit, 0)
     FOR UPDATE SKIP LOCKED
   )
  RETURNING
    webhook_events.id,
    webhook_events.event_type,
    webhook_events.organization_id,
    webhook_events.property_id,
    ( SELECT ci.id
      FROM public.crm_integrations ci
      WHERE ci.organization_id = webhook_events.organization_id
        AND ci.provider = 'gohighlevel'
      LIMIT 1 ),
    webhook_events.retry_count,
    webhook_events.payload;
END;
$claim$;

COMMENT ON FUNCTION public.claim_webhook_events(INT) IS
  'Atomic outbox claim for the N8N drain. Auto-skips unsupported types and orgs with no gohighlevel '
  'integration (existence only — B6). Claims actionable events (FOR UPDATE SKIP LOCKED), flips to '
  'processing, returns self-contained rows + integration_id. crm_automation EXECUTE only. '
  'Org is derived from the event row, not the JWT — the EXECUTE grant is the security boundary (B3).';

REVOKE ALL ON FUNCTION public.claim_webhook_events(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_webhook_events(INT) TO crm_automation;


-- ============================================================
-- STEP 5: complete_webhook_event() — terminal state writer
--
-- The SOLE writer of the event terminal state; folds crm_contact_ids
-- writeback + integration health into ONE transaction. SECURITY DEFINER.
--
--   • Idempotency: acts only on status='processing'; otherwise no-op.
--   • B4: outcome='sent' RAISES on null/blank contact_id (no null writeback).
--   • Writeback is a single UPDATE → row-atomic JSONB merge (no lost update).
--   • Retry uses exponential backoff (cap 15m) + jitter; provider Retry-After
--     OVERRIDES and is NOT capped (R8). Dead-letters at p_max_attempts.
--   • Definitive credential failure (auth/forbidden) marks integration health;
--     transient failures never do (anti-flap).
-- ============================================================

CREATE OR REPLACE FUNCTION public.complete_webhook_event(
  p_event_id            UUID,
  p_integration_id      UUID,
  p_outcome             TEXT,
  p_contact_id          TEXT DEFAULT NULL,
  p_error_class         TEXT DEFAULT NULL,
  p_error_message       TEXT DEFAULT NULL,
  p_max_attempts        INT  DEFAULT 5,
  p_retry_after_seconds INT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $complete$
DECLARE
  v_event           public.webhook_events%ROWTYPE;
  v_guest_id        UUID;
  v_org_id          UUID;
  v_integration_org UUID;
  v_attempt         INT;
  v_backoff         INT;
  v_delay           INT;
  v_next            TIMESTAMPTZ;
  v_final           TEXT;
BEGIN
  IF p_outcome NOT IN ('sent', 'retry', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'complete_webhook_event: invalid outcome %', COALESCE(p_outcome, 'null');
  END IF;

  SELECT * INTO v_event
  FROM public.webhook_events
  WHERE id = p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'complete_webhook_event: event % not found', p_event_id;
  END IF;

  -- Idempotency guard — only in-flight events are completable.
  IF v_event.status IS DISTINCT FROM 'processing' THEN
    RETURN jsonb_build_object(
      'event_id',        p_event_id,
      'final_status',    v_event.status,
      'already_terminal', true
    );
  END IF;

  v_org_id := v_event.organization_id;

  -- F6: a caller-supplied integration MUST belong to the event's organization.
  -- This is the only place the function would otherwise trust a caller-supplied
  -- id; validating it up front prevents a cross-tenant integration-health write
  -- (e.g. flipping another tenant's CRM to status='error'). A mismatch aborts
  -- the whole call before any crm_integrations row is touched.
  IF p_integration_id IS NOT NULL THEN
    SELECT organization_id INTO v_integration_org
    FROM public.crm_integrations
    WHERE id = p_integration_id;

    IF v_integration_org IS NULL OR v_integration_org IS DISTINCT FROM v_org_id THEN
      RAISE EXCEPTION
        'complete_webhook_event: integration % does not belong to the event''s organization '
        '(cross-tenant write rejected, event %)', p_integration_id, p_event_id
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ── SENT ──────────────────────────────────────────────────
  IF p_outcome = 'sent' THEN
    -- B4: a success MUST carry a usable contact id.
    IF p_contact_id IS NULL OR length(btrim(p_contact_id)) = 0 THEN
      RAISE EXCEPTION
        'complete_webhook_event: outcome=sent requires a non-empty contact_id (event %)', p_event_id;
    END IF;

    v_guest_id := NULLIF(v_event.payload->'guest'->>'id', '')::UUID;

    -- Writeback (single statement → row-atomic merge, preserves other providers).
    IF v_guest_id IS NOT NULL AND v_org_id IS NOT NULL THEN
      UPDATE public.guest_org_profiles
         SET crm_contact_ids = crm_contact_ids || jsonb_build_object('gohighlevel', p_contact_id),
             crm_synced_at   = now()
       WHERE guest_id        = v_guest_id
         AND organization_id = v_org_id
         AND deleted_at IS NULL;
    END IF;

    -- Integration health: success heals error → active, records the sync time.
    IF p_integration_id IS NOT NULL THEN
      UPDATE public.crm_integrations
         SET last_sync_at  = now(),
             last_error    = NULL,
             last_error_at = NULL,
             status        = CASE WHEN status = 'error' THEN 'active' ELSE status END,
             updated_at    = now()
       WHERE id = p_integration_id;
    END IF;

    UPDATE public.webhook_events
       SET status              = 'sent',
           processed_at        = now(),
           provider_contact_id = p_contact_id,
           next_attempt_at     = NULL,
           locked_at           = NULL,
           last_error          = NULL,
           error_class         = NULL
     WHERE id = p_event_id;

    v_final := 'sent';

  -- ── RETRY (with dead-letter promotion) ────────────────────
  ELSIF p_outcome = 'retry' THEN
    v_attempt := COALESCE(v_event.retry_count, 0) + 1;

    IF v_attempt >= p_max_attempts THEN
      UPDATE public.webhook_events
         SET status          = 'failed',
             retry_count     = v_attempt,
             processed_at    = now(),
             next_attempt_at = NULL,
             locked_at       = NULL,
             last_error      = p_error_message,
             error_class     = COALESCE(p_error_class, 'max_attempts')
       WHERE id = p_event_id;
      v_final := 'failed';
    ELSE
      -- Exponential backoff capped at 15m; provider Retry-After overrides (uncapped, R8).
      v_backoff := LEAST((30 * power(2, COALESCE(v_event.retry_count, 0)))::INT, 900);
      v_delay   := GREATEST(v_backoff, COALESCE(p_retry_after_seconds, 0));
      v_next    := now()
                   + make_interval(secs => v_delay)
                   + make_interval(secs => floor(random() * 5)::INT);

      UPDATE public.webhook_events
         SET status          = 'pending',
             retry_count     = v_attempt,
             next_attempt_at = v_next,
             locked_at       = NULL,
             last_error      = p_error_message,
             error_class     = p_error_class
       WHERE id = p_event_id;
      v_final := 'pending';
    END IF;

  -- ── FAILED (terminal) ─────────────────────────────────────
  ELSIF p_outcome = 'failed' THEN
    UPDATE public.webhook_events
       SET status          = 'failed',
           processed_at    = now(),
           next_attempt_at = NULL,
           locked_at       = NULL,
           last_error      = p_error_message,
           error_class     = p_error_class
     WHERE id = p_event_id;

    -- Anti-flap: only definitive credential failures touch integration health.
    IF p_integration_id IS NOT NULL AND p_error_class IN ('auth', 'forbidden') THEN
      UPDATE public.crm_integrations
         SET status        = 'error',
             last_error    = p_error_message,
             last_error_at = now(),
             updated_at    = now()
       WHERE id = p_integration_id;
    END IF;

    v_final := 'failed';

  -- ── SKIPPED (terminal) ────────────────────────────────────
  ELSE
    UPDATE public.webhook_events
       SET status          = 'skipped',
           processed_at    = now(),
           next_attempt_at = NULL,
           locked_at       = NULL,
           error_class     = COALESCE(p_error_class, 'skipped'),
           last_error      = p_error_message
     WHERE id = p_event_id;
    v_final := 'skipped';
  END IF;

  SELECT retry_count, next_attempt_at
    INTO v_attempt, v_next
  FROM public.webhook_events
  WHERE id = p_event_id;

  RETURN jsonb_build_object(
    'event_id',        p_event_id,
    'final_status',    v_final,
    'retry_count',     v_attempt,
    'next_attempt_at', v_next
  );
END;
$complete$;

COMMENT ON FUNCTION public.complete_webhook_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INT, INT) IS
  'Terminal state writer for the N8N drain. Idempotent (acts only on processing). outcome=sent folds '
  'crm_contact_ids writeback + integration health atomically and RAISES on empty contact_id (B4). '
  'retry applies capped exponential backoff + jitter (Retry-After overrides, uncapped — R8) and '
  'dead-letters at p_max_attempts. auth/forbidden failures mark integration status=error (anti-flap). '
  'crm_automation EXECUTE only — org derived from the event row, not the JWT (B3).';

REVOKE ALL ON FUNCTION public.complete_webhook_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INT, INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_webhook_event(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INT, INT)
  TO crm_automation;


-- ============================================================
-- STEP 6: requeue_webhook_event() — dead-letter recovery
--
-- Moves a terminal (failed/skipped) event back to pending for a fresh drain.
-- SECURITY DEFINER; crm_automation / ops only.
-- ============================================================

CREATE OR REPLACE FUNCTION public.requeue_webhook_event(p_event_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $requeue$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status
  FROM public.webhook_events
  WHERE id = p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'requeue_webhook_event: event % not found', p_event_id;
  END IF;

  IF v_status NOT IN ('failed', 'skipped') THEN
    RETURN jsonb_build_object(
      'event_id', p_event_id,
      'requeued', false,
      'reason',   'not_in_terminal_state',
      'status',   v_status
    );
  END IF;

  UPDATE public.webhook_events
     SET status          = 'pending',
         retry_count     = 0,
         next_attempt_at = now(),
         locked_at       = NULL,
         error_class     = NULL,
         last_error      = NULL,
         processed_at    = NULL
   WHERE id = p_event_id;

  RETURN jsonb_build_object('event_id', p_event_id, 'requeued', true);
END;
$requeue$;

COMMENT ON FUNCTION public.requeue_webhook_event(UUID) IS
  'Dead-letter recovery: moves a failed/skipped event back to pending (retry_count reset). '
  'crm_automation / ops EXECUTE only.';

REVOKE ALL ON FUNCTION public.requeue_webhook_event(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_webhook_event(UUID) TO crm_automation;


-- ============================================================
-- STEP 7: resolve_crm_secret() — extend EXECUTE to crm_resolver
--
-- v8 granted EXECUTE to service_role only. v9 adds crm_resolver (the Edge
-- Function identity) so the secret-bearing dispatch never runs as service_role.
-- The function body is UNCHANGED. crm_automation is deliberately NOT granted —
-- N8N must never be able to resolve a secret.
-- ============================================================

GRANT EXECUTE ON FUNCTION public.resolve_crm_secret(UUID) TO crm_resolver;


COMMIT;


-- ============================================================
-- VERIFICATION — Gates 0–2 (commented; run AFTER COMMIT + pgrst reload)
-- ============================================================

/*
-- ── GATE 0 — B3 EXECUTE boundary (run FIRST, before any external wiring) ──
-- The entire security model for claim/complete/requeue is the EXECUTE grant.
SELECT
  has_function_privilege('anon',          'public.claim_webhook_events(integer)','EXECUTE')                                              AS anon_claim,
  has_function_privilege('authenticated', 'public.claim_webhook_events(integer)','EXECUTE')                                              AS auth_claim,
  has_function_privilege('anon',          'public.complete_webhook_event(uuid,uuid,text,text,text,text,integer,integer)','EXECUTE')      AS anon_complete,
  has_function_privilege('authenticated', 'public.complete_webhook_event(uuid,uuid,text,text,text,text,integer,integer)','EXECUTE')      AS auth_complete,
  has_function_privilege('anon',          'public.requeue_webhook_event(uuid)','EXECUTE')                                                AS anon_requeue,
  has_function_privilege('authenticated', 'public.requeue_webhook_event(uuid)','EXECUTE')                                                AS auth_requeue,
  has_function_privilege('anon',          'public.get_crm_dispatch_context(uuid)','EXECUTE')                                             AS anon_ctx,
  has_function_privilege('authenticated', 'public.get_crm_dispatch_context(uuid)','EXECUTE')                                             AS auth_ctx,
  has_function_privilege('anon',          'public.resolve_crm_secret(uuid)','EXECUTE')                                                   AS anon_resolve,
  has_function_privilege('authenticated', 'public.resolve_crm_secret(uuid)','EXECUTE')                                                   AS auth_resolve;
-- Expected: ALL false.

-- crm_automation (N8N) must NOT be able to resolve secrets or read routing:
SELECT
  has_function_privilege('crm_automation','public.resolve_crm_secret(uuid)','EXECUTE')        AS automation_resolve,   -- false
  has_function_privilege('crm_automation','public.get_crm_dispatch_context(uuid)','EXECUTE')  AS automation_ctx,       -- false
  has_function_privilege('crm_automation','public.claim_webhook_events(integer)','EXECUTE')   AS automation_claim;     -- true
-- crm_resolver (Edge) must have resolve + context, NOT the drain RPCs:
SELECT
  has_function_privilege('crm_resolver','public.resolve_crm_secret(uuid)','EXECUTE')          AS resolver_resolve,     -- true
  has_function_privilege('crm_resolver','public.get_crm_dispatch_context(uuid)','EXECUTE')    AS resolver_ctx,         -- true
  has_function_privilege('crm_resolver','public.complete_webhook_event(uuid,uuid,text,text,text,text,integer,integer)','EXECUTE') AS resolver_complete; -- false


-- ── GATE 1 — Migration objects present ──
-- 1a. New columns
SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='webhook_events'
  AND column_name IN ('next_attempt_at','locked_at','provider_contact_id','error_class')
ORDER BY column_name;
-- Expected: all 4.

-- 1b. Widened CHECK
SELECT pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conrelid='public.webhook_events'::regclass AND contype='c'
  AND pg_get_constraintdef(oid) ILIKE '%status%';
-- Expected: CHECK (status = ANY (ARRAY['pending','processing','sent','failed','skipped']))

-- 1c. Claim index
SELECT indexname FROM pg_indexes
WHERE schemaname='public' AND indexname='idx_webhook_events_claimable';
-- Expected: 1 row.

-- 1d. Roles exist, NOLOGIN, no BYPASSRLS
SELECT rolname, rolcanlogin, rolbypassrls FROM pg_roles
WHERE rolname IN ('crm_automation','crm_resolver') ORDER BY rolname;
-- Expected: both rolcanlogin=false, rolbypassrls=false.


-- ── GATE 2 — Role assumption wiring ──
-- 2a. authenticator membership (B2)
SELECT r.rolname AS role, g.rolname AS member_of
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.member
JOIN pg_roles g ON g.oid = am.roleid
WHERE r.rolname IN ('crm_automation','crm_resolver');
-- Expected: both rows member_of = authenticator.

-- 2b. schema USAGE
SELECT has_schema_privilege('crm_automation','public','USAGE') AS automation_usage,
       has_schema_privilege('crm_resolver','public','USAGE')   AS resolver_usage;
-- Expected: both true.

-- 2c. Live role-assumption smoke test (impersonation; wraps in ROLLBACK)
-- BEGIN;
--   SET LOCAL ROLE crm_automation;
--   SELECT * FROM public.claim_webhook_events(1);            -- PASS: returns 0+ rows, no permission error
--   -- SELECT public.resolve_crm_secret(gen_random_uuid());  -- PASS: ERROR permission denied for function
-- ROLLBACK;
-- BEGIN;
--   SET LOCAL ROLE crm_resolver;
--   SELECT public.get_crm_dispatch_context(gen_random_uuid()); -- PASS: returns NULL, no permission error
--   -- SELECT public.claim_webhook_events(1);                  -- PASS: ERROR permission denied for function
-- ROLLBACK;
*/


-- ============================================================
-- ROLLBACK (manual — additive migration, low risk; run in ORDER)
--
-- 0. (Operational) Disable the N8N drain schedule first.
-- 1. UPDATE public.webhook_events SET status='pending', locked_at=NULL WHERE status='processing';
-- 2. UPDATE public.webhook_events SET status='failed'  WHERE status='skipped';   -- pre-narrow backfill
-- 3. Narrow the CHECK back (introspect → drop → add), e.g.:
--      DO $$ DECLARE c TEXT; BEGIN
--        FOR c IN SELECT conname FROM pg_constraint
--                 WHERE conrelid='public.webhook_events'::regclass AND contype='c'
--                   AND pg_get_constraintdef(oid) ILIKE '%status%'
--        LOOP EXECUTE format('ALTER TABLE public.webhook_events DROP CONSTRAINT %I', c); END LOOP;
--        ALTER TABLE public.webhook_events ADD CONSTRAINT webhook_events_status_check
--          CHECK (status IN ('pending','sent','failed'));
--      END $$;
-- 4. DROP FUNCTION public.claim_webhook_events(INT);
--    DROP FUNCTION public.complete_webhook_event(UUID,UUID,TEXT,TEXT,TEXT,TEXT,INT,INT);
--    DROP FUNCTION public.requeue_webhook_event(UUID);
--    DROP FUNCTION public.get_crm_dispatch_context(UUID);
-- 5. Detach the roles before dropping them. DROP ROLE fails while ANY privilege
--    still references the role. Step 4 dropped the four v9 functions (and with
--    them crm_automation's EXECUTE), but resolve_crm_secret is a RETAINED v8
--    function — crm_resolver's EXECUTE on it, plus the schema USAGE held by both
--    roles, must be revoked explicitly first:
--      REVOKE EXECUTE ON FUNCTION public.resolve_crm_secret(uuid) FROM crm_resolver;
--      REVOKE USAGE ON SCHEMA public FROM crm_automation, crm_resolver;
--      REVOKE crm_automation, crm_resolver FROM authenticator;
--      DROP ROLE crm_automation;  DROP ROLE crm_resolver;
-- 6. The 4 webhook_events columns may be LEFT in place (harmless defaults).
-- 7. NOTIFY pgrst, 'reload schema';
-- Already-written crm_contact_ids / crm_synced_at / last_sync_at stay (correct). Vault untouched.
-- No RLS flip anywhere → rollback cannot lock users out.
-- ============================================================
