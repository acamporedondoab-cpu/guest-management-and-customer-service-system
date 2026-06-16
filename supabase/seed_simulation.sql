-- ============================================================
-- SIMULATION SEED — Multi-Tenant Demo Data
-- Campground Guest Management & Revenue Intelligence
--
-- RUN AFTER: supabase/migrate_v2_multi_tenant.sql
--
-- This file handles:
--   Phase B: Simulation data (organizations, properties, users, guest)
--   Phase C: Loyalty constraint evolution (guest_id → guest+org unique)
--   Phase D: Trigger update for multi-tenant schema
--
-- Scenario:
--   Organizations : Aries Hospitality, Blue Ridge Hospitality
--   Properties    : North Camp + South Camp (Aries)
--                   Mountain Camp + River Camp (Blue Ridge)
--   Users         : aries@test.com, blue@test.com
--   Guest         : Sam Smith (sam.smith@example.com)
--
-- Sam's bookings:
--   Booking 1 → North Camp (Aries)    — checked_out
--   Booking 2 → South Camp (Aries)    — confirmed
--   Booking 3 → Mountain Camp (Blue Ridge) — confirmed
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- PHASE B: SIMULATION DATA
-- ════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────
-- B1. Organizations
-- ────────────────────────────────────────────────────────────
INSERT INTO public.organizations (id, name, slug, plan, ghl_location_id, status)
VALUES
  (
    '00000000-0000-0000-0000-000000000001',
    'Aries Hospitality',
    'aries-hospitality',
    'pro',
    'ghl-location-aries',
    'active'
  ),
  (
    '00000000-0000-0000-0000-000000000002',
    'Blue Ridge Hospitality',
    'blue-ridge-hospitality',
    'starter',
    'ghl-location-blueridge',
    'active'
  )
ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B2. Properties
-- North + South belong to Aries.
-- Mountain + River belong to Blue Ridge.
-- ────────────────────────────────────────────────────────────
INSERT INTO public.properties (id, name, location, status, organization_id, total_sites, timezone)
VALUES
  (
    '00000000-0000-0000-0000-000000000010',
    'North Camp',
    'Northern Valley, VA',
    'active',
    '00000000-0000-0000-0000-000000000001',
    45,
    'America/New_York'
  ),
  (
    '00000000-0000-0000-0000-000000000011',
    'South Camp',
    'Riverside, VA',
    'active',
    '00000000-0000-0000-0000-000000000001',
    32,
    'America/New_York'
  ),
  (
    '00000000-0000-0000-0000-000000000012',
    'Mountain Camp',
    'Blue Ridge Parkway, NC',
    'active',
    '00000000-0000-0000-0000-000000000002',
    28,
    'America/New_York'
  ),
  (
    '00000000-0000-0000-0000-000000000013',
    'River Camp',
    'Smoky River, NC',
    'active',
    '00000000-0000-0000-0000-000000000002',
    20,
    'America/New_York'
  )
ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B3. Users
-- ────────────────────────────────────────────────────────────
INSERT INTO public.users (id, email, full_name)
VALUES
  ('00000000-0000-0000-0000-000000000020', 'aries@test.com', 'Aries Owner'),
  ('00000000-0000-0000-0000-000000000021', 'blue@test.com',  'Blue Ridge Owner')
ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B4. User Roles
-- Both users are org-wide owners (property_id = NULL).
-- ────────────────────────────────────────────────────────────
INSERT INTO public.user_roles (user_id, organization_id, property_id, role)
VALUES
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', NULL, 'owner'),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000002', NULL, 'owner')
ON CONFLICT DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B5. Guest: Sam Smith
-- One row in guests = one platform identity (email is the key).
-- No PII beyond email lives here in the target schema.
-- The existing first_name/last_name columns are retained for
-- backward compatibility but are deprecated going forward.
-- ────────────────────────────────────────────────────────────
INSERT INTO public.guests (id, first_name, last_name, email, phone)
VALUES (
  '00000000-0000-0000-0000-000000000030',
  'Sam',
  'Smith',
  'sam.smith@example.com',
  '+15550001234'
)
ON CONFLICT (email) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B6. Guest Org Profiles
-- Sam has two profiles: one per organization he has booked with.
-- Each profile has a DIFFERENT ghl_contact_id because Aries and
-- Blue Ridge each have their own GoHighLevel sub-account.
-- ────────────────────────────────────────────────────────────
INSERT INTO public.guest_org_profiles
  (guest_id, organization_id, first_name, last_name, phone, ghl_contact_id)
VALUES
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000001',   -- Aries
    'Sam', 'Smith', '+15550001234',
    'ghl-aries-sam-001'
  ),
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000002',   -- Blue Ridge
    'Sam', 'Smith', '+15550001234',
    'ghl-blueridge-sam-002'
  )
ON CONFLICT (guest_id, organization_id) DO NOTHING;


-- ────────────────────────────────────────────────────────────
-- B7. Reservations
-- Disable the INSERT trigger during seed to avoid double-writing
-- loyalty (we insert loyalty data manually in Phase C with the
-- correct multi-tenant structure).
-- Re-enable after seed — all future reservation inserts go through
-- the updated Phase D trigger.
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.reservations DISABLE TRIGGER on_reservation_created;

-- Booking 1: North Camp (Aries) — Sam's first Aries visit, now checked out
INSERT INTO public.reservations (
  id, guest_id, organization_id, property_id,
  site_number, check_in, check_out, num_guests,
  nightly_rate, total_amount, original_total_amount, status, notes
) VALUES (
  '00000000-0000-0000-0000-000000000040',
  '00000000-0000-0000-0000-000000000030',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000010',
  'A-12', '2026-05-01', '2026-05-04',
  2, 49.99, 149.97, 149.97, 'checked_out',
  'First visit — North Camp'
) ON CONFLICT (id) DO NOTHING;

-- Booking 2: South Camp (Aries) — Sam's second Aries visit, upcoming
INSERT INTO public.reservations (
  id, guest_id, organization_id, property_id,
  site_number, check_in, check_out, num_guests,
  nightly_rate, total_amount, original_total_amount, status, notes
) VALUES (
  '00000000-0000-0000-0000-000000000041',
  '00000000-0000-0000-0000-000000000030',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000011',
  'B-07', '2026-07-10', '2026-07-13',
  2, 49.99, 149.97, 149.97, 'confirmed',
  'Returning Aries guest — second property visit'
) ON CONFLICT (id) DO NOTHING;

-- Booking 3: Mountain Camp (Blue Ridge) — Sam's first Blue Ridge visit, upcoming
INSERT INTO public.reservations (
  id, guest_id, organization_id, property_id,
  site_number, check_in, check_out, num_guests,
  nightly_rate, total_amount, original_total_amount, status, notes
) VALUES (
  '00000000-0000-0000-0000-000000000042',
  '00000000-0000-0000-0000-000000000030',
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000012',
  'C-03', '2026-08-15', '2026-08-18',
  1, 59.99, 179.97, 179.97, 'confirmed',
  'First Blue Ridge visit — different org, separate loyalty'
) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.reservations ENABLE TRIGGER on_reservation_created;


-- ════════════════════════════════════════════════════════════
-- PHASE C: EVOLVE LOYALTY UNIQUE CONSTRAINT
-- This must run after all existing loyalty rows have an
-- organization_id value. If you have pre-existing loyalty
-- rows from v1, uncomment and run the backfill UPDATE below.
-- ════════════════════════════════════════════════════════════

-- Backfill: assign any NULL organization_id loyalty rows to a default org.
-- Uncomment if you have pre-existing loyalty data from v1.
-- UPDATE public.loyalty
--   SET organization_id = '00000000-0000-0000-0000-000000000001'
--   WHERE organization_id IS NULL;

-- C1 + C2. MOVED (B2): the loyalty composite unique constraint
-- (loyalty_guest_org_unique) is now created by migrate_v3 STEP 0 as
-- part of the schema chain, so it exists whether or not this demo
-- seed is ever run. The guarded block below is retained only as an
-- idempotent backstop for an out-of-order run where this file is
-- applied before migrate_v3; in the canonical order it is a no-op.
ALTER TABLE public.loyalty
  DROP CONSTRAINT IF EXISTS loyalty_guest_id_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'loyalty_guest_org_unique'
      AND conrelid = 'public.loyalty'::regclass
  ) THEN
    ALTER TABLE public.loyalty
      ADD CONSTRAINT loyalty_guest_org_unique
      UNIQUE (guest_id, organization_id);
  END IF;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- C3. Loyalty (org-wide tier) for Sam
--
-- Aries:     2 confirmed visits, Bronze tier
--   North Camp $149.97 + South Camp $149.97 = $299.94
-- Blue Ridge: 1 confirmed visit, Bronze tier
--   Mountain Camp $179.97
-- ────────────────────────────────────────────────────────────
INSERT INTO public.loyalty (
  guest_id, organization_id,
  total_visits, confirmed_visits, total_spend, tier, last_visit
) VALUES
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000001',   -- Aries
    2, 2, 299.94, 'Bronze', '2026-07-10'
  ),
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000002',   -- Blue Ridge
    1, 1, 179.97, 'Bronze', '2026-08-15'
  )
ON CONFLICT (guest_id, organization_id) DO UPDATE SET
  total_visits     = EXCLUDED.total_visits,
  confirmed_visits = EXCLUDED.confirmed_visits,
  total_spend      = EXCLUDED.total_spend,
  tier             = EXCLUDED.tier,
  last_visit       = EXCLUDED.last_visit,
  updated_at       = NOW();


-- ────────────────────────────────────────────────────────────
-- C4. Loyalty by property — Sam's per-campground analytics
-- ────────────────────────────────────────────────────────────
INSERT INTO public.loyalty_by_property (
  guest_id, property_id, organization_id,
  confirmed_visits, total_spend, last_visit
) VALUES
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000010',   -- North Camp
    '00000000-0000-0000-0000-000000000001',   -- Aries
    1, 149.97, '2026-05-01'
  ),
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000011',   -- South Camp
    '00000000-0000-0000-0000-000000000001',   -- Aries
    1, 149.97, '2026-07-10'
  ),
  (
    '00000000-0000-0000-0000-000000000030',
    '00000000-0000-0000-0000-000000000012',   -- Mountain Camp
    '00000000-0000-0000-0000-000000000002',   -- Blue Ridge
    1, 179.97, '2026-08-15'
  )
ON CONFLICT (guest_id, property_id) DO UPDATE SET
  confirmed_visits = EXCLUDED.confirmed_visits,
  total_spend      = EXCLUDED.total_spend,
  last_visit       = EXCLUDED.last_visit,
  updated_at       = NOW();


-- ────────────────────────────────────────────────────────────
-- C5. Webhook Events — one per reservation, all sent
-- ────────────────────────────────────────────────────────────
INSERT INTO public.webhook_events (
  reservation_id, organization_id, property_id,
  event_type, payload, status, processed_at
) VALUES
  (
    '00000000-0000-0000-0000-000000000040',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000010',
    'reservation.created',
    '{"event":"reservation.created","org":"Aries Hospitality","property":"North Camp","guest":"sam.smith@example.com","loyalty":{"visits":1,"tier":"Bronze"}}',
    'sent',
    NOW() - INTERVAL '42 days'
  ),
  (
    '00000000-0000-0000-0000-000000000041',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000011',
    'reservation.created',
    '{"event":"reservation.created","org":"Aries Hospitality","property":"South Camp","guest":"sam.smith@example.com","loyalty":{"visits":2,"tier":"Bronze"}}',
    'sent',
    NOW() - INTERVAL '2 days'
  ),
  (
    '00000000-0000-0000-0000-000000000042',
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000012',
    'reservation.created',
    '{"event":"reservation.created","org":"Blue Ridge Hospitality","property":"Mountain Camp","guest":"sam.smith@example.com","loyalty":{"visits":1,"tier":"Bronze"}}',
    'sent',
    NOW() - INTERVAL '1 day'
  );


-- ════════════════════════════════════════════════════════════
-- PHASE D: UPDATED TRIGGER — Multi-Tenant Aware
-- Replaces handle_new_reservation() with version that:
--   1. Uses ON CONFLICT (guest_id, organization_id) for loyalty
--   2. Also upserts loyalty_by_property per booking
--   3. Includes organization_id + property_id in webhook payload
--   4. Skips loyalty increment for cancelled/no_show reservations
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.handle_new_reservation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload JSONB;
BEGIN
  -- Skip loyalty updates for non-confirmed initial inserts
  IF NEW.status IN ('cancelled', 'no_show') THEN
    RETURN NEW;
  END IF;

  -- Step 1: Upsert org-wide loyalty
  -- Conflict target matches the new UNIQUE(guest_id, organization_id) constraint.
  INSERT INTO public.loyalty (
    guest_id, organization_id,
    total_visits, confirmed_visits, total_spend, tier, last_visit, updated_at
  )
  VALUES (
    NEW.guest_id,
    NEW.organization_id,
    1, 1,
    COALESCE(NEW.total_amount, 0.00),
    NEW.check_in,
    public.calculate_tier(1),
    NOW()
  )
  ON CONFLICT (guest_id, organization_id) DO UPDATE SET
    total_visits     = public.loyalty.total_visits + 1,
    confirmed_visits = public.loyalty.confirmed_visits + 1,
    total_spend      = public.loyalty.total_spend + COALESCE(NEW.total_amount, 0.00),
    last_visit       = NEW.check_in,
    tier             = public.calculate_tier(public.loyalty.confirmed_visits + 1),
    updated_at       = NOW();

  -- Step 2: Upsert property-level loyalty (analytics)
  IF NEW.property_id IS NOT NULL THEN
    INSERT INTO public.loyalty_by_property (
      guest_id, property_id, organization_id,
      confirmed_visits, total_spend, last_visit, updated_at
    )
    VALUES (
      NEW.guest_id, NEW.property_id, NEW.organization_id,
      1,
      COALESCE(NEW.total_amount, 0.00),
      NEW.check_in,
      NOW()
    )
    ON CONFLICT (guest_id, property_id) DO UPDATE SET
      confirmed_visits = public.loyalty_by_property.confirmed_visits + 1,
      total_spend      = public.loyalty_by_property.total_spend + COALESCE(NEW.total_amount, 0.00),
      last_visit       = NEW.check_in,
      updated_at       = NOW();
  END IF;

  -- Step 3: Build self-contained multi-tenant webhook payload
  SELECT jsonb_build_object(
    'event',           'reservation.created',
    'timestamp',       to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source',          'campground-saas',
    'organization_id', NEW.organization_id,
    'property_id',     NEW.property_id,

    'organization', (
      SELECT jsonb_build_object('id', o.id, 'name', o.name, 'ghl_location_id', o.ghl_location_id)
      FROM public.organizations o WHERE o.id = NEW.organization_id
    ),

    'property', (
      SELECT jsonb_build_object('id', p.id, 'name', p.name)
      FROM public.properties p WHERE p.id = NEW.property_id
    ),

    'reservation', jsonb_build_object(
      'id',                      NEW.id,
      'external_reservation_id', NEW.external_reservation_id,
      'site_number',             NEW.site_number,
      'check_in',     to_char(NEW.check_in,  'YYYY-MM-DD'),
      'check_out',    to_char(NEW.check_out, 'YYYY-MM-DD'),
      'num_nights',   (NEW.check_out - NEW.check_in),
      'num_guests',   NEW.num_guests,
      'nightly_rate', NEW.nightly_rate,
      'total_amount', NEW.total_amount,
      'status',       NEW.status,
      'notes',        COALESCE(NEW.notes, '')
    ),

    'guest', (
      SELECT jsonb_build_object('id', g.id, 'email', g.email)
      FROM public.guests g WHERE g.id = NEW.guest_id
    ),

    'guest_profile', (
      SELECT jsonb_build_object(
        'first_name',     gop.first_name,
        'last_name',      gop.last_name,
        'phone',          COALESCE(gop.phone, ''),
        'ghl_contact_id', gop.ghl_contact_id
      )
      FROM public.guest_org_profiles gop
      WHERE gop.guest_id = NEW.guest_id
        AND gop.organization_id = NEW.organization_id
        AND gop.deleted_at IS NULL
    ),

    'loyalty', (
      SELECT jsonb_build_object(
        'total_visits',     l.total_visits,
        'confirmed_visits', l.confirmed_visits,
        'total_spend',      l.total_spend,
        'tier',             l.tier,
        'is_returning',     (l.total_visits > 1)
      )
      FROM public.loyalty l
      WHERE l.guest_id = NEW.guest_id
        AND l.organization_id = NEW.organization_id
    )

  ) INTO v_payload;

  -- Step 4: Store webhook event with full tenant context
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
  'Multi-tenant AFTER INSERT trigger on reservations (Phase D). '
  'Step 1: upserts loyalty UNIQUE(guest_id, organization_id). '
  'Step 2: upserts loyalty_by_property UNIQUE(guest_id, property_id). '
  'Step 3: builds self-contained JSONB payload with org + property + guest + loyalty context. '
  'Step 4: stores payload in webhook_events with organization_id + property_id set.';


-- ════════════════════════════════════════════════════════════
-- VALIDATION QUERIES
-- Run these to verify the simulation is correct.
-- ════════════════════════════════════════════════════════════

-- Verify organizations
-- SELECT id, name, slug, plan FROM public.organizations ORDER BY name;

-- Verify properties per org
-- SELECT p.name AS property, o.name AS org
-- FROM public.properties p
-- JOIN public.organizations o ON o.id = p.organization_id
-- ORDER BY o.name, p.name;

-- Verify Sam's guest record
-- SELECT id, email FROM public.guests WHERE email = 'sam.smith@example.com';

-- Verify Sam's two org profiles (different ghl_contact_id per org)
-- SELECT gop.organization_id, o.name, gop.first_name, gop.ghl_contact_id
-- FROM public.guest_org_profiles gop
-- JOIN public.organizations o ON o.id = gop.organization_id
-- WHERE gop.guest_id = '00000000-0000-0000-0000-000000000030';

-- Verify Sam's 3 reservations across 2 orgs
-- SELECT r.id, o.name AS org, p.name AS property, r.check_in, r.check_out, r.status
-- FROM public.reservations r
-- JOIN public.organizations o ON o.id = r.organization_id
-- JOIN public.properties p    ON p.id = r.property_id
-- WHERE r.guest_id = '00000000-0000-0000-0000-000000000030'
-- ORDER BY r.check_in;

-- Verify org-wide loyalty (Sam has 2 rows — one per org)
-- SELECT o.name AS org, l.total_visits, l.total_spend, l.tier
-- FROM public.loyalty l
-- JOIN public.organizations o ON o.id = l.organization_id
-- WHERE l.guest_id = '00000000-0000-0000-0000-000000000030';

-- Verify per-property loyalty (Sam has 3 rows — one per property visited)
-- SELECT p.name AS property, o.name AS org, lbp.confirmed_visits, lbp.total_spend
-- FROM public.loyalty_by_property lbp
-- JOIN public.properties p ON p.id = lbp.property_id
-- JOIN public.organizations o ON o.id = lbp.organization_id
-- WHERE lbp.guest_id = '00000000-0000-0000-0000-000000000030';

-- Tenant isolation: what Aries sees (filter by org_id)
-- SELECT r.id, p.name AS property, r.check_in, r.check_out, r.status
-- FROM public.reservations r
-- JOIN public.properties p ON p.id = r.property_id
-- WHERE r.organization_id = '00000000-0000-0000-0000-000000000001'
-- ORDER BY r.check_in;

-- Tenant isolation: what Blue Ridge sees
-- SELECT r.id, p.name AS property, r.check_in, r.check_out, r.status
-- FROM public.reservations r
-- JOIN public.properties p ON p.id = r.property_id
-- WHERE r.organization_id = '00000000-0000-0000-0000-000000000002'
-- ORDER BY r.check_in;
