-- ============================================================
-- MIGRATION v7 → v8: CRM Secure Credential Foundation
-- Campground OS — Multi-Tenant Guest Management & Revenue Intelligence
--
-- PURPOSE:
--   Make CRM secret storage breach-resistant and give owners a safe
--   write path, WITHOUT exposing any secret to the browser.
--     • Secrets move to Supabase Vault (vault.secrets); crm_integrations
--       holds only a non-secret credential_ref (vault id + masked metadata).
--     • upsert_crm_integration() owner-only SECURITY DEFINER RPC becomes
--       the SOLE secret-write path; direct base-table writes are revoked.
--     • resolve_crm_secret() SECURITY DEFINER resolver lets service_role /
--       N8N read the plaintext SERVER-SIDE over PostgREST rpc/ — the vault
--       schema is never REST-exposed.
--     • Adds auth_type, audit (connected_at/by) and sync-health columns.
--
-- VERIFIED VAULT EVIDENCE (live DB — supersedes all earlier assumptions):
--   • supabase_vault 0.3.1 installed; schema `vault` present
--   • vault.secrets and vault.decrypted_secrets exist
--   • vault.create_secret(new_secret text, new_name text,
--                          new_description text, new_key_id uuid) → uuid
--   • vault.update_secret(secret_id uuid, new_secret text,
--                         new_name text, new_description text,
--                         new_key_id uuid) → void
--   • service_role: schema usage + secrets_select + decrypted_select = TRUE
--   • authenticated / anon: NO vault access
--   v8 relies on the DEFAULT encryption key (new_key_id => NULL) and never
--   manages key_id itself.
--
-- SAFETY CONTRACT:
--   • Additive only — no columns dropped, no rows deleted, no RLS redesign.
--   • Every ALTER uses ADD COLUMN IF NOT EXISTS; constraints/FKs added via
--     guarded DO blocks; CREATE OR REPLACE for functions/views; GRANT/REVOKE
--     are idempotent.
--   • The legacy `credentials` column is RETAINED (deprecated) so N8N keeps
--     a dual-read fallback until cutover — guarantees no data loss and a
--     clean rollback.
--   • Run the WHOLE file as ONE transaction (explicit BEGIN/COMMIT below)
--     so there is never a window where the write grant is revoked but the
--     RPC is absent.
--
-- PRESERVES v7 SECURITY MODEL:
--   • RPC-only writes (mirrors upsert_guest / create_reservation).
--   • Safe-view-only reads (crm_integrations_safe still excludes credentials).
--   • Owner-only CRM management (matches the frozen permission matrix).
--   • JWT-derived org/role/user — never trusts caller-supplied ids.
--   • Function EXECUTE locked down (REVOKE FROM PUBLIC/anon; explicit grants).
--
-- DEPENDS ON:
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3 → migrate_v4
--   → migrate_v5 → migrate_v6 → migrate_v7  (and the v6 handle_new_reservation
--   body + the v4 JWT hook live and verified).
-- ============================================================

BEGIN;


-- ============================================================
-- STEP 0: Preconditions (self-guard)
--
-- Fail fast and roll the whole transaction back if Vault is not
-- present with the verified 4-arg signature. This protects against
-- running v8 against a project where supabase_vault is disabled.
-- ============================================================

DO $precheck$
BEGIN
  IF to_regprocedure('vault.create_secret(text, text, text, uuid)') IS NULL THEN
    RAISE EXCEPTION
      'v8 precondition failed: vault.create_secret(text,text,text,uuid) not found — enable supabase_vault first';
  END IF;
  IF to_regprocedure('vault.update_secret(uuid, text, text, text, uuid)') IS NULL THEN
    RAISE EXCEPTION
      'v8 precondition failed: vault.update_secret(uuid,text,text,text,uuid) not found';
  END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION
      'v8 precondition failed: vault.decrypted_secrets view not found';
  END IF;
END
$precheck$;


-- ============================================================
-- STEP 1: Additive columns on crm_integrations
--
--   auth_type       — explicit GHL auth model (OAuth-ready).
--   credential_ref  — NON-SECRET Vault pointer + masked metadata:
--                     { vault_secret_id, token_type, last4, expires_at }.
--                     NEVER holds plaintext; safe to surface in the view.
--   connected_at /
--   connected_by    — audit: when / who established the credential.
--   last_error /
--   last_error_at   — give status='error' real meaning (sync health).
--   sync_cursor     — N8N drain position.
-- ============================================================

ALTER TABLE public.crm_integrations
  ADD COLUMN IF NOT EXISTS auth_type      TEXT        NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS credential_ref JSONB       NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS connected_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS connected_by   UUID,
  ADD COLUMN IF NOT EXISTS last_error     TEXT,
  ADD COLUMN IF NOT EXISTS last_error_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sync_cursor    JSONB       NOT NULL DEFAULT '{}';

-- auth_type CHECK (guarded — ADD CONSTRAINT has no IF NOT EXISTS)
DO $auth_type_chk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'crm_integrations_auth_type_check'
      AND conrelid = 'public.crm_integrations'::regclass
  ) THEN
    ALTER TABLE public.crm_integrations
      ADD CONSTRAINT crm_integrations_auth_type_check
      CHECK (auth_type IN ('api_key', 'private_token', 'oauth2', 'none'));
  END IF;
END
$auth_type_chk$;

-- connected_by FK → users(id) (guarded; ON DELETE SET NULL preserves audit row)
DO $connected_by_fk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'crm_integrations_connected_by_fkey'
      AND conrelid = 'public.crm_integrations'::regclass
  ) THEN
    ALTER TABLE public.crm_integrations
      ADD CONSTRAINT crm_integrations_connected_by_fkey
      FOREIGN KEY (connected_by) REFERENCES public.users(id) ON DELETE SET NULL;
  END IF;
END
$connected_by_fk$;

COMMENT ON COLUMN public.crm_integrations.auth_type IS
  'CRM auth model: api_key | private_token | oauth2 | none. Drives RPC + N8N branching.';
COMMENT ON COLUMN public.crm_integrations.credential_ref IS
  'NON-SECRET Vault reference + masked metadata: { vault_secret_id, token_type, last4, expires_at }. '
  'NEVER contains plaintext. Safe to expose via crm_integrations_safe. '
  'The actual secret lives in vault.secrets and is readable only server-side (service_role / definer).';
COMMENT ON COLUMN public.crm_integrations.connected_at IS 'Audit: when the current credential was established/rotated.';
COMMENT ON COLUMN public.crm_integrations.connected_by IS 'Audit: public.users.id of the owner who connected/rotated the credential.';
COMMENT ON COLUMN public.crm_integrations.last_error IS 'Last sync error message (backs status=error). Written by N8N (service_role).';
COMMENT ON COLUMN public.crm_integrations.last_error_at IS 'Timestamp of last_error.';
COMMENT ON COLUMN public.crm_integrations.sync_cursor IS 'N8N drain position / provider sync cursor (non-secret).';

-- Deprecate the legacy plaintext column (RETAINED for dual-read transition).
COMMENT ON COLUMN public.crm_integrations.credentials IS
  'DEPRECATED as of migrate_v8. Secrets now live in Supabase Vault; crm_integrations '
  'references them via credential_ref. RETAINED (not dropped) as a dual-read fallback for '
  'N8N during transition. Stops being a write target (RPC writes Vault). Drop in a future '
  'cleanup migration only after v8 verification passes in all environments.';


-- ============================================================
-- STEP 2: Config normalization (N8N-first naming) — additive
--
-- Copy legacy Make.com key into the N8N-first key where absent.
-- The old key is NOT deleted (additive; safe to re-run).
-- ============================================================

UPDATE public.crm_integrations
   SET config = jsonb_set(config, '{n8n_inbound_url}', config->'make_incoming_url', true)
 WHERE config ? 'make_incoming_url'
   AND NOT (config ? 'n8n_inbound_url');

COMMENT ON COLUMN public.crm_integrations.config IS
  'Non-secret provider configuration (safe for owner/manager reads). N8N-first canonical keys: '
  'n8n_inbound_url, n8n_webhook_secret_ref (a Vault ref id, NEVER an inline secret), '
  'pipeline_id, calendar_id, field_mappings, tag_prefix. Legacy make_incoming_url retained during transition.';


-- ============================================================
-- STEP 3: Backfill existing plaintext credentials → Vault
--
-- Runs as postgres (has Vault access). For each row with a real
-- secret and no vault_secret_id yet: create a Vault secret under the
-- DEFAULT key (new_key_id => NULL), then record the non-secret
-- credential_ref. Idempotent: guarded on credential_ref->>'vault_secret_id'
-- IS NULL, so re-runs are no-ops. The deterministic Vault name embeds
-- the integration id, so it is unique and traceable.
--
-- `credentials` is LEFT POPULATED (dual-read fallback for N8N).
-- ============================================================

DO $backfill$
DECLARE
  r            RECORD;
  v_secret     TEXT;
  v_token_type TEXT;
  v_vault_id   UUID;
BEGIN
  FOR r IN
    SELECT id, organization_id, provider, credentials
    FROM public.crm_integrations
    WHERE (credential_ref->>'vault_secret_id') IS NULL
      AND credentials IS NOT NULL
      AND (credentials ? 'api_key' OR credentials ? 'make_webhook_secret')
  LOOP
    -- Prefer an API key; otherwise migrate the webhook signing secret.
    IF r.credentials ? 'api_key' THEN
      v_secret     := r.credentials->>'api_key';
      v_token_type := 'api_key';
    ELSE
      v_secret     := r.credentials->>'make_webhook_secret';
      v_token_type := 'webhook_secret';
    END IF;

    IF v_secret IS NULL OR length(v_secret) = 0 THEN
      CONTINUE;
    END IF;

    v_vault_id := vault.create_secret(
      v_secret,
      'crm/' || r.organization_id::text || '/' || r.provider || '/' || r.id::text,
      'Campground OS CRM secret (v8 backfill) for integration ' || r.id::text,
      NULL   -- default encryption key
    );

    UPDATE public.crm_integrations
       SET credential_ref = jsonb_build_object(
             'vault_secret_id', v_vault_id::text,
             'token_type',      v_token_type,
             'last4',           right(v_secret, 4)
           ),
           auth_type    = 'api_key',
           connected_at = COALESCE(connected_at, NOW())
     WHERE id = r.id;
  END LOOP;
END
$backfill$;


-- ============================================================
-- STEP 4: resolve_crm_secret() — server-side secret resolver
--
-- SECURITY DEFINER (owner = postgres) so it can read vault.decrypted_secrets
-- regardless of caller. Granted EXECUTE to service_role ONLY. N8N calls this
-- over PostgREST rpc/ with the service_role key — the `vault` schema itself
-- stays unexposed (transport-correct least privilege). NOT granted to
-- authenticated / anon, so the browser can never resolve a secret.
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_crm_secret(p_integration_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vault_id UUID;
  v_secret   TEXT;
BEGIN
  SELECT NULLIF(credential_ref->>'vault_secret_id', '')::UUID
    INTO v_vault_id
  FROM public.crm_integrations
  WHERE id = p_integration_id;

  IF v_vault_id IS NULL THEN
    RETURN NULL;   -- no secret configured for this integration
  END IF;

  SELECT decrypted_secret
    INTO v_secret
  FROM vault.decrypted_secrets
  WHERE id = v_vault_id;

  RETURN v_secret;
END;
$$;

COMMENT ON FUNCTION public.resolve_crm_secret(UUID) IS
  'Server-side resolver: returns the decrypted CRM secret for an integration. '
  'SECURITY DEFINER (owner postgres) reads vault.decrypted_secrets. EXECUTE granted to '
  'service_role ONLY — N8N calls it over rpc/ without exposing the vault schema. '
  'Never granted to authenticated/anon.';

REVOKE ALL ON FUNCTION public.resolve_crm_secret(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_crm_secret(UUID) TO service_role;


-- ============================================================
-- STEP 5: upsert_crm_integration() — owner-only secret write path
--
-- The ONLY authenticated path that writes CRM secrets. SECURITY DEFINER
-- (owner postgres) so it can write Vault and the base table despite the
-- revoked authenticated write grant (Step 6). All tenancy + authorization
-- is enforced INSIDE from JWT claims — never from arguments. Mirrors the
-- upsert_guest / create_reservation pattern.
--
--   • Write-only secret: p_secret goes to Vault, never to the table, never
--     returned. NULL p_secret = config/name-only edit (existing secret kept).
--   • Rotation: existing vault_secret_id + new p_secret → vault.update_secret
--     (value only; name/description/key preserved via NULLs).
--   • Returns SAFE fields only (no plaintext, no usable secret).
-- ============================================================

CREATE OR REPLACE FUNCTION public.upsert_crm_integration(
  p_provider            TEXT,
  p_name                TEXT,
  p_external_account_id TEXT        DEFAULT NULL,
  p_auth_type           TEXT        DEFAULT 'none',
  p_config              JSONB       DEFAULT '{}',
  p_secret              TEXT        DEFAULT NULL,
  p_expires_at          TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id   UUID  := jwt_org_id();
  v_role     TEXT  := jwt_role();
  v_user_id  UUID  := jwt_user_id();
  v_config   JSONB := COALESCE(p_config, '{}'::JSONB);
  v_existing public.crm_integrations%ROWTYPE;
  v_vault_id UUID;
  v_cred_ref JSONB;
  v_id       UUID;
BEGIN
  -- 5.1 Tenant + owner-only gate (matches the frozen matrix).
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'upsert_crm_integration: no organization context in JWT'
      USING ERRCODE = '42501';
  END IF;
  IF v_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'upsert_crm_integration: role % may not manage CRM integrations (owner only)',
      COALESCE(v_role, 'none')
      USING ERRCODE = '42501';
  END IF;

  -- 5.2 Validate enums.
  IF p_provider IS NULL OR p_provider NOT IN ('gohighlevel', 'hubspot', 'salesforce', 'none') THEN
    RAISE EXCEPTION 'upsert_crm_integration: invalid provider %', COALESCE(p_provider, 'null');
  END IF;
  IF COALESCE(p_auth_type, 'none') NOT IN ('api_key', 'private_token', 'oauth2', 'none') THEN
    RAISE EXCEPTION 'upsert_crm_integration: invalid auth_type %', COALESCE(p_auth_type, 'null');
  END IF;

  -- 5.3 Defense: a secret must never be smuggled through the browser-readable config.
  IF v_config ?| ARRAY['api_key','make_webhook_secret','webhook_secret','access_token',
                       'refresh_token','client_secret','private_token','secret'] THEN
    RAISE EXCEPTION 'upsert_crm_integration: config must not contain secret keys; pass secrets via p_secret only';
  END IF;

  -- 5.4 Locate any existing row for this org+provider (UNIQUE key).
  SELECT * INTO v_existing
  FROM public.crm_integrations
  WHERE organization_id = v_org_id
    AND provider        = p_provider;

  IF v_existing.id IS NOT NULL THEN
    ------------------------------------------------------------------
    -- UPDATE branch
    ------------------------------------------------------------------
    v_cred_ref := v_existing.credential_ref;

    IF p_secret IS NOT NULL AND length(p_secret) > 0 THEN
      v_vault_id := NULLIF(v_existing.credential_ref->>'vault_secret_id', '')::UUID;
      IF v_vault_id IS NULL THEN
        -- First secret for an existing (config-only) integration.
        v_vault_id := vault.create_secret(
          p_secret,
          'crm/' || v_org_id::text || '/' || p_provider || '/' || v_existing.id::text,
          'Campground OS CRM secret for integration ' || v_existing.id::text,
          NULL
        );
      ELSE
        -- Rotation: update value only; preserve name/description/key (NULLs).
        PERFORM vault.update_secret(v_vault_id, p_secret, NULL, NULL, NULL);
      END IF;

      v_cred_ref := jsonb_strip_nulls(jsonb_build_object(
        'vault_secret_id', v_vault_id::text,
        'token_type',      p_auth_type,
        'last4',           right(p_secret, 4),
        'expires_at',      to_jsonb(p_expires_at)
      ));
    END IF;

    UPDATE public.crm_integrations
       SET name                = p_name,
           external_account_id = COALESCE(p_external_account_id, external_account_id),
           auth_type           = p_auth_type,
           config              = v_config,
           credential_ref      = v_cred_ref,
           status              = CASE WHEN (v_cred_ref ? 'vault_secret_id') THEN 'active' ELSE status END,
           connected_at        = CASE WHEN p_secret IS NOT NULL THEN NOW()     ELSE connected_at END,
           connected_by        = CASE WHEN p_secret IS NOT NULL THEN v_user_id ELSE connected_by END,
           updated_at          = NOW()
     WHERE id = v_existing.id
     RETURNING id INTO v_id;

  ELSE
    ------------------------------------------------------------------
    -- INSERT branch — create the row first (need its id for the Vault
    -- name), then attach the Vault secret. credentials stays '{}' (Vault
    -- is the new home); credential_ref is filled below if a secret is given.
    ------------------------------------------------------------------
    INSERT INTO public.crm_integrations
      (organization_id, provider, name, external_account_id, auth_type,
       config, credentials, credential_ref, status)
    VALUES
      (v_org_id, p_provider, p_name, p_external_account_id, p_auth_type,
       v_config, '{}'::JSONB, '{}'::JSONB,
       CASE WHEN p_secret IS NOT NULL THEN 'active' ELSE 'inactive' END)
    RETURNING id INTO v_id;

    IF p_secret IS NOT NULL AND length(p_secret) > 0 THEN
      v_vault_id := vault.create_secret(
        p_secret,
        'crm/' || v_org_id::text || '/' || p_provider || '/' || v_id::text,
        'Campground OS CRM secret for integration ' || v_id::text,
        NULL
      );
      v_cred_ref := jsonb_strip_nulls(jsonb_build_object(
        'vault_secret_id', v_vault_id::text,
        'token_type',      p_auth_type,
        'last4',           right(p_secret, 4),
        'expires_at',      to_jsonb(p_expires_at)
      ));

      UPDATE public.crm_integrations
         SET credential_ref = v_cred_ref,
             connected_at   = NOW(),
             connected_by   = v_user_id,
             updated_at     = NOW()
       WHERE id = v_id;
    END IF;
  END IF;

  -- 5.5 Return SAFE fields only — never plaintext, never the raw secret.
  RETURN (
    SELECT jsonb_build_object(
      'id',                  ci.id,
      'provider',            ci.provider,
      'name',                ci.name,
      'external_account_id', ci.external_account_id,
      'auth_type',           ci.auth_type,
      'status',              ci.status,
      'last4',               ci.credential_ref->>'last4',
      'connected_at',        ci.connected_at
    )
    FROM public.crm_integrations ci
    WHERE ci.id = v_id
  );
END;
$$;

COMMENT ON FUNCTION public.upsert_crm_integration(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TIMESTAMPTZ) IS
  'Owner-only CRM integration write path (SECURITY DEFINER). Org/role/user from JWT only. '
  'Writes the secret to Vault (default key) and stores only a non-secret credential_ref. '
  'NULL p_secret = config-only edit (secret preserved); non-null with an existing secret = rotation. '
  'Returns safe fields only — never credentials/plaintext. Direct base-table writes are revoked (Step 6).';

REVOKE ALL ON FUNCTION public.upsert_crm_integration(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TIMESTAMPTZ)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_crm_integration(TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TIMESTAMPTZ)
  TO authenticated, service_role;


-- ============================================================
-- STEP 6: Grant tightening — close the browser credential-write path
--
-- The v5 grant `INSERT, UPDATE, DELETE ON crm_integrations TO authenticated`
-- survived v7 untouched (audit H-1). Revoke it so the RPC is the SOLE write
-- path. The v7 column-level SELECT grant (everything EXCEPT credentials) is
-- left intact; the owner/manager RLS policies remain as backstops.
--
-- Nothing in the current frontend uses direct writes (IntegrationsPage is
-- read-only), so no UI regresses.
-- ============================================================

REVOKE INSERT, UPDATE, DELETE ON public.crm_integrations FROM authenticated;

-- Extend the column-level SELECT grant to the NEW non-secret columns so the
-- security_invoker safe view (Step 7) keeps working for authenticated. (Same
-- reasoning as v7 Step 5c: an invoker view needs caller SELECT on referenced
-- columns.) `credentials` stays ungranted → still a hard permission error.
GRANT SELECT (auth_type, credential_ref, connected_at, connected_by,
              last_error, last_error_at, sync_cursor)
  ON public.crm_integrations TO authenticated;


-- ============================================================
-- STEP 7: Recreate crm_integrations_safe with the new non-secret fields
--
-- Still excludes `credentials`. credential_ref carries only the vault id +
-- masked metadata (no plaintext) and is safe to surface. security_invoker
-- keeps tenant scoping in the caller's context (owner/manager per RLS 7.11).
--
-- DROP + CREATE (not CREATE OR REPLACE): v8 reorders columns (auth_type /
-- credential_ref inserted before config), and CREATE OR REPLACE VIEW only
-- permits appending columns at the end. Same pattern v5/v7 use for shape
-- changes. No DB object depends on this view, so a plain DROP (no CASCADE)
-- is safe; the GRANT below restores the view's only privilege. Atomic within
-- the surrounding transaction.
-- ============================================================

DROP VIEW IF EXISTS public.crm_integrations_safe;
CREATE VIEW public.crm_integrations_safe
WITH (security_invoker = true)
AS
SELECT
  id,
  organization_id,
  provider,
  name,
  external_account_id,
  auth_type,
  credential_ref,
  config,
  status,
  connected_at,
  connected_by,
  last_error,
  last_error_at,
  last_sync_at,
  sync_cursor,
  created_at,
  updated_at
FROM public.crm_integrations;

GRANT SELECT ON public.crm_integrations_safe TO authenticated;

COMMENT ON VIEW public.crm_integrations_safe IS
  'Read-only view of crm_integrations. Excludes credentials. Adds v8 non-secret fields '
  '(auth_type, credential_ref [vault ref + masked last4 only], audit, sync-health). '
  'security_invoker = true: RLS (owner/manager) applies in caller context. '
  'Secret writes go through upsert_crm_integration(); secret reads through resolve_crm_secret() (service_role).';


COMMIT;


-- ============================================================
-- STEP 8: VERIFICATION (commented — run manually AFTER COMMIT)
--
-- Each impersonation block wraps in BEGIN/ROLLBACK and sets the JWT claims
-- GUC, matching the v7 Step 9 harness. Seeded ids:
--   aries owner user 00000000-0000-0000-0000-000000000020, org ...01
-- ============================================================

/*
-- ── 8a. Schema: new columns present ──────────────────────────
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations'
  AND column_name IN ('auth_type','credential_ref','connected_at','connected_by',
                      'last_error','last_error_at','sync_cursor')
ORDER BY column_name;
-- Expected: all 7 rows present.

-- ── 8b. Grants: authenticated write path is closed ───────────
SELECT
  has_table_privilege('authenticated','public.crm_integrations','INSERT') AS ins,
  has_table_privilege('authenticated','public.crm_integrations','UPDATE') AS upd,
  has_table_privilege('authenticated','public.crm_integrations','DELETE') AS del;
-- Expected: all FALSE.

-- ── 8c. Safe view: excludes credentials, includes v8 fields ──
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations_safe'
ORDER BY ordinal_position;
-- Expected: includes auth_type, credential_ref, connected_at/by, last_error(_at),
--           last_sync_at, sync_cursor.  NOT present: credentials.

-- ── 8d. Browser security: authenticated cannot reach secrets ──
-- BEGIN; SET LOCAL ROLE authenticated;
-- SELECT credentials FROM public.crm_integrations;        -- PASS: permission denied
-- SELECT decrypted_secret FROM vault.decrypted_secrets;   -- PASS: permission denied
-- SELECT public.resolve_crm_secret(gen_random_uuid());    -- PASS: permission denied for function
-- ROLLBACK;
SELECT
  has_function_privilege('authenticated','public.resolve_crm_secret(uuid)','EXECUTE') AS auth_can_resolve,
  has_function_privilege('anon',         'public.resolve_crm_secret(uuid)','EXECUTE') AS anon_can_resolve,
  has_table_privilege  ('authenticated','vault.decrypted_secrets','SELECT')           AS auth_vault_read;
-- Expected: all FALSE.

-- ── 8e. Vault WRITE test: owner upsert (no plaintext returned) ─
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','owner',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- SELECT public.upsert_crm_integration(
--   'gohighlevel','Aries — GHL', 'loc_test_123', 'api_key', '{}'::jsonb, 'super-secret-key-9999', NULL);
-- -- PASS: returns { id, provider, status:'active', last4:'9999', ... } and NO secret/plaintext.
-- SELECT credential_ref ? 'vault_secret_id' AS has_ref, credential_ref->>'last4' AS last4
--   FROM public.crm_integrations
--   WHERE organization_id='00000000-0000-0000-0000-000000000001' AND provider='gohighlevel';
-- -- PASS: has_ref = true, last4 = '9999'.
-- ROLLBACK;

-- ── 8f. Vault READ test: resolver returns the secret (server-side) ──
-- BEGIN;
-- (As postgres/service_role) create via upsert as in 8e WITHOUT rollback in a scratch row,
-- then:
-- SELECT public.resolve_crm_secret('<integration_id>'::uuid);  -- PASS: returns 'super-secret-key-9999'
-- -- Rotation: re-run upsert with a new p_secret, then resolve again → returns the NEW value.
-- ROLLBACK;

-- ── 8g. RLS: non-owner cannot manage; cross-org blocked ──────
-- BEGIN; SET LOCAL ROLE authenticated;
-- (Aries claims but 'user_role','manager')
-- SELECT public.upsert_crm_integration('gohighlevel','x',NULL,'api_key','{}'::jsonb,'k', NULL);
-- -- PASS: ERROR — role manager may not manage CRM integrations (owner only)
-- ROLLBACK;

-- ── 8h. Config-secret guard ──────────────────────────────────
-- (Aries owner claims)
-- SELECT public.upsert_crm_integration(
--   'gohighlevel','x',NULL,'api_key', '{"api_key":"leak"}'::jsonb, NULL, NULL);
-- -- PASS: ERROR — config must not contain secret keys

-- ── 8i. N8N path: service_role resolves over rpc/, vault stays unexposed ──
-- As service_role: SELECT public.resolve_crm_secret('<integration_id>'::uuid);  -- PASS: returns secret
-- Confirm a REST call to /rest/v1/ for the `vault` schema is NOT possible
-- (vault is not in the exposed schemas list) — only the rpc/ resolver works.
*/


-- ============================================================
-- STEP 9: ROLLBACK NOTES (manual — v8 is additive, rollback is low-risk)
--
-- In-transaction failure: the explicit BEGIN/COMMIT means any error before
-- COMMIT rolls back EVERYTHING (columns, functions, grants, AND the Vault
-- inserts from Step 3) — no partial state.
--
-- Post-commit reversal (only if a regression is found), in order:
--   1. DROP FUNCTION public.upsert_crm_integration(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TIMESTAMPTZ);
--      DROP FUNCTION public.resolve_crm_secret(UUID);
--   2. Recreate crm_integrations_safe with the v7 column set; re-GRANT SELECT.
--   3. EMERGENCY ONLY (re-opens audit H-1 — revert forward ASAP):
--      GRANT INSERT, UPDATE, DELETE ON public.crm_integrations TO authenticated;
--   4. Leave the v8 columns in place (harmless defaults). Dropping is optional/riskier.
--   5. Vault secrets from Step 3/Step 5 become inert/orphaned — delete by the
--      recorded credential_ref->>'vault_secret_id' if a clean revert is mandated,
--      or leave them (encrypted, unreferenced, unreadable by the browser).
--   6. `credentials` was never cleared → N8N never lost access; no data loss.
--
-- Rollback touches functions/view/grants only — NO RLS flip — so it cannot
-- lock users out the way a v7-style policy change could.
--
-- Still open after v8 (tracked):
--   • Restricted `crm_automation` role to retire blanket service_role (M-5).
--   • Frontend: Database generic + owner connect/rotate UI (separate release).
--   • N8N outbound consumer (next phase).
--   • Future cleanup migration: drop crm_integrations.credentials,
--     organizations.ghl_location_id / make_webhook_secret after cutover verified.
-- ============================================================
