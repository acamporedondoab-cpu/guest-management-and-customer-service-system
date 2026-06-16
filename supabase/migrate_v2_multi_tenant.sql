-- ============================================================
-- MIGRATION v1 → v2: Multi-Tenant SaaS Architecture
-- Campground Guest Management & Revenue Intelligence
--
-- SAFETY CONTRACT:
--   • All steps are additive — no columns dropped, no data deleted
--   • Every ALTER TABLE uses IF NOT EXISTS
--   • Every CREATE TABLE uses IF NOT EXISTS
--   • Existing RLS policies are left untouched
--   • The loyalty unique constraint change is deferred to Phase C
--     in seed_simulation.sql (requires data backfill first)
--
-- EXECUTION ORDER:
--   1. Run this file in the Supabase SQL Editor
--   2. Run supabase/seed_simulation.sql afterward
--
-- PHASE A: Structural additions (this file)
-- PHASE B: Simulation data seed (seed_simulation.sql)
-- PHASE C: Loyalty constraint evolution (seed_simulation.sql)
-- PHASE D: Trigger update for multi-tenant schema (seed_simulation.sql)
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- A1. organizations
-- Top-level tenant entity. One row per campground owner.
-- All reservation, loyalty, and CRM data scopes to this table.
-- ghl_location_id maps to one GoHighLevel sub-account per org.
-- make_webhook_secret authenticates inbound Make.com payloads.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.organizations (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                TEXT        NOT NULL,
  slug                TEXT        UNIQUE NOT NULL,
  plan                TEXT        NOT NULL DEFAULT 'starter'
                      CHECK (plan IN ('starter', 'pro', 'enterprise')),
  ghl_location_id     TEXT,
  make_webhook_secret TEXT,
  status              TEXT        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'suspended', 'cancelled')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.organizations IS
  'Top-level tenant entity. One row per campground owner or management group. '
  'All tenant data (properties, guests, reservations, loyalty) scopes to organization_id.';
COMMENT ON COLUMN public.organizations.ghl_location_id IS
  'GoHighLevel sub-account location ID. One sub-account per organization, not per property.';
COMMENT ON COLUMN public.organizations.make_webhook_secret IS
  'HMAC secret used to validate inbound Make.com webhook payloads. '
  'Never expose to frontend — read server-side only.';


-- ────────────────────────────────────────────────────────────
-- A2. users
-- Platform authentication entities. Decoupled from Supabase
-- Auth to allow pre-provisioning before first login.
-- In production: link to auth.users via auth_user_id column.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.users (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email      TEXT        UNIQUE NOT NULL,
  full_name  TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.users IS
  'Platform user accounts. One row per staff member or owner. '
  'Permissions are assigned via user_roles, not on this table.';


-- ────────────────────────────────────────────────────────────
-- A3. user_roles
-- Flexible permission assignments.
-- property_id = NULL  → org-wide access (owner, regional manager)
-- property_id = set   → scoped to one property (site manager, staff)
-- Multiple rows allowed for users with access to multiple properties.
-- revoked_at enables soft revocation — audit trail is preserved.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_roles (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES public.users(id)         ON DELETE CASCADE,
  organization_id UUID        NOT NULL REFERENCES public.organizations(id)  ON DELETE CASCADE,
  property_id     UUID        REFERENCES public.properties(id)              ON DELETE SET NULL,
  role            TEXT        NOT NULL DEFAULT 'staff'
                  CHECK (role IN ('owner', 'manager', 'staff', 'viewer')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at      TIMESTAMPTZ
);

COMMENT ON TABLE public.user_roles IS
  'Role assignments. property_id = NULL means org-wide access. '
  'property_id set means scoped to that property only. '
  'One user can have multiple rows for different properties.';
COMMENT ON COLUMN public.user_roles.revoked_at IS
  'Soft revocation. NULL = active. Set to NOW() to revoke access. '
  'Preserves audit trail — do not delete rows.';


-- ────────────────────────────────────────────────────────────
-- A4. Evolve properties
-- Add organization_id (the tenant ownership link).
-- Add total_sites (required for occupancy % calculation).
-- Add timezone (required for accurate date-range reporting).
-- All columns nullable — backfilled in seed_simulation.sql.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES public.organizations(id);

ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS total_sites INTEGER;

ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'America/New_York';

COMMENT ON COLUMN public.properties.organization_id IS
  'Owning organization. Nullable until backfilled. '
  'Will become NOT NULL after seed_simulation.sql Phase B runs.';
COMMENT ON COLUMN public.properties.total_sites IS
  'Total bookable sites. Required for occupancy % = occupied_sites / total_sites.';


-- ────────────────────────────────────────────────────────────
-- A5. guest_org_profiles
-- Per-org PII and CRM data. This is where first_name, last_name,
-- phone, and ghl_contact_id live in the multi-tenant schema.
--
-- The existing guests table retains its PII columns for backward
-- compatibility during migration. Those columns are deprecated
-- and will be removed in a future Phase 3 migration once all
-- reads/writes go through guest_org_profiles.
--
-- UNIQUE(guest_id, organization_id) → one profile per guest per org.
-- ghl_contact_id is per-org because each org has its own GHL sub-account.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guest_org_profiles (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  guest_id         UUID        NOT NULL REFERENCES public.guests(id)        ON DELETE CASCADE,
  organization_id  UUID        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  first_name       TEXT        NOT NULL,
  last_name        TEXT        NOT NULL,
  phone            TEXT,
  ghl_contact_id   TEXT,
  crm_synced_at    TIMESTAMPTZ,
  internal_notes   TEXT,
  deleted_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (guest_id, organization_id)
);

COMMENT ON TABLE public.guest_org_profiles IS
  'Per-org PII and CRM contact data. One row per guest per organization. '
  'Replaces PII stored on guests table (deprecated columns retained for compat). '
  'ghl_contact_id is different per org — each org has its own GHL sub-account.';
COMMENT ON COLUMN public.guest_org_profiles.deleted_at IS
  'Soft delete for GDPR erasure. Set to NOW() to erase PII. '
  'The guests row (email + id) is retained for audit and reservation linkage.';


-- ────────────────────────────────────────────────────────────
-- A6. Evolve reservations
-- Add organization_id — denormalized from property for O(1) RLS.
-- Add property_id — which campground location this booking is at.
-- Add original_total_amount — required for accurate cancellation
--   loyalty decrements (total_amount may be updated/refunded).
-- Backfill original_total_amount from existing total_amount rows.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES public.organizations(id);

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS property_id UUID REFERENCES public.properties(id);

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS original_total_amount NUMERIC(10,2);

-- Backfill: copy total_amount into original_total_amount for existing rows
UPDATE public.reservations
  SET original_total_amount = total_amount
  WHERE original_total_amount IS NULL
    AND total_amount IS NOT NULL;

COMMENT ON COLUMN public.reservations.organization_id IS
  'Denormalized from property.organization_id. Enables O(1) RLS checks '
  'without a JOIN back through properties. Must always equal '
  'property.organization_id for the associated property_id.';
COMMENT ON COLUMN public.reservations.property_id IS
  'Which campground property this reservation is at. '
  'Nullable until backfilled for pre-migration rows.';
COMMENT ON COLUMN public.reservations.original_total_amount IS
  'Amount at time of booking. Used for accurate loyalty.total_spend '
  'decrements on cancellation — total_amount may change (refund, adjustment).';


-- ────────────────────────────────────────────────────────────
-- A7. Evolve loyalty
-- Add organization_id — changes loyalty from per-guest to per-guest-per-org.
-- Add confirmed_visits — excludes cancelled/no_show (replaces total_visits
--   for tier calculation; total_visits is retained for historical reporting).
--
-- IMPORTANT: The existing UNIQUE(guest_id) constraint is NOT removed here.
-- It will be dropped and replaced with UNIQUE(guest_id, organization_id)
-- in seed_simulation.sql AFTER existing rows are backfilled with organization_id.
-- Dropping the constraint before backfill would break the INSERT trigger.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.loyalty
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES public.organizations(id);

ALTER TABLE public.loyalty
  ADD COLUMN IF NOT EXISTS confirmed_visits INTEGER;

-- Backfill confirmed_visits from total_visits for existing rows
UPDATE public.loyalty
  SET confirmed_visits = total_visits
  WHERE confirmed_visits IS NULL;

COMMENT ON COLUMN public.loyalty.organization_id IS
  'Owning organization. Nullable until backfilled. '
  'After Phase C: becomes part of UNIQUE(guest_id, organization_id).';
COMMENT ON COLUMN public.loyalty.confirmed_visits IS
  'Visits excluding cancelled and no_show. Used for tier calculation. '
  'total_visits counts all reservation inserts including cancelled.';


-- ────────────────────────────────────────────────────────────
-- A8. loyalty_by_property
-- Property-level analytics. Separate from the org-wide loyalty table.
-- Org-wide loyalty drives tier (Bronze/Silver/Gold).
-- loyalty_by_property drives: per-property visit counts, per-property
-- revenue, "most visited property" insight, AI occupancy inputs.
-- UNIQUE(guest_id, property_id) — one row per guest per campground.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.loyalty_by_property (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  guest_id         UUID          NOT NULL REFERENCES public.guests(id)        ON DELETE CASCADE,
  property_id      UUID          NOT NULL REFERENCES public.properties(id)    ON DELETE CASCADE,
  organization_id  UUID          NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  confirmed_visits INTEGER       NOT NULL DEFAULT 0,
  total_spend      NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  last_visit       DATE,
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (guest_id, property_id)
);

COMMENT ON TABLE public.loyalty_by_property IS
  'Per-property visit analytics. One row per guest per campground. '
  'Feeds per-property reporting and AI occupancy inputs. '
  'Org-wide loyalty (tier) lives in the loyalty table — this is analytics only.';


-- ────────────────────────────────────────────────────────────
-- A9. Evolve webhook_events
-- Add organization_id + property_id for tenant-scoped event filtering.
-- Add retry_count + last_error for dead-letter queue pattern.
-- Add processed_at for latency monitoring.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES public.organizations(id);

ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS property_id UUID REFERENCES public.properties(id);

ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS retry_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS last_error TEXT;

ALTER TABLE public.webhook_events
  ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;

COMMENT ON COLUMN public.webhook_events.retry_count IS
  'Number of Make.com delivery attempts. Feeds dead-letter queue logic: '
  'events with retry_count >= 3 and status = failed are escalated.';
COMMENT ON COLUMN public.webhook_events.processed_at IS
  'Timestamp when Make.com PATCHed status to sent. '
  'processed_at - created_at = automation latency for monitoring.';


-- ────────────────────────────────────────────────────────────
-- A10. Indexes — all new FK and high-cardinality query columns
-- Every organization_id column gets an index because RLS policies
-- will use equality checks on this column for every query.
-- ────────────────────────────────────────────────────────────

-- organizations
CREATE INDEX IF NOT EXISTS idx_organizations_slug
  ON public.organizations(slug);

CREATE INDEX IF NOT EXISTS idx_organizations_status
  ON public.organizations(status);

-- properties → organization
CREATE INDEX IF NOT EXISTS idx_properties_org_id
  ON public.properties(organization_id);

-- guest_org_profiles
CREATE INDEX IF NOT EXISTS idx_guest_org_profiles_guest_id
  ON public.guest_org_profiles(guest_id);

CREATE INDEX IF NOT EXISTS idx_guest_org_profiles_org_id
  ON public.guest_org_profiles(organization_id);

CREATE INDEX IF NOT EXISTS idx_guest_org_profiles_ghl_contact_id
  ON public.guest_org_profiles(ghl_contact_id);

-- reservations → organization, property
CREATE INDEX IF NOT EXISTS idx_reservations_org_id
  ON public.reservations(organization_id);

CREATE INDEX IF NOT EXISTS idx_reservations_property_id
  ON public.reservations(property_id);

-- Compound: org + date range filtering (occupancy queries)
CREATE INDEX IF NOT EXISTS idx_reservations_org_checkin
  ON public.reservations(organization_id, check_in);

-- loyalty → organization
CREATE INDEX IF NOT EXISTS idx_loyalty_org_id
  ON public.loyalty(organization_id);

-- loyalty compound for tier reporting per org
CREATE INDEX IF NOT EXISTS idx_loyalty_org_tier
  ON public.loyalty(organization_id, tier);

-- loyalty_by_property
CREATE INDEX IF NOT EXISTS idx_lbp_guest_id
  ON public.loyalty_by_property(guest_id);

CREATE INDEX IF NOT EXISTS idx_lbp_property_id
  ON public.loyalty_by_property(property_id);

CREATE INDEX IF NOT EXISTS idx_lbp_org_id
  ON public.loyalty_by_property(organization_id);

-- user_roles
CREATE INDEX IF NOT EXISTS idx_user_roles_user_id
  ON public.user_roles(user_id);

CREATE INDEX IF NOT EXISTS idx_user_roles_org_id
  ON public.user_roles(organization_id);

CREATE INDEX IF NOT EXISTS idx_user_roles_property_id
  ON public.user_roles(property_id)
  WHERE property_id IS NOT NULL;

-- webhook_events → organization
CREATE INDEX IF NOT EXISTS idx_webhook_events_org_id
  ON public.webhook_events(organization_id);


-- ────────────────────────────────────────────────────────────
-- A11. RLS — enable on new tables with demo-permissive policies
-- These allow the React frontend (anon key) to read and write
-- all rows for simulation purposes.
-- Replace with tenant-scoped policies before adding real auth.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.organizations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guest_org_profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty_by_property ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_organizations"       ON public.organizations;
CREATE POLICY "demo_allow_all_organizations"
  ON public.organizations FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_users"               ON public.users;
CREATE POLICY "demo_allow_all_users"
  ON public.users FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_user_roles"          ON public.user_roles;
CREATE POLICY "demo_allow_all_user_roles"
  ON public.user_roles FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_guest_org_profiles"  ON public.guest_org_profiles;
CREATE POLICY "demo_allow_all_guest_org_profiles"
  ON public.guest_org_profiles FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_loyalty_by_property" ON public.loyalty_by_property;
CREATE POLICY "demo_allow_all_loyalty_by_property"
  ON public.loyalty_by_property FOR ALL USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- A12. Grants — new tables need explicit GRANT to anon / authenticated
-- ────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON public.organizations       TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.users               TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_roles          TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.guest_org_profiles  TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.loyalty_by_property TO anon, authenticated;


-- ────────────────────────────────────────────────────────────
-- A13. Updated views — add property and org context
-- Drop-and-recreate is safe because we are changing column lists.
-- ────────────────────────────────────────────────────────────

-- reservation_detail: add property_id, property_name, organization_id
DROP VIEW IF EXISTS public.reservation_detail;
CREATE VIEW public.reservation_detail
WITH (security_invoker = true)
AS
SELECT
  r.id,
  r.external_reservation_id,
  r.organization_id,
  r.property_id,
  p.name                                  AS property_name,
  r.guest_id,
  (g.first_name || ' ' || g.last_name)   AS guest_name,
  g.email,
  r.site_number,
  r.check_in,
  r.check_out,
  (r.check_out - r.check_in)             AS num_nights,
  r.num_guests,
  r.nightly_rate,
  r.total_amount,
  r.status,
  r.notes,
  r.created_at
FROM public.reservations r
JOIN public.guests g     ON g.id = r.guest_id
LEFT JOIN public.properties p ON p.id = r.property_id;

GRANT SELECT ON public.reservation_detail TO anon, authenticated;

COMMENT ON VIEW public.reservation_detail IS
  'Reservations with guest name, property name, and org_id. '
  'Filter by organization_id for tenant-scoped display.';

-- guest_summary: updated to also pull from guest_org_profiles when available
-- Falls back to guests table PII (legacy columns) when no profile exists.
DROP VIEW IF EXISTS public.guest_summary;
CREATE VIEW public.guest_summary AS
SELECT
  g.id,
  COALESCE(gop.first_name, g.first_name)             AS first_name,
  COALESCE(gop.last_name,  g.last_name)              AS last_name,
  (COALESCE(gop.first_name, g.first_name) || ' ' ||
   COALESCE(gop.last_name,  g.last_name))            AS full_name,
  g.email,
  COALESCE(gop.phone, g.phone)                       AS phone,
  COALESCE(gop.ghl_contact_id, g.ghl_contact_id)    AS ghl_contact_id,
  gop.organization_id,
  COALESCE(l.total_visits,    0)                     AS total_visits,
  COALESCE(l.confirmed_visits, l.total_visits, 0)    AS confirmed_visits,
  COALESCE(l.total_spend,     0.00)                  AS total_spend,
  COALESCE(l.tier, 'Bronze')                         AS loyalty_tier,
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
  'Guests with loyalty state and org-scoped PII. '
  'When organization_id is present, filter by it to get org-scoped view. '
  'Falls back to guests table PII for pre-migration rows.';

-- kpi_summary: add org_id column so frontend can filter
-- kpi_summary remains global in demo mode (no RLS active).
-- After RLS is enabled, this view is replaced by an org-scoped function.
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
  (SELECT COUNT(*) FROM public.guest_org_profiles
   WHERE ghl_contact_id IS NOT NULL)                                AS synced_contacts,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'pending')  AS pending_webhooks,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'failed')   AS failed_webhooks;

GRANT SELECT ON public.kpi_summary TO anon, authenticated;
