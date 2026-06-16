-- ============================================================
-- MIGRATION v5 → v6: Onboarding Infrastructure
-- Campground Guest Management & Revenue Intelligence
--
-- WHAT THIS FILE DOES:
--   STEP  1 — loyalty_config table (per-org Silver/Gold thresholds)
--   STEP  2 — Backfill loyalty_config for existing orgs (platform defaults)
--   STEP  3 — GAP 3 FIX: DROP + recreate calculate_tier()
--               Old: calculate_tier(INTEGER)  IMMUTABLE  (hardcoded 3/6)
--               New: calculate_tier(INTEGER, UUID DEFAULT NULL)  STABLE
--               Looks up org thresholds; falls back to platform defaults.
--               CANNOT use CREATE OR REPLACE to change volatility.
--   STEP  4 — Update handle_reservation_status_change() to pass
--               organization_id to calculate_tier() for org-aware tiers.
--   STEP  5 — Recalibrate existing loyalty tiers with new function.
--               No-op when org thresholds = platform defaults (3/6).
--   STEP  6 — pms_integrations table (Campspot, RezWorks, Hostfully, etc.)
--   STEP  7 — pms_integrations_safe view (excludes credentials)
--   STEP  8 — invitations table (token-based, 7-day expiry, single-use)
--   STEP  9 — onboarding_sessions table (7-step tracking per org)
--   STEP 10 — Backfill onboarding_sessions for existing orgs (mark complete)
--   STEP 11 — Indexes
--   STEP 12 — RLS + Grants
--   STEP 13 — Verification queries (commented)
--
-- SAFETY CONTRACT:
--   • All CREATE TABLE / ALTER TABLE use IF NOT EXISTS
--   • DROP FUNCTION is scoped to exact signature — other overloads unaffected
--   • Trigger function update uses CREATE OR REPLACE (volatility not changed)
--   • Backfills are idempotent: ON CONFLICT DO NOTHING / WHERE ... IS NULL
--   • No columns dropped, no rows deleted
--
-- EXECUTION ORDER:
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3 → migrate_v4 → migrate_v5 → [THIS FILE]
-- ============================================================


-- ============================================================
-- STEP 1: loyalty_config
-- One row per organization. Stores Silver and Gold visit thresholds.
-- Platform defaults: Silver=3, Gold=6 (matches hardcoded v1 values).
-- UNIQUE(organization_id) — one config per org.
-- CHECK constraint ensures Silver < Gold and Silver >= 1.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.loyalty_config (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID        UNIQUE NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  silver_threshold    INTEGER     NOT NULL DEFAULT 3,
  gold_threshold      INTEGER     NOT NULL DEFAULT 6,
  CONSTRAINT loyalty_config_thresholds_ordered
    CHECK (silver_threshold >= 1 AND gold_threshold > silver_threshold),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.loyalty_config IS
  'Per-org loyalty tier thresholds. One row per organization. '
  'silver_threshold = min confirmed visits for Silver tier. '
  'gold_threshold = min confirmed visits for Gold tier. '
  'Platform defaults: 3/6. calculate_tier() reads this table for org-aware tier calculation.';

COMMENT ON COLUMN public.loyalty_config.silver_threshold IS
  'Minimum confirmed_visits required for Silver tier. Default: 3. '
  'Must be >= 1 and < gold_threshold.';

COMMENT ON COLUMN public.loyalty_config.gold_threshold IS
  'Minimum confirmed_visits required for Gold tier. Default: 6. '
  'Must be > silver_threshold.';


-- ============================================================
-- STEP 2: Backfill loyalty_config for existing orgs
-- Inserts a platform-default row for every org that does not
-- already have a loyalty_config row. ON CONFLICT DO NOTHING
-- makes this safe to re-run.
-- ============================================================
INSERT INTO public.loyalty_config (organization_id, silver_threshold, gold_threshold)
SELECT id, 3, 6
FROM public.organizations
ON CONFLICT (organization_id) DO NOTHING;


-- ============================================================
-- STEP 3: Gap 3 Fix — DROP + recreate calculate_tier()
--
-- WHY DROP instead of CREATE OR REPLACE:
--   PostgreSQL does not allow changing a function's volatility
--   via CREATE OR REPLACE. The v1 function is IMMUTABLE (correct
--   when thresholds were hardcoded constants). The new function
--   reads loyalty_config, which changes over time → must be STABLE.
--
-- BACKWARD COMPATIBILITY:
--   New signature: calculate_tier(visits INTEGER, p_org_id UUID DEFAULT NULL)
--   Old callers that pass one argument continue to work unchanged —
--   p_org_id defaults to NULL → falls back to platform defaults (3/6).
--   This means v3 trigger functions remain safe to call even before
--   they are updated in Step 4.
--
-- DEPENDENCY CHECK:
--   Functions referencing calculate_tier() store the call as text —
--   PostgreSQL does not create hard dependencies on called functions
--   in plpgsql function bodies. DROP without CASCADE is safe here.
-- ============================================================

DROP FUNCTION IF EXISTS public.calculate_tier(INTEGER);

CREATE OR REPLACE FUNCTION public.calculate_tier(
  visits    INTEGER,
  p_org_id  UUID    DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_silver INTEGER;
  v_gold   INTEGER;
BEGIN
  -- Look up org-specific thresholds when org_id is provided.
  IF p_org_id IS NOT NULL THEN
    SELECT silver_threshold, gold_threshold
    INTO   v_silver, v_gold
    FROM   public.loyalty_config
    WHERE  organization_id = p_org_id;
  END IF;

  -- Fall back to platform defaults if no org config found (or org_id not passed).
  v_silver := COALESCE(v_silver, 3);
  v_gold   := COALESCE(v_gold,   6);

  IF    visits >= v_gold   THEN RETURN 'Gold';
  ELSIF visits >= v_silver THEN RETURN 'Silver';
  ELSE                          RETURN 'Bronze';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.calculate_tier(INTEGER, UUID) IS
  'Returns the loyalty tier (Bronze/Silver/Gold) for a given confirmed visit count. '
  'p_org_id: reads silver_threshold and gold_threshold from loyalty_config for this org. '
  'p_org_id = NULL: uses platform defaults (silver=3, gold=6). '
  'STABLE: reads loyalty_config which may change between transactions. '
  'Replaces v1 IMMUTABLE calculate_tier(INTEGER) which had hardcoded thresholds.';

-- Re-grant execute so all existing callers retain access
GRANT EXECUTE ON FUNCTION public.calculate_tier(INTEGER, UUID) TO anon, authenticated;


-- ============================================================
-- STEP 4: Update handle_reservation_status_change()
-- Pass NEW.organization_id to calculate_tier() so org-specific
-- thresholds are used at checkout.
--
-- Only the two calculate_tier() call sites change.
-- Entire function reproduced here because CREATE OR REPLACE
-- replaces the complete function body.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_reservation_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_type TEXT;
  v_payload    JSONB;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  v_event_type := CASE NEW.status
    WHEN 'checked_in'  THEN 'reservation.checked_in'
    WHEN 'checked_out' THEN 'reservation.checked_out'
    WHEN 'cancelled'   THEN 'reservation.cancelled'
    WHEN 'no_show'     THEN 'reservation.no_show'
    ELSE NULL
  END;

  IF v_event_type IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'checked_out' THEN

    INSERT INTO public.loyalty (
      guest_id,
      organization_id,
      total_visits,
      confirmed_visits,
      total_spend,
      tier,
      last_visit,
      updated_at
    )
    VALUES (
      NEW.guest_id,
      NEW.organization_id,
      1,
      1,
      COALESCE(NEW.total_amount, 0.00),
      -- v6: pass organization_id for org-aware tier thresholds
      public.calculate_tier(1, NEW.organization_id),
      NEW.check_out,
      NOW()
    )
    ON CONFLICT (guest_id, organization_id) DO UPDATE
      SET confirmed_visits = COALESCE(public.loyalty.confirmed_visits, 0) + 1,
          total_spend      = COALESCE(public.loyalty.total_spend, 0.00)
                             + COALESCE(NEW.total_amount, 0.00),
          -- v6: pass organization_id for org-aware tier thresholds
          tier             = public.calculate_tier(
                               COALESCE(public.loyalty.confirmed_visits, 0) + 1,
                               NEW.organization_id
                             ),
          last_visit       = NEW.check_out,
          updated_at       = NOW();

    IF NEW.property_id IS NOT NULL THEN
      INSERT INTO public.loyalty_by_property (
        guest_id,
        property_id,
        organization_id,
        confirmed_visits,
        total_spend,
        last_visit,
        updated_at
      )
      VALUES (
        NEW.guest_id,
        NEW.property_id,
        NEW.organization_id,
        1,
        COALESCE(NEW.total_amount, 0.00),
        NEW.check_out,
        NOW()
      )
      ON CONFLICT (guest_id, property_id) DO UPDATE
        SET confirmed_visits = public.loyalty_by_property.confirmed_visits + 1,
            total_spend      = public.loyalty_by_property.total_spend
                               + COALESCE(NEW.total_amount, 0.00),
            last_visit       = NEW.check_out,
            updated_at       = NOW();
    END IF;

  END IF;

  SELECT jsonb_build_object(
    'event',           v_event_type,
    'timestamp',       to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source',          'campground-saas',
    'organization_id', NEW.organization_id,
    'property_id',     NEW.property_id,
    'previous_status', OLD.status,
    'new_status',      NEW.status,

    'organization', (
      SELECT jsonb_build_object(
        'id',              o.id,
        'name',            o.name,
        'ghl_location_id', o.ghl_location_id
      )
      FROM public.organizations o
      WHERE o.id = NEW.organization_id
    ),

    'property', (
      SELECT jsonb_build_object('id', p.id, 'name', p.name)
      FROM public.properties p
      WHERE p.id = NEW.property_id
    ),

    'reservation', jsonb_build_object(
      'id',                      NEW.id,
      'external_reservation_id', NEW.external_reservation_id,
      'site_number',             NEW.site_number,
      'check_in',                to_char(NEW.check_in,  'YYYY-MM-DD'),
      'check_out',               to_char(NEW.check_out, 'YYYY-MM-DD'),
      'num_nights',              (NEW.check_out - NEW.check_in),
      'num_guests',              NEW.num_guests,
      'nightly_rate',            NEW.nightly_rate,
      'total_amount',            NEW.total_amount,
      'status',                  NEW.status,
      'notes',                   COALESCE(NEW.notes, '')
    ),

    'guest', (
      SELECT jsonb_build_object('id', g.id, 'email', g.email)
      FROM public.guests g
      WHERE g.id = NEW.guest_id
    ),

    'guest_profile', (
      SELECT jsonb_build_object(
        'first_name',      gop.first_name,
        'last_name',       gop.last_name,
        'phone',           COALESCE(gop.phone, ''),
        'crm_contact_ids', gop.crm_contact_ids
      )
      FROM public.guest_org_profiles gop
      WHERE gop.guest_id        = NEW.guest_id
        AND gop.organization_id = NEW.organization_id
        AND gop.deleted_at      IS NULL
    ),

    'loyalty', (
      SELECT jsonb_build_object(
        'total_visits',     l.total_visits,
        'confirmed_visits', COALESCE(l.confirmed_visits, 0),
        'total_spend',      COALESCE(l.total_spend, 0.00),
        'tier',             l.tier,
        'is_returning',     (COALESCE(l.confirmed_visits, 0) > 1)
      )
      FROM public.loyalty l
      WHERE l.guest_id        = NEW.guest_id
        AND l.organization_id = NEW.organization_id
    )

  ) INTO v_payload;

  INSERT INTO public.webhook_events (
    event_type,
    reservation_id,
    organization_id,
    property_id,
    payload
  )
  VALUES (
    v_event_type,
    NEW.id,
    NEW.organization_id,
    NEW.property_id,
    v_payload
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_reservation_status_change IS
  'AFTER UPDATE OF status trigger on reservations (v6). '
  'Credits confirmed_visits + total_spend on checked_out only. '
  'Fires domain event webhooks for all status transitions. '
  'v6 change: calculate_tier() now receives organization_id for per-org thresholds. '
  'Cancellations require no loyalty reversal — loyalty never credited at booking.';

-- Also update guest_profile in handle_new_reservation to use crm_contact_ids
-- (ghl_contact_id deprecated in v5). CREATE OR REPLACE preserves the trigger wire.
CREATE OR REPLACE FUNCTION public.handle_new_reservation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payload JSONB;
BEGIN
  IF NEW.status IN ('cancelled', 'no_show') THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.loyalty (
    guest_id,
    organization_id,
    total_visits,
    confirmed_visits,
    total_spend,
    tier,
    last_visit,
    updated_at
  )
  VALUES (
    NEW.guest_id,
    NEW.organization_id,
    1,
    0,
    0.00,
    'Bronze',
    NULL,
    NOW()
  )
  ON CONFLICT (guest_id, organization_id) DO UPDATE
    SET total_visits = public.loyalty.total_visits + 1,
        updated_at   = NOW();

  IF NEW.property_id IS NOT NULL THEN
    INSERT INTO public.loyalty_by_property (
      guest_id,
      property_id,
      organization_id,
      confirmed_visits,
      total_spend,
      last_visit,
      updated_at
    )
    VALUES (
      NEW.guest_id,
      NEW.property_id,
      NEW.organization_id,
      0,
      0.00,
      NULL,
      NOW()
    )
    ON CONFLICT (guest_id, property_id) DO NOTHING;
  END IF;

  SELECT jsonb_build_object(
    'event',           'reservation.created',
    'timestamp',       to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source',          'campground-saas',
    'organization_id', NEW.organization_id,
    'property_id',     NEW.property_id,

    'organization', (
      SELECT jsonb_build_object(
        'id',              o.id,
        'name',            o.name,
        'ghl_location_id', o.ghl_location_id
      )
      FROM public.organizations o
      WHERE o.id = NEW.organization_id
    ),

    'property', (
      SELECT jsonb_build_object('id', p.id, 'name', p.name)
      FROM public.properties p
      WHERE p.id = NEW.property_id
    ),

    'reservation', jsonb_build_object(
      'id',                      NEW.id,
      'external_reservation_id', NEW.external_reservation_id,
      'site_number',             NEW.site_number,
      'check_in',                to_char(NEW.check_in,  'YYYY-MM-DD'),
      'check_out',               to_char(NEW.check_out, 'YYYY-MM-DD'),
      'num_nights',              (NEW.check_out - NEW.check_in),
      'num_guests',              NEW.num_guests,
      'nightly_rate',            NEW.nightly_rate,
      'total_amount',            NEW.total_amount,
      'status',                  NEW.status,
      'notes',                   COALESCE(NEW.notes, '')
    ),

    'guest', (
      SELECT jsonb_build_object('id', g.id, 'email', g.email)
      FROM public.guests g
      WHERE g.id = NEW.guest_id
    ),

    'guest_profile', (
      SELECT jsonb_build_object(
        'first_name',      gop.first_name,
        'last_name',       gop.last_name,
        'phone',           COALESCE(gop.phone, ''),
        'crm_contact_ids', gop.crm_contact_ids
      )
      FROM public.guest_org_profiles gop
      WHERE gop.guest_id        = NEW.guest_id
        AND gop.organization_id = NEW.organization_id
        AND gop.deleted_at      IS NULL
    ),

    'loyalty', (
      SELECT jsonb_build_object(
        'total_visits',     l.total_visits,
        'confirmed_visits', COALESCE(l.confirmed_visits, 0),
        'total_spend',      COALESCE(l.total_spend, 0.00),
        'tier',             l.tier,
        'is_returning',     (l.total_visits > 1)
      )
      FROM public.loyalty l
      WHERE l.guest_id        = NEW.guest_id
        AND l.organization_id = NEW.organization_id
    )

  ) INTO v_payload;

  INSERT INTO public.webhook_events (
    event_type,
    reservation_id,
    organization_id,
    property_id,
    payload
  )
  VALUES (
    'reservation.created',
    NEW.id,
    NEW.organization_id,
    NEW.property_id,
    v_payload
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_reservation IS
  'AFTER INSERT trigger on reservations (v6). '
  'Increments total_visits only — booking-intent counter. '
  'confirmed_visits and total_spend credited by handle_reservation_status_change() at checkout. '
  'v6 change: guest_profile payload now uses crm_contact_ids instead of deprecated ghl_contact_id.';


-- ============================================================
-- STEP 5: Recalibrate existing loyalty tiers
-- Re-runs calculate_tier() with org-aware thresholds for all rows.
-- For orgs with platform-default loyalty_config (silver=3, gold=6),
-- this updates 0 rows — the computed value matches what was stored.
-- Included for correctness: if any org's loyalty_config was manually
-- set to non-default thresholds before this migration ran, this
-- recalibrates tier to match those thresholds.
-- ============================================================
UPDATE public.loyalty l
SET
  tier       = public.calculate_tier(COALESCE(l.confirmed_visits, 0), l.organization_id),
  updated_at = NOW()
WHERE l.tier IS DISTINCT FROM
      public.calculate_tier(COALESCE(l.confirmed_visits, 0), l.organization_id);


-- ============================================================
-- STEP 6: pms_integrations
-- One row per PMS provider per organization.
-- Follows the same security pattern as crm_integrations:
--   credentials JSONB — never SELECT from base table in frontend.
--   All frontend reads go through pms_integrations_safe view.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.pms_integrations (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider            TEXT        NOT NULL
                      CHECK (provider IN (
                        'campspot', 'rezworks', 'hostfully',
                        'rvshare', 'hipcamp', 'direct', 'none'
                      )),
  name                TEXT        NOT NULL,
  external_property_id TEXT,
  -- Provider-specific property/location reference:
  -- Campspot: property_id. RezWorks: site_id. Hostfully: agency_uid.
  credentials         JSONB       NOT NULL DEFAULT '{}',
  -- API key, OAuth tokens, webhook signing secrets.
  -- NEVER expose to frontend.
  config              JSONB       NOT NULL DEFAULT '{}',
  -- Non-secret: webhook receive URL, field mappings, sync interval,
  -- reservation status mapping (PMS status → platform status).
  sync_direction      TEXT        NOT NULL DEFAULT 'inbound'
                      CHECK (sync_direction IN ('inbound', 'bidirectional', 'outbound')),
  -- inbound:       PMS → platform (PMS is source of truth for reservations)
  -- outbound:      platform → PMS (platform pushes availability to PMS)
  -- bidirectional: both directions
  status              TEXT        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'inactive', 'error')),
  last_sync_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, provider)
);

COMMENT ON TABLE public.pms_integrations IS
  'Property Management System configurations per organization. '
  'One row per PMS provider per org. Covers reservation ingestion sources: '
  'Campspot, RezWorks, Hostfully, RVshare, Hipcamp, direct booking. '
  'credentials column: NEVER expose to frontend. Reads via pms_integrations_safe.';

COMMENT ON COLUMN public.pms_integrations.sync_direction IS
  'inbound: PMS sends reservations to platform (most common). '
  'outbound: platform pushes availability/rates to PMS. '
  'bidirectional: both.';

COMMENT ON COLUMN public.pms_integrations.config IS
  'Non-secret integration config. Safe for authenticated reads. '
  'Keys: webhook_receive_url (PMS sends reservation events here), '
  'status_map (PMS status string → platform confirmed/checked_in/etc.), '
  'field_map (PMS field → platform reservation field).';


-- ============================================================
-- STEP 7: pms_integrations_safe view
-- Excludes credentials column. security_invoker = true.
-- ============================================================
CREATE OR REPLACE VIEW public.pms_integrations_safe
WITH (security_invoker = true)
AS
SELECT
  id,
  organization_id,
  provider,
  name,
  external_property_id,
  config,
  sync_direction,
  status,
  last_sync_at,
  created_at,
  updated_at
FROM public.pms_integrations;

COMMENT ON VIEW public.pms_integrations_safe IS
  'Read-only view of pms_integrations with credentials column excluded. '
  'Use this view for all frontend and authenticated-role reads. '
  'security_invoker = true ensures RLS on the base table applies in caller context.';


-- ============================================================
-- STEP 8: invitations
-- Token-based invitations for adding staff to an organization.
-- Workflow:
--   1. Owner/manager creates invitation → token generated, email sent
--   2. Invitee clicks link with token → creates Supabase Auth account
--   3. On signup, claim_invitation() (future function) links token →
--      creates public.users row + user_roles row → marks accepted
--
-- Token: 64-char hex string (32 random bytes via pgcrypto).
-- Expiry: 7 days from creation.
-- Single-use: accepted_at IS NULL check in partial unique index.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.invitations (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invited_email   TEXT        NOT NULL,
  role            TEXT        NOT NULL DEFAULT 'staff'
                  CHECK (role IN ('owner', 'manager', 'staff', 'viewer')),
  property_id     UUID        REFERENCES public.properties(id) ON DELETE SET NULL,
  -- NULL = org-wide access at the given role. Set = property-scoped.
  token           TEXT        UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days',
  accepted_at     TIMESTAMPTZ,
  accepted_by     UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  created_by      UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  revoked_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.invitations IS
  'Token-based invitations for adding users to an organization. '
  'token: 64-char hex, single-use. expires_at: 7 days from creation. '
  'accepted_at NULL = pending. accepted_at SET = claimed. '
  'revoked_at SET = cancelled by owner/manager before acceptance.';

COMMENT ON COLUMN public.invitations.token IS
  '64-char hex token (32 random bytes). Sent in invitation email URL. '
  'Single-use: accepted_at is set on first claim, blocking re-use. '
  'UNIQUE constraint prevents token collisions across all orgs.';

COMMENT ON COLUMN public.invitations.property_id IS
  'NULL = org-wide access at the specified role. '
  'Set = access scoped to this property only. '
  'Matches the property_id semantics of user_roles.';

COMMENT ON COLUMN public.invitations.accepted_by IS
  'The public.users.id of the user who accepted the invitation. '
  'Set during claim flow after Supabase Auth account creation.';


-- ============================================================
-- STEP 9: onboarding_sessions
-- Tracks 7-step onboarding completion per organization.
-- One row per org. current_step is the step currently in progress.
-- completed_steps is an integer array of finished step numbers.
--
-- Step definitions:
--   1 — Organization basics       (name, slug, plan)
--   2 — First property            (property name, sites, timezone)
--   3 — Loyalty configuration     (silver/gold thresholds)
--   4 — CRM integration           (GHL / HubSpot / Salesforce)
--   5 — PMS integration           (Campspot / RezWorks / Hostfully)
--   6 — Staff invitations         (invite team members)
--   7 — Test reservation          (go-live smoke test)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.onboarding_sessions (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID        UNIQUE NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  current_step     INTEGER     NOT NULL DEFAULT 1
                   CHECK (current_step BETWEEN 1 AND 7),
  completed_steps  INTEGER[]   NOT NULL DEFAULT '{}',
  step_data        JSONB       NOT NULL DEFAULT '{}',
  -- Keyed by step number string: { "1": {...}, "2": {...} }
  -- Stores non-sensitive summary data from each completed step
  -- for display in the onboarding progress UI.
  is_complete      BOOLEAN     NOT NULL DEFAULT false,
  completed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.onboarding_sessions IS
  'Tracks 7-step onboarding progress per organization. One row per org. '
  'Steps: 1=org basics, 2=first property, 3=loyalty config, 4=CRM, '
  '5=PMS, 6=staff invitations, 7=test reservation. '
  'is_complete = true once all 7 steps are done.';

COMMENT ON COLUMN public.onboarding_sessions.completed_steps IS
  'Array of step numbers completed so far. e.g., {1,2,3}. '
  'Step is added when the user completes that step and advances. '
  'NOT necessarily sequential — users can skip and return.';

COMMENT ON COLUMN public.onboarding_sessions.step_data IS
  'Summary data from each completed step. Keyed by step number string. '
  'Example: {"1": {"org_name": "Aries Hospitality", "plan": "starter"}, '
  '"4": {"provider": "gohighlevel", "crm_integration_id": "uuid"}}. '
  'Used to populate the onboarding review page without re-querying all tables.';


-- ============================================================
-- STEP 10: Backfill onboarding_sessions for existing orgs
-- Existing orgs (created in seed_simulation.sql) are post-onboarding.
-- Mark all 7 steps complete. ON CONFLICT DO NOTHING = safe to re-run.
-- ============================================================
INSERT INTO public.onboarding_sessions (
  organization_id,
  current_step,
  completed_steps,
  step_data,
  is_complete,
  completed_at
)
SELECT
  id,
  7,
  '{1,2,3,4,5,6,7}'::INTEGER[],
  jsonb_build_object(
    '1', jsonb_build_object('org_name', name, 'slug', slug, 'plan', plan),
    '7', jsonb_build_object('note', 'backfilled — org pre-dates onboarding flow')
  ),
  true,
  created_at
FROM public.organizations
ON CONFLICT (organization_id) DO NOTHING;


-- ============================================================
-- STEP 11: Indexes
-- ============================================================

-- loyalty_config: primary lookup is by organization_id (already UNIQUE, indexed)
-- No additional indexes needed — the UNIQUE constraint covers all query patterns.

-- pms_integrations
CREATE INDEX IF NOT EXISTS idx_pms_integrations_org_id
  ON public.pms_integrations(organization_id);

CREATE INDEX IF NOT EXISTS idx_pms_integrations_provider
  ON public.pms_integrations(provider);

CREATE INDEX IF NOT EXISTS idx_pms_integrations_org_active
  ON public.pms_integrations(organization_id, status)
  WHERE status = 'active';

-- invitations: primary lookup paths
CREATE INDEX IF NOT EXISTS idx_invitations_org_id
  ON public.invitations(organization_id);

CREATE INDEX IF NOT EXISTS idx_invitations_token
  ON public.invitations(token);
  -- Covered by UNIQUE constraint but explicit for query planner visibility.

CREATE INDEX IF NOT EXISTS idx_invitations_invited_email
  ON public.invitations(invited_email);
  -- Lookup by email on signup to find pending invitations.

-- Partial unique: one pending invite per email per org.
-- Expired or revoked invites do not block re-inviting the same address.
CREATE UNIQUE INDEX IF NOT EXISTS idx_invitations_pending_unique
  ON public.invitations(organization_id, invited_email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- onboarding_sessions: primary lookup is by organization_id (already UNIQUE, indexed)
CREATE INDEX IF NOT EXISTS idx_onboarding_incomplete
  ON public.onboarding_sessions(organization_id)
  WHERE is_complete = false;
  -- Fast scan for orgs still in onboarding (dashboard banner, nudge emails).


-- ============================================================
-- STEP 12: RLS + Grants
-- ============================================================

-- loyalty_config
ALTER TABLE public.loyalty_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_loyalty_config" ON public.loyalty_config;
CREATE POLICY "demo_allow_all_loyalty_config"
  ON public.loyalty_config FOR ALL USING (true) WITH CHECK (true);
-- Template for real policy (apply after JWT hook verified):
--   USING (organization_id = jwt_org_id())
--   WITH CHECK (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))

GRANT SELECT, INSERT, UPDATE ON public.loyalty_config TO authenticated;
GRANT SELECT ON public.loyalty_config TO anon;
-- anon SELECT required: calculate_tier() (STABLE) reads this table from
-- DB trigger context where the role may be postgres or anon. Restricting
-- SELECT from anon would silently fall back to platform defaults in trigger
-- execution, masking org-specific thresholds.

-- pms_integrations
ALTER TABLE public.pms_integrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_pms_integrations" ON public.pms_integrations;
CREATE POLICY "demo_allow_all_pms_integrations"
  ON public.pms_integrations FOR ALL USING (true) WITH CHECK (true);
-- Template for real policy:
--   USING (organization_id = jwt_org_id())
--   WITH CHECK (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))

-- Same pattern as crm_integrations: no SELECT on base table, reads via safe view
GRANT INSERT, UPDATE, DELETE ON public.pms_integrations TO authenticated;
GRANT SELECT ON public.pms_integrations_safe TO authenticated;

-- invitations
ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_invitations" ON public.invitations;
CREATE POLICY "demo_allow_all_invitations"
  ON public.invitations FOR ALL USING (true) WITH CHECK (true);
-- Template for real policies:
--   SELECT: USING (organization_id = jwt_org_id())       -- members see org's invites
--   INSERT: WITH CHECK (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))
--   UPDATE: USING (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))
--   Token claim (special): a separate function with SECURITY DEFINER handles accepting
--   an invite by token — bypasses RLS for the narrow accept-by-token path.

GRANT SELECT, INSERT, UPDATE ON public.invitations TO authenticated;
-- anon can INSERT (pre-auth: user accepting invite before they have a session).
-- Scoped tightly in production by the claim_invitation() SECURITY DEFINER function.
GRANT INSERT ON public.invitations TO anon;

-- onboarding_sessions
ALTER TABLE public.onboarding_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_onboarding_sessions" ON public.onboarding_sessions;
CREATE POLICY "demo_allow_all_onboarding_sessions"
  ON public.onboarding_sessions FOR ALL USING (true) WITH CHECK (true);
-- Template for real policy:
--   USING (organization_id = jwt_org_id())
--   WITH CHECK (organization_id = jwt_org_id() AND jwt_role() IN ('owner', 'manager'))

GRANT SELECT, INSERT, UPDATE ON public.onboarding_sessions TO authenticated;
GRANT SELECT ON public.onboarding_sessions TO anon;


-- ============================================================
-- STEP 13: Verification queries (run manually after migration)
-- Uncomment each block individually to verify.
-- ============================================================

/*
-- 13a. Verify calculate_tier() was replaced with new signature
SELECT
  p.proname                                           AS function_name,
  pg_get_function_arguments(p.oid)                   AS arguments,
  p.provolatile                                       AS volatility,
  -- 'i' = IMMUTABLE, 's' = STABLE, 'v' = VOLATILE
  p.prosecdef                                        AS security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'calculate_tier';
-- Expected: ONE row with arguments = 'visits integer, p_org_id uuid DEFAULT NULL'
--           volatility = 's' (STABLE)
--           security_definer = false
-- NOT present: old signature 'visits integer' with volatility 'i' (IMMUTABLE)


-- 13b. Verify calculate_tier() returns correct values at each threshold
SELECT
  public.calculate_tier(0)  AS bronze_0,   -- Bronze
  public.calculate_tier(2)  AS bronze_2,   -- Bronze (< 3)
  public.calculate_tier(3)  AS silver_3,   -- Silver (= 3)
  public.calculate_tier(5)  AS silver_5,   -- Silver (< 6)
  public.calculate_tier(6)  AS gold_6,     -- Gold   (= 6)
  public.calculate_tier(99) AS gold_99;    -- Gold
-- Expected: bronze_0=Bronze, bronze_2=Bronze, silver_3=Silver,
--           silver_5=Silver, gold_6=Gold, gold_99=Gold


-- 13c. Verify org-aware calculate_tier() with a custom loyalty_config
-- (Run in a transaction to isolate the temporary config change)
BEGIN;

  -- Temporarily set a different threshold for Aries org
  UPDATE public.loyalty_config
    SET silver_threshold = 2, gold_threshold = 4
    WHERE organization_id = '00000000-0000-0000-0000-000000000001';

  SELECT
    public.calculate_tier(1, '00000000-0000-0000-0000-000000000001') AS tier_1_visit,
    -- Expected: Bronze (1 < 2)
    public.calculate_tier(2, '00000000-0000-0000-0000-000000000001') AS tier_2_visits,
    -- Expected: Silver (2 >= 2)
    public.calculate_tier(4, '00000000-0000-0000-0000-000000000001') AS tier_4_visits,
    -- Expected: Gold (4 >= 4)
    public.calculate_tier(4)  AS tier_4_no_org;
    -- Expected: Silver (4 < 6 using platform defaults — org_id not passed)

ROLLBACK;
-- After ROLLBACK: loyalty_config reverts to 3/6. No permanent data change.


-- 13d. Verify loyalty_config backfill
SELECT
  o.name              AS org_name,
  lc.silver_threshold,
  lc.gold_threshold
FROM public.loyalty_config lc
JOIN public.organizations o ON o.id = lc.organization_id
ORDER BY o.name;
-- Expected: one row per org, silver_threshold=3, gold_threshold=6


-- 13e. Verify loyalty tier recalibration (Step 5 should be a no-op for demo data)
SELECT
  o.name                                                             AS organization,
  l.confirmed_visits,
  l.tier                                                            AS stored_tier,
  public.calculate_tier(
    COALESCE(l.confirmed_visits, 0), l.organization_id
  )                                                                  AS computed_tier,
  (l.tier = public.calculate_tier(
    COALESCE(l.confirmed_visits, 0), l.organization_id
  ))                                                                 AS tier_is_correct
FROM public.loyalty l
JOIN public.organizations o ON o.id = l.organization_id
ORDER BY o.name;
-- Expected: tier_is_correct = true for all rows


-- 13f. Verify pms_integrations and pms_integrations_safe exist
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pms_integrations_safe'
ORDER BY ordinal_position;
-- Expected: id, organization_id, provider, name, external_property_id,
--           config, sync_direction, status, last_sync_at, created_at, updated_at
-- NOT present: credentials


-- 13g. Verify invitations token uniqueness and default token generation
INSERT INTO public.invitations (organization_id, invited_email, role)
SELECT id, 'test-invite@example.com', 'staff'
FROM public.organizations LIMIT 1
RETURNING id, invited_email, role, LEFT(token, 8) AS token_prefix,
          LENGTH(token) AS token_length, expires_at;
-- Expected: token_length = 64, expires_at ≈ NOW() + 7 days

-- Clean up test invite
DELETE FROM public.invitations WHERE invited_email = 'test-invite@example.com';


-- 13h. Verify pending-unique partial index blocks duplicate pending invites
-- (Only one pending invite per email per org allowed)
DO $$
DECLARE
  v_org_id UUID;
BEGIN
  SELECT id INTO v_org_id FROM public.organizations LIMIT 1;

  INSERT INTO public.invitations (organization_id, invited_email, role)
  VALUES (v_org_id, 'dup-test@example.com', 'staff');

  BEGIN
    INSERT INTO public.invitations (organization_id, invited_email, role)
    VALUES (v_org_id, 'dup-test@example.com', 'viewer');
    RAISE EXCEPTION 'Expected unique violation but got none';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'Correctly blocked duplicate pending invite — partial index working';
  END;

  DELETE FROM public.invitations WHERE invited_email = 'dup-test@example.com';
END;
$$;
-- Expected: NOTICE: Correctly blocked duplicate pending invite — partial index working


-- 13i. Verify onboarding_sessions backfill
SELECT
  o.name                AS org_name,
  os.current_step,
  os.completed_steps,
  os.is_complete,
  os.completed_at IS NOT NULL AS has_completed_at
FROM public.onboarding_sessions os
JOIN public.organizations o ON o.id = os.organization_id
ORDER BY o.name;
-- Expected: one row per org, current_step=7, completed_steps={1,2,3,4,5,6,7},
--           is_complete=true, has_completed_at=true


-- 13j. Verify all new tables exist with RLS enabled
SELECT
  tablename,
  rowsecurity AS rls_enabled
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('loyalty_config', 'pms_integrations', 'invitations', 'onboarding_sessions')
ORDER BY tablename;
-- Expected: 4 rows, all with rls_enabled = true


-- 13k. Verify indexes
SELECT indexname, tablename
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_pms_integrations_org_id',
    'idx_pms_integrations_provider',
    'idx_pms_integrations_org_active',
    'idx_invitations_org_id',
    'idx_invitations_token',
    'idx_invitations_invited_email',
    'idx_invitations_pending_unique',
    'idx_onboarding_incomplete'
  )
ORDER BY indexname;
-- Expected: 8 rows
*/


-- ────────────────────────────────────────────────────────────
-- Post-migration checklist (manual steps)
-- ────────────────────────────────────────────────────────────

/*
STEP A — Verify no regression in loyalty tier calculation
  Run block 13b and 13e. Confirm all existing tiers are correct
  and calculate_tier() returns expected values at each threshold.
  Run 13c to confirm org-aware thresholds work correctly (uses
  a transaction — safe to run on production).

STEP B — Update loyalty_config via org settings page
  When the React onboarding wizard (Step 3) writes loyalty thresholds:

    PATCH /rest/v1/loyalty_config
          ?organization_id=eq.{org_id}
    Body: { "silver_threshold": 3, "gold_threshold": 6 }

  Loyalty tiers for existing guests are NOT automatically recalibrated
  when thresholds change — they update on next checkout via trigger.
  To force a bulk recalibration after a threshold change:

    UPDATE loyalty
    SET tier = calculate_tier(COALESCE(confirmed_visits, 0), organization_id)
    WHERE organization_id = '{org_id}'
      AND tier != calculate_tier(COALESCE(confirmed_visits, 0), organization_id);

STEP C — PMS integration setup (onboarding Step 5)
  When an org selects a PMS provider in the onboarding wizard:

    POST /rest/v1/pms_integrations
    Body: {
      "organization_id": "{org_id}",
      "provider": "campspot",
      "name": "Aries — Campspot",
      "external_property_id": "{campspot_property_id}",
      "credentials": {},         ← Write via service role key only
      "config": {
        "webhook_receive_url": "https://hook.make.com/...",
        "status_map": {
          "confirmed": "confirmed",
          "checked_in": "checked_in",
          "checked_out": "checked_out",
          "cancelled": "cancelled"
        }
      },
      "sync_direction": "inbound"
    }

  Frontend reads via pms_integrations_safe (no credentials column).
  credentials are written via service role key (server-side / Make.com).

STEP D — Invitation claim flow (future claim_invitation() function)
  When an invitee clicks their invitation link and creates an account:
  1. Look up invitation by token: SELECT * FROM invitations WHERE token = ?
     AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > NOW()
  2. Create public.users row linked to their new auth_user_id
  3. Insert user_roles row with role and property_id from the invitation
  4. Mark invitation claimed: UPDATE invitations SET accepted_at = NOW(),
     accepted_by = {new_user_id} WHERE token = ?
  5. Update users.active_org_id = invitation.organization_id
  6. Trigger JWT refresh: supabase.auth.refreshSession()

  The claim_invitation() SECURITY DEFINER function (future migrate_v7)
  wraps all of these steps in a single transaction.

STEP E — Onboarding step completion events
  When an org completes a step in the wizard, update onboarding_sessions:

    PATCH /rest/v1/onboarding_sessions
          ?organization_id=eq.{org_id}
    Body: {
      "current_step": {next_step},
      "completed_steps": {1,2,...,{step}},
      "step_data": { "{step}": {step_summary_data} },
      "is_complete": false,
      "updated_at": "{now}"
    }

  When Step 7 completes (test reservation), set is_complete = true,
  completed_at = now().
*/
