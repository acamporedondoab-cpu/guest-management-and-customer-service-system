-- ============================================================
-- MIGRATION v9 → v10: get_dispatch_event() — event-bound dispatch context
-- Campground OS — Multi-Tenant Guest Management & Revenue Intelligence
--
-- PURPOSE (closes Phase 3B review BLOCKER B-1):
--   The crm-sync-dispatch Edge Function must derive EVERYTHING from the event
--   row, never from the caller's request body. This adds the single read the
--   Edge needs: by event_id, return the event's type/org/property/status, the
--   org's GoHighLevel integration id, the NON-SECRET routing context, and the
--   stored payload. The Edge then resolves the secret by the DB-derived
--   integration_id and refuses any event whose status is not 'processing'.
--
--   This restores, at the secret-holding tier, the V9 invariant "derive tenant
--   from the event row, not the caller" (B3/F6). A leaked EDGE_DISPATCH_TOKEN
--   can then only re-trigger genuinely-claimed in-flight events with their real
--   data (idempotent), never pair a victim integration_id with crafted payload.
--
-- SECURITY PATTERN (identical to get_crm_dispatch_context, v9):
--   • SECURITY DEFINER (owner postgres) so it can read webhook_events +
--     crm_integrations without granting the caller any table privilege.
--   • Pinned search_path = public.
--   • Returns NO secret — credential_ref / credentials are never referenced.
--   • EXECUTE granted to crm_resolver ONLY; REVOKEd from PUBLIC, anon,
--     authenticated, and crm_automation (N8N must never read payload/routing
--     this way — it only orchestrates).
--
-- SAFETY CONTRACT:
--   • Additive only — ONE new function, ONE grant. No tables, columns, roles,
--     RLS, or existing objects touched.
--   • Single transaction (BEGIN/COMMIT) so the function never exists with its
--     default PUBLIC EXECUTE still live.
--   • CREATE OR REPLACE + idempotent REVOKE/GRANT → safe to re-run.
--
-- DEPENDS ON (applied & verified):
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3 → migrate_v4
--   → migrate_v5 → migrate_v6 → migrate_v7 → migrate_v8 → migrate_v9
--   (v9 created the crm_resolver / crm_automation roles this file references.)
--
-- POST-COMMIT (operational, NOT part of this file):
--   • NOTIFY pgrst, 'reload schema';   (the new RPC 404s until PostgREST reloads)
--
-- SCOPE: WU-2 only. No Edge Function code, no N8N changes, no frontend changes.
-- ============================================================

BEGIN;


-- ============================================================
-- STEP 0: Preconditions (self-guard) — fail fast, roll back fully
-- ============================================================

DO $precheck$
BEGIN
  IF to_regclass('public.webhook_events') IS NULL THEN
    RAISE EXCEPTION 'v10 precondition failed: public.webhook_events not found';
  END IF;
  IF to_regclass('public.crm_integrations') IS NULL THEN
    RAISE EXCEPTION 'v10 precondition failed: public.crm_integrations not found — apply migrate_v5 first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_resolver') THEN
    RAISE EXCEPTION 'v10 precondition failed: role crm_resolver not found — apply migrate_v9 first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_automation') THEN
    RAISE EXCEPTION 'v10 precondition failed: role crm_automation not found — apply migrate_v9 first';
  END IF;
END
$precheck$;


-- ============================================================
-- STEP 1: get_dispatch_event() — event-bound, non-secret dispatch context
--
-- Returns (JSONB):
--   { "found": false }                              -- event_id does not exist
--   { "found": true,
--     "status":          <webhook_events.status>,   -- Edge proceeds only if 'processing'
--     "event_type":      <webhook_events.event_type>,
--     "organization_id": <uuid>,
--     "property_id":     <uuid|null>,
--     "integration_id":  <org's gohighlevel integration id | null>,
--     "context":         { provider, external_account_id, auth_type, status,
--                          tag_prefix (default ""), field_mappings (default {}) } | null,
--     "payload":         <webhook_events.payload> }
--
-- integration_id / context are resolved by the SAME correlated lookup claim
-- uses (org + provider='gohighlevel'); both NULL when the org has no
-- gohighlevel row (e.g. deleted post-claim) → Edge returns no_provider.
-- NEVER returns a secret (credential_ref / credentials excluded).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_dispatch_event(p_event_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $get_event$
DECLARE
  v_event   public.webhook_events%ROWTYPE;
  v_int_id  UUID  := NULL;
  v_context JSONB := NULL;
BEGIN
  SELECT * INTO v_event
  FROM public.webhook_events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  -- Resolve the org's GoHighLevel integration (UNIQUE(organization_id, provider)
  -- guarantees at most one). Load ONLY the non-secret fields the output needs —
  -- credentials, credential_ref, and vault_secret_id MUST never enter scope, so
  -- this selects an explicit column list (NOT *) and builds context inline.
  -- No match → both targets stay NULL (Edge → no_provider).
  SELECT
    ci.id,
    jsonb_build_object(
      'provider',            ci.provider,
      'external_account_id', ci.external_account_id,
      'auth_type',           ci.auth_type,
      'status',              ci.status,
      'tag_prefix',          COALESCE(ci.config->>'tag_prefix', ''),
      'field_mappings',      COALESCE(ci.config->'field_mappings', '{}'::jsonb)
    )
  INTO v_int_id, v_context
  FROM public.crm_integrations ci
  WHERE ci.organization_id = v_event.organization_id
    AND ci.provider        = 'gohighlevel'
  LIMIT 1;

  RETURN jsonb_build_object(
    'found',           true,
    'status',          v_event.status,
    'event_type',      v_event.event_type,
    'organization_id', v_event.organization_id,
    'property_id',     v_event.property_id,
    'integration_id',  v_int_id,
    'context',         v_context,
    'payload',         v_event.payload
  );
END;
$get_event$;

COMMENT ON FUNCTION public.get_dispatch_event(UUID) IS
  'Event-bound dispatch context for the crm-sync-dispatch Edge Function (closes B-1). '
  'By event_id returns status/event_type/org/property, the org gohighlevel integration_id, '
  'non-secret routing context (mirrors get_crm_dispatch_context), and the stored payload. '
  'Returns {"found":false} for an unknown id. NEVER returns a secret. '
  'crm_resolver EXECUTE only — the Edge derives integration_id + payload here instead of '
  'trusting the request body, and proceeds only when status=''processing''.';

-- B3-style grant: the EXECUTE grant is the boundary. Close the default PUBLIC
-- grant and admit only crm_resolver. crm_automation (N8N) is explicitly excluded.
REVOKE ALL ON FUNCTION public.get_dispatch_event(UUID) FROM PUBLIC, anon, authenticated, crm_automation;
GRANT EXECUTE ON FUNCTION public.get_dispatch_event(UUID) TO crm_resolver;


COMMIT;


-- ============================================================
-- VERIFICATION (commented; run AFTER COMMIT + pgrst reload)
-- ============================================================

/*
-- V1. Function exists, SECURITY DEFINER, search_path pinned
SELECT p.proname, p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='get_dispatch_event';
-- Expected: 1 row, security_definer=t, proconfig contains search_path=public.

-- V2. EXECUTE boundary — crm_resolver only
SELECT
  has_function_privilege('crm_resolver',  'public.get_dispatch_event(uuid)','EXECUTE') AS resolver,      -- t
  has_function_privilege('crm_automation','public.get_dispatch_event(uuid)','EXECUTE') AS automation,    -- f
  has_function_privilege('authenticated', 'public.get_dispatch_event(uuid)','EXECUTE') AS authd,         -- f
  has_function_privilege('anon',          'public.get_dispatch_event(uuid)','EXECUTE') AS anon;          -- f
-- Expected: resolver=t; automation=f; authd=f; anon=f.

-- V3. Functional smoke — unknown id returns {"found": false}
-- BEGIN;
--   SET LOCAL ROLE crm_resolver;
--   SELECT public.get_dispatch_event('00000000-0000-0000-0000-000000000000');  -- {"found": false}
-- ROLLBACK;

-- V4. (Optional, after a real claim) shape on a processing event
-- BEGIN;
--   SET LOCAL ROLE crm_resolver;
--   SELECT public.get_dispatch_event('<a-processing-event-id>');
--   -- Expected keys: found=true, status='processing', event_type, organization_id,
--   --   property_id, integration_id (uuid), context (object: provider/external_account_id/
--   --   auth_type/status/tag_prefix/field_mappings), payload. NO secret / credential_ref.
-- ROLLBACK;

-- V5. Secret-exclusion assertion — the output must NEVER expose secret keys, at
--     the top level OR inside context, for any event id. Run as crm_resolver
--     against a real id; the doc::text check also catches any nested occurrence.
-- BEGIN;
--   SET LOCAL ROLE crm_resolver;
--   WITH r AS (SELECT public.get_dispatch_event('<a-processing-event-id>') AS doc)
--   SELECT
--     (doc ? 'credential_ref')                              AS top_has_credential_ref,      -- f
--     (doc ? 'credentials')                                 AS top_has_credentials,          -- f
--     COALESCE(doc->'context' ? 'credential_ref', false)    AS ctx_has_credential_ref,       -- f
--     COALESCE(doc->'context' ? 'credentials', false)       AS ctx_has_credentials,          -- f
--     (doc::text ILIKE '%vault_secret_id%')                 AS doc_mentions_vault_secret_id  -- f
--   FROM r;
-- ROLLBACK;
-- Expected: all five FALSE.
*/


-- ============================================================
-- ROLLBACK (manual — function-only; trivial and low risk)
--
-- 0. (Operational) Disable any N8N drain / dispatch first.
-- 1. DROP FUNCTION public.get_dispatch_event(UUID);
--      -- crm_resolver's EXECUTE grant is removed automatically with the function;
--      -- no roles, columns, RLS, or v9 objects are touched.
-- 2. NOTIFY pgrst, 'reload schema';
-- No data is affected; the Edge Function (if deployed) would then fail its
-- get_dispatch_event call and should be rolled back alongside this.
-- ============================================================
