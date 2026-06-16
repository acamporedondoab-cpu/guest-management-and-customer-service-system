-- ============================================================
-- MIGRATION v3: Loyalty Lifecycle Correction
-- Campground Guest Management & Revenue Intelligence
--
-- WHAT THIS FIXES:
--   Phase D trigger (seed_simulation.sql) credits confirmed_visits
--   and total_spend at reservation INSERT time. This is wrong.
--   Loyalty should reflect completed stays only, not bookings.
--
-- WHAT THIS FILE DOES:
--   STEP 1 — Replace handle_new_reservation()
--             Booking-intent counter only: increments total_visits.
--             Does NOT credit confirmed_visits or total_spend.
--
--   STEP 2 — Create handle_reservation_status_change()
--             Credits confirmed_visits + total_spend at checked_out.
--             Fires domain events for all status transitions.
--             Cancellations and no-shows require NO loyalty reversal
--             because loyalty was never credited at booking.
--
--   STEP 3 — Create handle_loyalty_tier_change()
--             Fires loyalty.tier_updated webhook event when tier changes.
--             Triggered automatically by Step 2's loyalty upsert.
--
--   STEP 4 — Wire the two missing triggers (Gap 1 fix)
--             reservation_status_change_events (AFTER UPDATE OF status)
--             loyalty_tier_change_events       (AFTER UPDATE OF tier)
--
--   STEP 5 — Recalibrate existing demo data
--             Corrects loyalty and loyalty_by_property to reflect
--             checkout-only logic. Idempotent — safe to re-run.
--
--   STEP 6 — Verification queries (commented out, run manually)
--
-- DEPENDS ON:
--   schema.sql (v1)               — tables, v1 calculate_tier()
--   migrate_v2_multi_tenant.sql   — organizations, loyalty.organization_id,
--                                   loyalty_by_property, guest_org_profiles
--   seed_simulation.sql           — (optional) demo data only; STEP 0 owns the constraint,
--                                   demo data for Step 5 recalibration
--
-- EXPECTED DEMO DATA AFTER RECALIBRATION:
--   Sam + Aries Hospitality:
--     total_visits=2, confirmed_visits=1, total_spend=149.97,
--     last_visit=2026-05-04, tier=Bronze
--   Sam + Blue Ridge Hospitality:
--     total_visits=1, confirmed_visits=0, total_spend=0.00,
--     last_visit=NULL, tier=Bronze
--
-- SAFETY CONTRACT:
--   Functions: CREATE OR REPLACE — idempotent
--   Triggers:  DROP IF EXISTS + CREATE — idempotent
--   Data:      UPDATE from source of truth — idempotent
--   No columns dropped, no data deleted
-- ============================================================


-- ============================================================
-- STEP 0: Loyalty composite unique constraint  (B2)
--
-- Relocated from seed_simulation.sql Phase C so the constraint lives
-- in the schema chain, not the demo data. handle_new_reservation()
-- (Step 1) and handle_reservation_status_change() (Step 2) upsert with
-- ON CONFLICT (guest_id, organization_id); that conflict target MUST
-- exist. Idempotent and safe on an empty (fresh) loyalty table or one
-- that already carries the constraint, so the chain works WITHOUT
-- seed_simulation.sql.
--
-- Upgrading a v1 deployment that still holds loyalty rows: backfill
-- organization_id before this migration (see the commented UPDATE in
-- the original seed Phase C). On a fresh chain loyalty is empty, so no
-- backfill is needed.
-- ============================================================

-- C1. Drop the v1 single-column unique (one loyalty row per guest);
--     the multi-tenant model is one row per guest PER organization.
ALTER TABLE public.loyalty
  DROP CONSTRAINT IF EXISTS loyalty_guest_id_key;

-- C2. Add the composite unique (guest + org). Guarded so re-runs and
--     a later seed_simulation.sql Phase C are both no-ops.
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


-- ============================================================
-- STEP 1: Replace handle_new_reservation()
--
-- New behavior:
--   • Increments total_visits (booking-intent counter)
--   • Provisions loyalty row with confirmed_visits=0, total_spend=0
--   • Provisions loyalty_by_property row (zero counters)
--   • Fires reservation.created webhook with full tenant context
--   • Does NOT touch confirmed_visits, total_spend, or last_visit
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_reservation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payload JSONB;
BEGIN
  -- Skip loyalty updates for non-bookable initial inserts
  IF NEW.status IN ('cancelled', 'no_show') THEN
    RETURN NEW;
  END IF;

  -- Increment total_visits (booking-intent counter only).
  -- confirmed_visits and total_spend are NOT updated here.
  -- They are credited by handle_reservation_status_change()
  -- when status transitions to checked_out.
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

  -- Provision loyalty_by_property row if it does not exist.
  -- Zero counters — credited at checkout, not at booking.
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

  -- Build self-contained multi-tenant webhook payload for reservation.created.
  -- Reads loyalty AFTER the upsert above to capture current total_visits.
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
        'first_name',     gop.first_name,
        'last_name',      gop.last_name,
        'phone',          COALESCE(gop.phone, ''),
        'ghl_contact_id', gop.ghl_contact_id
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
  'AFTER INSERT trigger on reservations (v3). '
  'Increments total_visits only — booking-intent counter. '
  'confirmed_visits and total_spend are credited by '
  'handle_reservation_status_change() at checkout, not here. '
  'Provisions zero-counter loyalty_by_property row for the property.';


-- ============================================================
-- STEP 2: Create handle_reservation_status_change()
--
-- Behavior by status:
--   confirmed    → no loyalty change, webhook fired
--   checked_in   → no loyalty change, webhook fired
--   checked_out  → confirmed_visits + 1, total_spend + amount,
--                  tier recalculated, last_visit set, webhook fired
--   cancelled    → no loyalty change, webhook fired
--                  (no reversal needed — loyalty never credited at booking)
--   no_show      → no loyalty change, webhook fired (future-proofed;
--                  no_show is not yet in the status CHECK constraint)
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
  -- No-op if status did not actually change
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Map status to domain event type.
  -- NULL means no webhook for this transition.
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

  -- Credit loyalty only when the guest completes a stay.
  -- This is the single authoritative place where confirmed_visits
  -- and total_spend are incremented.
  IF NEW.status = 'checked_out' THEN

    -- Upsert org-wide loyalty.
    -- The ON CONFLICT handles the normal case (row exists from booking trigger).
    -- The INSERT handles the edge case (status set to checked_out on first insert).
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
      public.calculate_tier(1),
      NEW.check_out,
      NOW()
    )
    ON CONFLICT (guest_id, organization_id) DO UPDATE
      SET confirmed_visits = COALESCE(public.loyalty.confirmed_visits, 0) + 1,
          total_spend      = COALESCE(public.loyalty.total_spend, 0.00)
                             + COALESCE(NEW.total_amount, 0.00),
          tier             = public.calculate_tier(
                               COALESCE(public.loyalty.confirmed_visits, 0) + 1
                             ),
          last_visit       = NEW.check_out,
          updated_at       = NOW();

    -- Upsert property-level loyalty analytics.
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
  -- No loyalty changes for checked_in, cancelled, or no_show transitions.

  -- Build webhook payload for the status change event.
  -- Reads loyalty AFTER the upsert above so the payload reflects
  -- the credited state when the event is checked_out.
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
        'first_name',     gop.first_name,
        'last_name',      gop.last_name,
        'phone',          COALESCE(gop.phone, ''),
        'ghl_contact_id', gop.ghl_contact_id
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
  'AFTER UPDATE OF status trigger on reservations (v3). '
  'Credits confirmed_visits + total_spend on checked_out only. '
  'Fires domain event webhooks for all status transitions. '
  'Cancellations require no loyalty reversal — loyalty is never '
  'credited at booking time under the v3 lifecycle model.';


-- ============================================================
-- STEP 3: Create handle_loyalty_tier_change()
--
-- Fires automatically when handle_reservation_status_change()
-- upserts the loyalty tier column. Inserts a loyalty.tier_updated
-- webhook event so Make.com can update GHL contact tags.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_loyalty_tier_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payload JSONB;
BEGIN
  -- No-op if tier did not actually change
  IF OLD.tier = NEW.tier THEN
    RETURN NEW;
  END IF;

  v_payload := jsonb_build_object(
    'event',            'loyalty.tier_updated',
    'timestamp',        to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source',           'campground-saas',
    'organization_id',  NEW.organization_id,
    'guest_id',         NEW.guest_id,
    'previous_tier',    OLD.tier,
    'new_tier',         NEW.tier,
    'confirmed_visits', COALESCE(NEW.confirmed_visits, 0),
    'total_spend',      COALESCE(NEW.total_spend, 0.00)
  );

  -- reservation_id is NULL — tier changes are org-level events,
  -- not tied to a specific reservation.
  INSERT INTO public.webhook_events (
    event_type,
    reservation_id,
    organization_id,
    property_id,
    payload
  )
  VALUES (
    'loyalty.tier_updated',
    NULL,
    NEW.organization_id,
    NULL,
    v_payload
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_loyalty_tier_change IS
  'AFTER UPDATE OF tier trigger on loyalty (v3). '
  'Fires loyalty.tier_updated webhook when tier changes. '
  'Triggered automatically by handle_reservation_status_change() '
  'when a checkout upserts a new tier value. Make.com uses this '
  'event to remove the old tier tag and add the new one in GHL.';


-- ============================================================
-- STEP 4: Wire triggers — Gap 1 fix
--
-- These triggers were missing from all prior migrations.
-- Without them, handle_reservation_status_change() and
-- handle_loyalty_tier_change() exist in the database but
-- are never called. Loyalty is never credited at checkout.
-- ============================================================

-- Trigger: reservation status transitions → domain events + loyalty
DROP TRIGGER IF EXISTS reservation_status_change_events ON public.reservations;
CREATE TRIGGER reservation_status_change_events
  AFTER UPDATE OF status
  ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_reservation_status_change();

COMMENT ON TRIGGER reservation_status_change_events
  ON public.reservations IS
  'Fires handle_reservation_status_change() on status column updates. '
  'Credits loyalty at checked_out. Fires domain webhooks for all transitions.';

-- Trigger: loyalty tier changes → GHL sync events
DROP TRIGGER IF EXISTS loyalty_tier_change_events ON public.loyalty;
CREATE TRIGGER loyalty_tier_change_events
  AFTER UPDATE OF tier
  ON public.loyalty
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_loyalty_tier_change();

COMMENT ON TRIGGER loyalty_tier_change_events
  ON public.loyalty IS
  'Fires handle_loyalty_tier_change() when the tier column changes. '
  'Inserts loyalty.tier_updated webhook so Make.com can update GHL tags.';


-- ============================================================
-- STEP 5: Recalibrate existing demo data
--
-- The Phase D trigger in seed_simulation.sql credited loyalty at
-- INSERT time, producing incorrect counts. These UPDATEs recompute
-- all counts from the reservation table as source of truth.
--
-- Idempotent: re-running produces the same result.
-- Safe: no rows deleted, only SET confirmed_visits, total_spend, etc.
--
-- CURRENT STATE (Phase D seed):
--   Sam + Aries:      confirmed_visits=2, total_spend=299.94
--   Sam + Blue Ridge: confirmed_visits=1, total_spend=179.97
--
-- TARGET STATE (v3 checkout-only logic):
--   Sam + Aries:      confirmed_visits=1, total_spend=149.97,
--                     last_visit=2026-05-04 (North Camp checkout)
--   Sam + Blue Ridge: confirmed_visits=0, total_spend=0.00,
--                     last_visit=NULL (Mountain Camp not checked out)
--
--   North Camp lbp:    confirmed_visits=1, total_spend=149.97
--   South Camp lbp:    confirmed_visits=0, total_spend=0.00
--   Mountain Camp lbp: confirmed_visits=0, total_spend=0.00
-- ============================================================

-- 5a. Recompute confirmed_visits, total_spend, last_visit
--     from actual checked_out reservations only.
UPDATE public.loyalty l
SET
  confirmed_visits = (
    SELECT COUNT(*)
    FROM public.reservations r
    WHERE r.guest_id        = l.guest_id
      AND r.organization_id = l.organization_id
      AND r.status          = 'checked_out'
  ),
  total_spend = (
    SELECT COALESCE(SUM(r.total_amount), 0.00)
    FROM public.reservations r
    WHERE r.guest_id        = l.guest_id
      AND r.organization_id = l.organization_id
      AND r.status          = 'checked_out'
  ),
  last_visit = (
    SELECT MAX(r.check_out)
    FROM public.reservations r
    WHERE r.guest_id        = l.guest_id
      AND r.organization_id = l.organization_id
      AND r.status          = 'checked_out'
  ),
  updated_at = NOW();

-- 5b. Recompute total_visits as count of all non-cancelled bookings.
--     Includes confirmed, checked_in, and checked_out reservations.
UPDATE public.loyalty l
SET
  total_visits = (
    SELECT COUNT(*)
    FROM public.reservations r
    WHERE r.guest_id        = l.guest_id
      AND r.organization_id = l.organization_id
      AND r.status          NOT IN ('cancelled')
  ),
  updated_at = NOW();

-- 5c. Recalculate tier from corrected confirmed_visits.
--     Runs after 5a so confirmed_visits is already correct.
UPDATE public.loyalty
SET
  tier       = public.calculate_tier(COALESCE(confirmed_visits, 0)),
  updated_at = NOW();

-- 5d. Recompute loyalty_by_property from checked_out reservations.
UPDATE public.loyalty_by_property lbp
SET
  confirmed_visits = (
    SELECT COUNT(*)
    FROM public.reservations r
    WHERE r.guest_id    = lbp.guest_id
      AND r.property_id = lbp.property_id
      AND r.status      = 'checked_out'
  ),
  total_spend = (
    SELECT COALESCE(SUM(r.total_amount), 0.00)
    FROM public.reservations r
    WHERE r.guest_id    = lbp.guest_id
      AND r.property_id = lbp.property_id
      AND r.status      = 'checked_out'
  ),
  last_visit = (
    SELECT MAX(r.check_out)
    FROM public.reservations r
    WHERE r.guest_id    = lbp.guest_id
      AND r.property_id = lbp.property_id
      AND r.status      = 'checked_out'
  ),
  updated_at = NOW();


-- ============================================================
-- STEP 6: Verification queries
-- Uncomment and run individually to confirm correct state.
-- ============================================================

-- 6a. Confirm all three triggers are wired and enabled.
--     Expected: 3 rows with tgenabled = 'O' (origin firing)
--
-- SELECT tgname, tgrelid::regclass AS on_table, tgenabled
-- FROM pg_trigger
-- WHERE tgname IN (
--   'on_reservation_created',
--   'reservation_status_change_events',
--   'loyalty_tier_change_events'
-- )
-- ORDER BY tgname;


-- 6b. Confirm loyalty is calibrated correctly.
--     confirmed_visits must equal actual checked_out count.
--     Any row with check_result = 'MISMATCH' indicates a problem.
--
-- SELECT
--   o.name                                          AS organization,
--   l.total_visits,
--   l.confirmed_visits,
--   l.total_spend,
--   l.tier,
--   l.last_visit,
--   (
--     SELECT COUNT(*) FROM public.reservations r
--     WHERE r.guest_id = l.guest_id AND r.organization_id = l.organization_id
--       AND r.status = 'checked_out'
--   )                                               AS actual_checkout_count,
--   CASE
--     WHEN l.confirmed_visits = (
--       SELECT COUNT(*) FROM public.reservations r
--       WHERE r.guest_id = l.guest_id AND r.organization_id = l.organization_id
--         AND r.status = 'checked_out'
--     ) THEN 'OK' ELSE 'MISMATCH'
--   END                                             AS check_result
-- FROM public.loyalty l
-- JOIN public.organizations o ON o.id = l.organization_id
-- ORDER BY o.name;


-- 6c. Spot-check Sam Smith's loyalty values.
--
-- Expected output:
--   Aries Hospitality:      total_visits=2, confirmed_visits=1,
--                           total_spend=149.97, tier=Bronze,
--                           last_visit=2026-05-04
--   Blue Ridge Hospitality: total_visits=1, confirmed_visits=0,
--                           total_spend=0.00, tier=Bronze,
--                           last_visit=NULL
--
-- SELECT
--   o.name AS organization,
--   l.total_visits,
--   l.confirmed_visits,
--   l.total_spend,
--   l.tier,
--   l.last_visit
-- FROM public.loyalty l
-- JOIN public.guests g        ON g.id  = l.guest_id
-- JOIN public.organizations o ON o.id  = l.organization_id
-- WHERE g.email = 'sam.smith@example.com'
-- ORDER BY o.name;


-- 6d. Spot-check Sam Smith's per-property loyalty values.
--
-- Expected output:
--   Mountain Camp: confirmed_visits=0, total_spend=0.00, last_visit=NULL
--   North Camp:    confirmed_visits=1, total_spend=149.97, last_visit=2026-05-04
--   South Camp:    confirmed_visits=0, total_spend=0.00, last_visit=NULL
--
-- SELECT
--   p.name  AS property,
--   o.name  AS organization,
--   lbp.confirmed_visits,
--   lbp.total_spend,
--   lbp.last_visit
-- FROM public.loyalty_by_property lbp
-- JOIN public.guests g        ON g.id  = lbp.guest_id
-- JOIN public.properties p    ON p.id  = lbp.property_id
-- JOIN public.organizations o ON o.id  = lbp.organization_id
-- WHERE g.email = 'sam.smith@example.com'
-- ORDER BY p.name;


-- 6e. Live end-to-end test: update North Camp reservation back to
--     confirmed, then back to checked_out, and verify loyalty.
--     Run in a transaction so you can roll back if needed.
--
-- BEGIN;
--
--   UPDATE public.reservations
--     SET status = 'confirmed'
--     WHERE id = '00000000-0000-0000-0000-000000000040';
--
--   -- Sam Aries should now be: confirmed_visits=0, total_spend=0.00
--   SELECT l.confirmed_visits, l.total_spend, l.tier
--   FROM public.loyalty l
--   JOIN public.guests g ON g.id = l.guest_id
--   WHERE g.email = 'sam.smith@example.com'
--     AND l.organization_id = '00000000-0000-0000-0000-000000000001';
--
--   UPDATE public.reservations
--     SET status = 'checked_out'
--     WHERE id = '00000000-0000-0000-0000-000000000040';
--
--   -- Sam Aries should now be: confirmed_visits=1, total_spend=149.97, tier=Bronze
--   SELECT l.confirmed_visits, l.total_spend, l.tier
--   FROM public.loyalty l
--   JOIN public.guests g ON g.id = l.guest_id
--   WHERE g.email = 'sam.smith@example.com'
--     AND l.organization_id = '00000000-0000-0000-0000-000000000001';
--
--   -- A reservation.checked_out webhook event should exist
--   SELECT event_type, status, created_at
--   FROM public.webhook_events
--   WHERE event_type = 'reservation.checked_out'
--   ORDER BY created_at DESC LIMIT 1;
--
-- ROLLBACK;
