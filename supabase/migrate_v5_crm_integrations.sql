-- ============================================================
-- MIGRATION v4 → v5: CRM Integration Abstraction
-- Campground Guest Management & Revenue Intelligence
--
-- PURPOSE:
--   Abstracts CRM provider details (currently GoHighLevel-specific
--   columns on organizations) into a reusable crm_integrations table.
--   Enables multi-CRM support per organization without future schema
--   changes. Migrates ghl_location_id and make_webhook_secret data
--   into crm_integrations. Deprecates both source columns.
--
-- SAFETY CONTRACT:
--   • All steps are additive — no columns dropped, no data deleted
--   • Every ALTER TABLE uses IF NOT EXISTS
--   • Existing ghl_location_id and make_webhook_secret columns are
--     retained and deprecated via COMMENT (removed in migrate_v7
--     after all reads confirmed to use crm_integrations)
--   • Backfills are idempotent: ON CONFLICT DO NOTHING / WHERE ... IS NULL
--   • guest_summary and kpi_summary views are drop-and-recreated;
--     existing grants re-applied immediately after
--
-- EXECUTION ORDER:
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3 → migrate_v4 → [THIS FILE] → migrate_v6
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- Step 1: crm_integrations
-- One row per CRM provider per organization.
-- UNIQUE(organization_id, provider): one active integration per
-- provider per org. Relax this constraint in a future migration
-- if multi-account support is needed.
--
-- credentials JSONB: sensitive secrets — API keys, OAuth tokens,
-- webhook signing secrets. NEVER SELECT from this table in frontend
-- code. ALL frontend reads go through crm_integrations_safe view.
--
-- config JSONB: non-secret provider config — webhook receive URLs,
-- pipeline IDs, field mapping overrides, tag prefixes, etc.
--
-- external_account_id: provider-specific account reference.
--   GHL:        location_id (sub-account)
--   HubSpot:    portal_id
--   Salesforce: org_id
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.crm_integrations (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider            TEXT        NOT NULL
                      CHECK (provider IN ('gohighlevel', 'hubspot', 'salesforce', 'none')),
  name                TEXT        NOT NULL,
  external_account_id TEXT,
  credentials         JSONB       NOT NULL DEFAULT '{}',
  config              JSONB       NOT NULL DEFAULT '{}',
  status              TEXT        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'inactive', 'error')),
  last_sync_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, provider)
);

COMMENT ON TABLE public.crm_integrations IS
  'CRM provider configurations per organization. One row per provider per org. '
  'Abstracts GHL, HubSpot, Salesforce behind a common structure. '
  'credentials column is NEVER exposed to frontend — all reads go through crm_integrations_safe.';

COMMENT ON COLUMN public.crm_integrations.external_account_id IS
  'Provider-specific account identifier. '
  'GHL: location_id (sub-account). HubSpot: portal_id. Salesforce: org_id. '
  'NULL for provider = none (not yet configured).';

COMMENT ON COLUMN public.crm_integrations.credentials IS
  'Sensitive credentials — API keys, OAuth tokens, webhook secrets. '
  'NEVER SELECT from base table in frontend code. Use crm_integrations_safe view instead. '
  'Keys present by provider: GHL: make_webhook_secret, api_key. '
  'HubSpot: access_token, refresh_token. Salesforce: client_id, client_secret, access_token, instance_url.';

COMMENT ON COLUMN public.crm_integrations.config IS
  'Non-secret provider configuration. Safe for authenticated reads. '
  'Keys present by provider: make_incoming_url (Make.com receive URL), '
  'pipeline_id, tag_prefix (prepended to all loyalty tags in this CRM), '
  'field_mappings (platform field → CRM field JSON map).';

COMMENT ON COLUMN public.crm_integrations.external_account_id IS
  'Provider-specific account/location identifier. '
  'GHL: location_id (one sub-account per org). '
  'HubSpot: portal_id. Salesforce: org_id. '
  'NULL for provider = none.';


-- ────────────────────────────────────────────────────────────
-- Step 2: Add crm_contact_ids to guest_org_profiles
-- Maps provider key → contact ID for a guest in this org's CRM.
-- Structure: { "gohighlevel": "abc123", "hubspot": "456def" }
-- Replaces the single ghl_contact_id TEXT column with a
-- multi-provider map. ghl_contact_id is retained (deprecated)
-- for backward compatibility with existing Make.com scenarios.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.guest_org_profiles
  ADD COLUMN IF NOT EXISTS crm_contact_ids JSONB NOT NULL DEFAULT '{}';

COMMENT ON COLUMN public.guest_org_profiles.crm_contact_ids IS
  'Maps CRM provider key → contact ID for this guest in this org. '
  'Example: {"gohighlevel": "abc123", "hubspot": "456def"}. '
  'Written by Make.com after successful contact upsert in each provider. '
  'Replaces ghl_contact_id (deprecated as of migrate_v5).';

COMMENT ON COLUMN public.guest_org_profiles.ghl_contact_id IS
  'DEPRECATED as of migrate_v5. Use crm_contact_ids->>''gohighlevel'' instead. '
  'Retained for backward compatibility with Make.com scenarios that write this column. '
  'Remove in migrate_v7 after all Make.com scenarios updated to write crm_contact_ids.';


-- ────────────────────────────────────────────────────────────
-- Step 3: Backfill crm_contact_ids from existing ghl_contact_id
-- Only updates rows where crm_contact_ids is empty and
-- ghl_contact_id is set. Safe to re-run.
-- ────────────────────────────────────────────────────────────
UPDATE public.guest_org_profiles
  SET crm_contact_ids = jsonb_build_object('gohighlevel', ghl_contact_id)
  WHERE ghl_contact_id IS NOT NULL
    AND crm_contact_ids = '{}';


-- ────────────────────────────────────────────────────────────
-- Step 4: Backfill crm_integrations from organizations
-- Creates one crm_integrations row for each org that has
-- ghl_location_id set. Migrates make_webhook_secret into
-- credentials JSONB. ON CONFLICT DO NOTHING: safe to re-run.
-- ────────────────────────────────────────────────────────────
INSERT INTO public.crm_integrations (
  organization_id,
  provider,
  name,
  external_account_id,
  credentials,
  config,
  status
)
SELECT
  o.id,
  'gohighlevel',
  o.name || ' — GoHighLevel',
  o.ghl_location_id,
  CASE
    WHEN o.make_webhook_secret IS NOT NULL
    THEN jsonb_build_object('make_webhook_secret', o.make_webhook_secret)
    ELSE '{}'::JSONB
  END,
  '{}',
  'active'
FROM public.organizations o
WHERE o.ghl_location_id IS NOT NULL
ON CONFLICT (organization_id, provider) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- Step 5: Deprecation comments on organizations columns
-- Columns retained for backward compatibility during transition.
-- Remove in migrate_v7 after:
--   (a) All Make.com scenarios updated to read crm_integrations
--   (b) React frontend confirmed to not reference these columns
--   (c) No read queries hitting these columns (check pg_stat_user_tables)
-- ────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.organizations.ghl_location_id IS
  'DEPRECATED as of migrate_v5. Use crm_integrations WHERE provider = ''gohighlevel'' AND organization_id = ... instead. '
  'Data migrated to crm_integrations.external_account_id in Step 4. '
  'Retained for backward compatibility. Remove in migrate_v7.';

COMMENT ON COLUMN public.organizations.make_webhook_secret IS
  'DEPRECATED as of migrate_v5. Use crm_integrations.credentials->>''make_webhook_secret'' instead '
  '(requires service role key to read). '
  'Data migrated to crm_integrations.credentials in Step 4. '
  'Retained for backward compatibility. Remove in migrate_v7.';


-- ────────────────────────────────────────────────────────────
-- Step 6: Indexes
-- ────────────────────────────────────────────────────────────

-- Primary lookup: find all integrations for an org
CREATE INDEX IF NOT EXISTS idx_crm_integrations_org_id
  ON public.crm_integrations(organization_id);

-- Provider filter across orgs (e.g., "all GHL orgs for batch sync")
CREATE INDEX IF NOT EXISTS idx_crm_integrations_provider
  ON public.crm_integrations(provider);

-- Active integrations only — RLS policies and sync queries filter by this
CREATE INDEX IF NOT EXISTS idx_crm_integrations_org_active
  ON public.crm_integrations(organization_id, status)
  WHERE status = 'active';

-- GIN index on crm_contact_ids JSONB:
-- Enables: crm_contact_ids ? 'gohighlevel'         (key existence check)
--          crm_contact_ids @> '{"gohighlevel":"x"}' (value lookup by Make.com)
CREATE INDEX IF NOT EXISTS idx_gop_crm_contact_ids
  ON public.guest_org_profiles USING GIN (crm_contact_ids);


-- ────────────────────────────────────────────────────────────
-- Step 7: crm_integrations_safe view
-- Excludes credentials column. All frontend reads use this view.
-- security_invoker = true: RLS on crm_integrations evaluates in
-- the caller's context — when real tenant RLS policies replace
-- demo_allow_all_crm_integrations, the view automatically
-- inherits correct org scoping without requiring a view change.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.crm_integrations_safe
WITH (security_invoker = true)
AS
SELECT
  id,
  organization_id,
  provider,
  name,
  external_account_id,
  config,
  status,
  last_sync_at,
  created_at,
  updated_at
FROM public.crm_integrations;

COMMENT ON VIEW public.crm_integrations_safe IS
  'Read-only view of crm_integrations with credentials column excluded. '
  'Use this view for ALL frontend and authenticated-role reads. '
  'security_invoker = true ensures RLS on the base table applies in caller context.';


-- ────────────────────────────────────────────────────────────
-- Step 8: RLS on crm_integrations
-- Demo-permissive policy allows simulation without real auth.
-- Template for real tenant-scoped replacement (apply AFTER
-- JWT hook is verified per migrate_v4 post-migration steps):
--
--   DROP POLICY "demo_allow_all_crm_integrations" ON public.crm_integrations;
--   CREATE POLICY "tenant_crm_integrations_select"
--     ON public.crm_integrations FOR SELECT
--     USING (organization_id = jwt_org_id());
--   CREATE POLICY "tenant_crm_integrations_write"
--     ON public.crm_integrations FOR INSERT UPDATE DELETE
--     USING (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))
--     WITH CHECK (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'));
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.crm_integrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_crm_integrations" ON public.crm_integrations;
CREATE POLICY "demo_allow_all_crm_integrations"
  ON public.crm_integrations FOR ALL USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- Step 9: Grants
-- Base table: INSERT/UPDATE/DELETE for authenticated writes.
-- No SELECT grant on base table — reads forced through safe view.
-- anon role: no grants (CRM config is never visible to
-- unauthenticated requests, even in demo mode).
-- crm_integrations_safe: SELECT for authenticated only.
--
-- NOTE: The demo frontend currently uses the anon key.
-- The settings page that reads CRM config requires an authenticated
-- session established via Supabase Auth (see migrate_v4 post-migration
-- Step B for JWT hook registration). Use service role key for
-- server-side reads of the base table that include credentials.
-- ────────────────────────────────────────────────────────────

-- Write path: authenticated users can manage integrations (RLS controls tenant scope)
GRANT INSERT, UPDATE, DELETE ON public.crm_integrations TO authenticated;

-- Read path: authenticated users read config (but NOT credentials) via safe view
GRANT SELECT ON public.crm_integrations_safe TO authenticated;


-- ────────────────────────────────────────────────────────────
-- Step 10: Update guest_summary view
-- Add crm_contact_ids column. Update ghl_contact_id resolution to
-- prefer crm_contact_ids (v5+) → ghl_contact_id deprecated column →
-- guests table legacy column.
-- ────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.guest_summary;
CREATE VIEW public.guest_summary
WITH (security_invoker = true)
AS
SELECT
  g.id,
  COALESCE(gop.first_name, g.first_name)                                    AS first_name,
  COALESCE(gop.last_name,  g.last_name)                                     AS last_name,
  (COALESCE(gop.first_name, g.first_name) || ' ' ||
   COALESCE(gop.last_name,  g.last_name))                                   AS full_name,
  g.email,
  COALESCE(gop.phone, g.phone)                                              AS phone,
  COALESCE(
    gop.crm_contact_ids->>'gohighlevel',
    gop.ghl_contact_id,
    g.ghl_contact_id
  )                                                                         AS ghl_contact_id,
  gop.crm_contact_ids,
  gop.organization_id,
  COALESCE(l.total_visits,    0)                                            AS total_visits,
  COALESCE(l.confirmed_visits, l.total_visits, 0)                          AS confirmed_visits,
  COALESCE(l.total_spend,     0.00)                                        AS total_spend,
  COALESCE(l.tier, 'Bronze')                                               AS loyalty_tier,
  l.last_visit,
  gop.crm_synced_at,
  g.created_at
FROM public.guests g
LEFT JOIN public.guest_org_profiles gop ON gop.guest_id = g.id
LEFT JOIN public.loyalty l
  ON  l.guest_id = g.id
  AND (l.organization_id = gop.organization_id OR gop.organization_id IS NULL);

GRANT SELECT ON public.guest_summary TO anon, authenticated;

COMMENT ON VIEW public.guest_summary IS
  'Guests with loyalty state, org-scoped PII, and CRM contact IDs. '
  'ghl_contact_id resolved from: crm_contact_ids->>''gohighlevel'' (v5+), '
  'then gop.ghl_contact_id (deprecated), then guests.ghl_contact_id (legacy). '
  'crm_contact_ids column: full multi-provider map for this guest in this org. '
  'Filter by organization_id for tenant-scoped display.';


-- ────────────────────────────────────────────────────────────
-- Step 11: Update kpi_summary view
-- synced_contacts: count profiles with any CRM contact ID
--   (non-empty crm_contact_ids OR legacy ghl_contact_id set).
-- active_crm_integrations: new metric — orgs with a live
--   non-none CRM provider configured.
-- ────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.kpi_summary;
CREATE VIEW public.kpi_summary AS
SELECT
  (SELECT COUNT(*) FROM public.guests)                              AS total_guests,
  (SELECT COUNT(*) FROM public.reservations)                        AS total_reservations,
  (SELECT COUNT(*) FROM public.loyalty WHERE total_visits > 1)      AS returning_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Bronze')       AS bronze_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Silver')       AS silver_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Gold')         AS gold_guests,
  (SELECT COALESCE(SUM(total_amount), 0.00)
   FROM public.reservations WHERE status != 'cancelled')            AS estimated_revenue,
  (SELECT COUNT(*)
   FROM public.guest_org_profiles
   WHERE crm_contact_ids != '{}'::JSONB
      OR ghl_contact_id IS NOT NULL)                                AS synced_contacts,
  (SELECT COUNT(DISTINCT organization_id)
   FROM public.crm_integrations
   WHERE status = 'active' AND provider != 'none')                  AS active_crm_integrations,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'pending')  AS pending_webhooks,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'failed')   AS failed_webhooks;

GRANT SELECT ON public.kpi_summary TO anon, authenticated;

COMMENT ON VIEW public.kpi_summary IS
  'Global KPI aggregates for the demo dashboard. '
  'synced_contacts: guest_org_profiles with at least one CRM contact ID (any provider). '
  'active_crm_integrations: distinct orgs with status=active and provider != none. '
  'Org-scoped KPIs require a dedicated function once real RLS is enabled.';


-- ────────────────────────────────────────────────────────────
-- Step 12: Verification queries (run manually after migration)
-- Uncomment each block individually to verify.
-- ────────────────────────────────────────────────────────────

/*
-- 12a. Verify crm_integrations table structure
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations'
ORDER BY ordinal_position;
-- Expected columns: id, organization_id, provider, name, external_account_id,
--                   credentials, config, status, last_sync_at, created_at, updated_at


-- 12b. Verify crm_integrations backfill from organizations
SELECT
  ci.organization_id,
  o.name                                          AS org_name,
  ci.provider,
  ci.name                                         AS integration_name,
  ci.external_account_id,
  o.ghl_location_id                               AS legacy_ghl_location_id,
  (ci.external_account_id = o.ghl_location_id)   AS external_account_id_matches,
  ci.status
FROM public.crm_integrations ci
JOIN public.organizations o ON o.id = ci.organization_id
ORDER BY o.name;
-- Expected: one row per org that had ghl_location_id set
--           external_account_id_matches = true for all rows


-- 12c. Verify make_webhook_secret migrated into credentials
-- NOTE: Do NOT log or store output of this query in production environments
SELECT
  ci.organization_id,
  o.name                                                                            AS org_name,
  (ci.credentials ? 'make_webhook_secret')                                          AS has_webhook_secret,
  (ci.credentials->>'make_webhook_secret' = o.make_webhook_secret)                 AS secret_matches
FROM public.crm_integrations ci
JOIN public.organizations o ON o.id = ci.organization_id
WHERE o.make_webhook_secret IS NOT NULL;
-- Expected: has_webhook_secret = true, secret_matches = true for all rows


-- 12d. Verify crm_contact_ids backfill from ghl_contact_id
SELECT
  gop.guest_id,
  gop.organization_id,
  gop.ghl_contact_id                              AS legacy_ghl_contact_id,
  gop.crm_contact_ids->>'gohighlevel'             AS crm_contact_ids_ghl,
  (gop.crm_contact_ids->>'gohighlevel'
    = gop.ghl_contact_id)                         AS ids_match
FROM public.guest_org_profiles gop
WHERE gop.ghl_contact_id IS NOT NULL
ORDER BY gop.organization_id, gop.guest_id;
-- Expected: ids_match = true for all rows


-- 12e. Verify crm_contact_ids column exists with correct type
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'guest_org_profiles'
  AND column_name = 'crm_contact_ids';
-- Expected: data_type = jsonb, column_default = '{}'::jsonb


-- 12f. Verify crm_integrations_safe excludes credentials
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations_safe'
ORDER BY ordinal_position;
-- Expected: id, organization_id, provider, name, external_account_id,
--           config, status, last_sync_at, created_at, updated_at
-- NOT present: credentials


-- 12g. Verify SELECT blocked on base table for non-service roles
-- Run as an authenticated Supabase user (not service role):
--   SELECT * FROM public.crm_integrations LIMIT 1;
-- Expected: ERROR: permission denied for table crm_integrations
-- Confirms credentials are never directly accessible from the API layer.
--
-- Verify safe view is accessible:
SELECT COUNT(*) FROM public.crm_integrations_safe;
-- Expected: returns row count, no error, no credentials column


-- 12h. Verify indexes created
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_crm_integrations_org_id',
    'idx_crm_integrations_provider',
    'idx_crm_integrations_org_active',
    'idx_gop_crm_contact_ids'
  )
ORDER BY indexname;
-- Expected: 4 rows returned


-- 12i. Verify deprecation comments on organizations columns
SELECT
  a.attname                               AS column_name,
  LEFT(d.description, 60)                AS comment_preview
FROM pg_class c
JOIN pg_attribute a   ON a.attrelid = c.oid AND a.attnum > 0
LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = a.attnum
WHERE c.relname = 'organizations'
  AND c.relnamespace = 'public'::regnamespace
  AND a.attname IN ('ghl_location_id', 'make_webhook_secret');
-- Expected: both columns have comments starting with 'DEPRECATED as of migrate_v5'


-- 12j. Verify kpi_summary reflects new metrics
SELECT
  synced_contacts,
  active_crm_integrations,
  pending_webhooks,
  failed_webhooks
FROM public.kpi_summary;
-- Expected:
--   synced_contacts:          > 0 if any demo guests have GHL contact IDs
--   active_crm_integrations:  count of orgs with ghl_location_id set (from backfill)
*/


-- ────────────────────────────────────────────────────────────
-- Post-migration checklist (manual steps)
-- ────────────────────────────────────────────────────────────

/*
STEP A — Verify backfill counts
  Run blocks 12b, 12c, 12d. Confirm every org with ghl_location_id
  has a crm_integrations row and every guest_org_profile with
  ghl_contact_id has it mirrored in crm_contact_ids.

STEP B — Update Make.com scenarios to read crm_integrations
  Replace direct reads of organizations.ghl_location_id and
  organizations.make_webhook_secret with crm_integrations:

    GET /rest/v1/crm_integrations
        ?organization_id=eq.{org_id}
        &provider=eq.gohighlevel
        &select=external_account_id,credentials,config
    Authorization: Bearer {service_role_key}  ← service key required for credentials
    apikey: {service_role_key}

  IMPORTANT: Use service_role_key, not anon key, for any request
  that includes the credentials column. Anon and authenticated
  roles cannot SELECT from the base table.

STEP C — Update Make.com GHL contact writeback
  After creating/updating a GHL contact, write both columns during
  the transition period (before ghl_contact_id is removed in v7):

    PATCH /rest/v1/guest_org_profiles
          ?guest_id=eq.{guest_id}&organization_id=eq.{org_id}
    Body: {
      "crm_contact_ids": {"gohighlevel": "{contact_id}"},
      "ghl_contact_id":  "{contact_id}",
      "crm_synced_at":   "{iso_timestamp}"
    }

  After migrate_v7 removes ghl_contact_id, drop it from the PATCH body.

STEP D — Test crm_integrations_safe in React frontend
  The org settings page should read from the safe view:

    const { data } = await supabase
      .from('crm_integrations_safe')
      .select('*')
      .eq('organization_id', orgId)

  Verify: (1) no credentials key in returned objects,
          (2) requires an authenticated session (not anon key).

STEP E — Register CRM provider in onboarding flow
  When a new org is created (migrate_v6 onboarding flow), insert
  a crm_integrations row with provider = 'none' as a placeholder:

    INSERT INTO crm_integrations (organization_id, provider, name, status)
    VALUES ({org_id}, 'none', 'No CRM configured', 'inactive');

  Upgrade to real provider row when the org completes onboarding Step 5 (CRM config).

STEP F — Retire deprecated columns (future migrate_v7)
  Only after Steps B, C, D confirmed in all environments:

    ALTER TABLE public.organizations      DROP COLUMN ghl_location_id;
    ALTER TABLE public.organizations      DROP COLUMN make_webhook_secret;
    ALTER TABLE public.guest_org_profiles DROP COLUMN ghl_contact_id;

  DO NOT run these now — backward compatibility required during Make.com scenario migration.
*/
