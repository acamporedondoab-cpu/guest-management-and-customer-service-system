-- ============================================================
-- Campground Guest Management & Revenue Intelligence
-- Supabase Schema — v1.0
--
-- Stack context:
--   Reservation Source → Make.com → Supabase (this file)
--                                → GoHighLevel → Email/SMS
--
-- Execution order: run this file once in the Supabase SQL editor.
-- ============================================================


-- ============================================================
-- TABLES
-- ============================================================

-- ------------------------------------------------------------
-- properties
-- One record per campground location.
-- Referenced by reservations.property_id.
-- Supports multi-property expansion (Phase 2).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.properties (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  location   TEXT,
  status     TEXT        NOT NULL DEFAULT 'active'
             CHECK (status IN ('active', 'inactive')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.properties IS
  'Campground properties. One row per location. '
  'Referenced by reservations for multi-property support.';
COMMENT ON COLUMN public.properties.status IS
  'active | inactive. Controls whether the property accepts new reservations.';


-- ------------------------------------------------------------
-- guests
-- One record per unique person, deduplicated by email address.
-- Email is the canonical identity key shared with GoHighLevel.
-- ghl_contact_id is null until Make.com syncs the contact to
-- GoHighLevel and writes the ID back via a PATCH request.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.guests (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name     TEXT        NOT NULL,
  last_name      TEXT        NOT NULL,
  email          TEXT        UNIQUE NOT NULL,
  phone          TEXT,
  ghl_contact_id TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.guests IS
  'Core identity table. One row per unique guest, deduplicated by email.';
COMMENT ON COLUMN public.guests.ghl_contact_id IS
  'GoHighLevel contact ID. Null until Make.com performs first CRM sync '
  'and writes the ID back. Subsequent updates use this ID directly '
  'instead of searching by email — faster and idempotent.';


-- ------------------------------------------------------------
-- reservations
-- One row per booking event. Multiple rows per guest.
-- check_out > check_in is enforced at the database level.
-- status follows a strict lifecycle enforced by CHECK constraint.
-- The handle_new_reservation() trigger fires AFTER every INSERT.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reservations (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  external_reservation_id TEXT        UNIQUE,
  guest_id                UUID        NOT NULL REFERENCES public.guests(id) ON DELETE CASCADE,
  site_number             TEXT        NOT NULL,
  check_in     DATE        NOT NULL,
  check_out    DATE        NOT NULL,
  num_guests   INTEGER     NOT NULL DEFAULT 1,
  nightly_rate NUMERIC(10,2),
  total_amount NUMERIC(10,2),
  status       TEXT        NOT NULL DEFAULT 'confirmed'
               CHECK (status IN ('confirmed', 'checked_in', 'checked_out', 'cancelled')),
  notes        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_checkout_after_checkin CHECK (check_out > check_in)
);

COMMENT ON TABLE  public.reservations IS
  'Booking events. Multiple rows per guest. '
  'Status lifecycle: confirmed → checked_in → checked_out (or cancelled). '
  'Inserting a row fires on_reservation_created trigger.';
COMMENT ON COLUMN public.reservations.external_reservation_id IS
  'ID assigned by the upstream reservation system (Campspot, RezWorks, Hostfully, etc.). '
  'UNIQUE constraint enables idempotent inserts: Make.com can safely retry a webhook '
  'without creating duplicate reservations or double-incrementing loyalty. '
  'NULL for reservations created directly via the demo form.';
COMMENT ON COLUMN public.reservations.status IS
  'confirmed | checked_in | checked_out | cancelled. '
  'Enforced at database level via CHECK constraint.';
COMMENT ON COLUMN public.reservations.total_amount IS
  'Pre-computed on insert: (check_out - check_in) * nightly_rate. '
  'Stored for reporting accuracy — avoids recalculating against stale rates.';


-- ------------------------------------------------------------
-- loyalty
-- One row per guest. Maintained exclusively by the
-- handle_new_reservation() trigger. Never write to this table
-- directly from application code — the trigger is the authority.
--
-- Tier thresholds:
--   Bronze : 1–2 visits
--   Silver : 3–5 visits
--   Gold   : 6+ visits
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.loyalty (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  guest_id     UUID         UNIQUE NOT NULL REFERENCES public.guests(id) ON DELETE CASCADE,
  total_visits INTEGER      NOT NULL DEFAULT 0,
  total_spend  NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  tier         TEXT         NOT NULL DEFAULT 'Bronze'
               CHECK (tier IN ('Bronze', 'Silver', 'Gold')),
  last_visit   DATE,
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.loyalty IS
  'Computed loyalty state. One row per guest. '
  'Owned by on_reservation_created trigger. Never write directly.';
COMMENT ON COLUMN public.loyalty.tier IS
  'Bronze: 1-2 visits. Silver: 3-5 visits. Gold: 6+ visits. '
  'Recalculated by calculate_tier() on every new reservation.';
COMMENT ON COLUMN public.loyalty.total_spend IS
  'Running lifetime spend. Used for tier enrichment in GoHighLevel '
  'and future AI revenue segmentation.';


-- ------------------------------------------------------------
-- webhook_events
-- Outbound automation audit log. Every reservation.created event
-- is stored here as a self-contained JSONB payload.
--
-- Make.com receives this payload via webhook and needs zero
-- follow-up API calls — all data (guest, reservation, loyalty)
-- is embedded in the single payload object.
--
-- Make.com PATCHes status → 'sent' on success, 'failed' on error.
-- status = 'pending' means automation has not yet processed it.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.webhook_events (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type     TEXT        NOT NULL,
  reservation_id UUID        REFERENCES public.reservations(id) ON DELETE SET NULL,
  payload        JSONB       NOT NULL,
  status         TEXT        NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'sent', 'failed')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.webhook_events IS
  'Audit log of every outbound automation event. '
  'Make.com PATCHes status to sent/failed after processing.';
COMMENT ON COLUMN public.webhook_events.payload IS
  'Full self-contained webhook payload (event + reservation + guest + loyalty). '
  'Make.com needs zero follow-up API calls to process a reservation.';
COMMENT ON COLUMN public.webhook_events.status IS
  'pending: not yet processed. '
  'sent: Make.com confirmed receipt. '
  'failed: Make.com reported an error — requires investigation.';


-- ============================================================
-- INDEXES
-- Performance-critical queries: guest lookup by email,
-- reservation queries by guest and date, loyalty tier
-- reporting, webhook event monitoring by status and time.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_guests_email
  ON public.guests(email);

CREATE INDEX IF NOT EXISTS idx_reservations_guest_id
  ON public.reservations(guest_id);

CREATE INDEX IF NOT EXISTS idx_reservations_external_id
  ON public.reservations(external_reservation_id);

CREATE INDEX IF NOT EXISTS idx_reservations_check_in
  ON public.reservations(check_in);

CREATE INDEX IF NOT EXISTS idx_reservations_status
  ON public.reservations(status);

CREATE INDEX IF NOT EXISTS idx_loyalty_guest_id
  ON public.loyalty(guest_id);

CREATE INDEX IF NOT EXISTS idx_loyalty_tier
  ON public.loyalty(tier);

CREATE INDEX IF NOT EXISTS idx_webhook_events_status
  ON public.webhook_events(status);

CREATE INDEX IF NOT EXISTS idx_webhook_events_created_at
  ON public.webhook_events(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_webhook_events_reservation_id
  ON public.webhook_events(reservation_id);


-- ============================================================
-- ROW LEVEL SECURITY
-- Enabled on all tables. Demo uses permissive policies to allow
-- the React frontend (anon key) to read and write.
--
-- Production design: add an operator_id column to guests and
-- reservations, then restrict policies by operator_id to support
-- multi-tenant campground operator isolation.
-- ============================================================

ALTER TABLE public.properties     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guests         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_allow_all_properties"    ON public.properties;
CREATE POLICY "demo_allow_all_properties"
  ON public.properties FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_guests"         ON public.guests;
CREATE POLICY "demo_allow_all_guests"
  ON public.guests FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_reservations"   ON public.reservations;
CREATE POLICY "demo_allow_all_reservations"
  ON public.reservations FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_loyalty"        ON public.loyalty;
CREATE POLICY "demo_allow_all_loyalty"
  ON public.loyalty FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "demo_allow_all_webhook_events" ON public.webhook_events;
CREATE POLICY "demo_allow_all_webhook_events"
  ON public.webhook_events FOR ALL USING (true) WITH CHECK (true);


-- ============================================================
-- FUNCTIONS
-- ============================================================

-- ------------------------------------------------------------
-- calculate_tier(visits INTEGER) → TEXT
--
-- Pure tier calculation. Declared IMMUTABLE so PostgreSQL can
-- inline and cache calls — safe to use inside expressions and
-- index definitions.
--
-- Thresholds:
--   1–2 visits → 'Bronze'
--   3–5 visits → 'Silver'
--   6+ visits  → 'Gold'
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_tier(visits INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF    visits >= 6 THEN RETURN 'Gold';
  ELSIF visits >= 3 THEN RETURN 'Silver';
  ELSE                    RETURN 'Bronze';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.calculate_tier IS
  'Pure loyalty tier calculation. IMMUTABLE — PostgreSQL can optimize calls. '
  'Bronze: 1-2 visits. Silver: 3-5 visits. Gold: 6+ visits.';


-- ------------------------------------------------------------
-- handle_new_reservation() → TRIGGER
--
-- Fires AFTER INSERT on public.reservations (FOR EACH ROW).
-- Three steps, all within the same transaction:
--
--   Step 1 — Upsert loyalty record
--     First reservation:  INSERT with total_visits = 1
--     Subsequent visits:  UPDATE total_visits++, total_spend++,
--                         recalculate tier, update last_visit
--
--   Step 2 — Build webhook payload
--     Constructs a single self-contained JSONB object containing
--     event metadata, reservation fields, guest fields, and the
--     freshly updated loyalty state. The loyalty subquery reads
--     the row written in Step 1 — values are current within the
--     same transaction.
--
--   Step 3 — Store webhook event
--     Inserts the payload into webhook_events with status='pending'.
--     Make.com polls or receives this and PATCHes status on completion.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_reservation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload JSONB;
BEGIN

  -- ── Step 1: Upsert loyalty ──────────────────────────────────
  INSERT INTO public.loyalty (
    guest_id, total_visits, total_spend, last_visit, updated_at
  )
  VALUES (
    NEW.guest_id,
    1,
    COALESCE(NEW.total_amount, 0.00),
    NEW.check_in,
    NOW()
  )
  ON CONFLICT (guest_id) DO UPDATE SET
    total_visits = public.loyalty.total_visits + 1,
    total_spend  = public.loyalty.total_spend + COALESCE(NEW.total_amount, 0.00),
    last_visit   = NEW.check_in,
    tier         = public.calculate_tier(public.loyalty.total_visits + 1),
    updated_at   = NOW();

  -- ── Step 2: Build self-contained webhook payload ────────────
  -- Loyalty subquery reads the row updated in Step 1.
  -- All three subqueries execute within this transaction —
  -- loyalty values reflect the post-upsert state.
  SELECT jsonb_build_object(
    'event',       'reservation.created',
    'timestamp',   to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source',      'campground-demo',

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
      SELECT jsonb_build_object(
        'id',         g.id,
        'first_name', g.first_name,
        'last_name',  g.last_name,
        'email',      g.email,
        'phone',      COALESCE(g.phone, '')
      )
      FROM public.guests g
      WHERE g.id = NEW.guest_id
    ),

    'loyalty', (
      SELECT jsonb_build_object(
        'total_visits', l.total_visits,
        'total_spend',  l.total_spend,
        'tier',         l.tier,
        'is_returning', (l.total_visits > 1)
      )
      FROM public.loyalty l
      WHERE l.guest_id = NEW.guest_id
    )

  ) INTO v_payload;

  -- ── Step 3: Store webhook event ─────────────────────────────
  INSERT INTO public.webhook_events (event_type, reservation_id, payload)
  VALUES ('reservation.created', NEW.id, v_payload);

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_reservation IS
  'AFTER INSERT trigger on reservations. '
  'Step 1: upserts loyalty (visits++, tier recalculated). '
  'Step 2: builds self-contained JSONB webhook payload. '
  'Step 3: stores payload in webhook_events for Make.com pickup.';


-- ============================================================
-- TRIGGERS
-- ============================================================

-- Fires after every new reservation is inserted.
-- Calls handle_new_reservation() which owns loyalty + webhook logic.
CREATE TRIGGER on_reservation_created
  AFTER INSERT ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_reservation();


-- ============================================================
-- VIEWS
-- Stable API layer between raw tables and consumers (React
-- dashboard, Power BI, future AI tools). Consumers should
-- always query views, never raw tables. This isolates them
-- from schema changes.
-- ============================================================

-- ------------------------------------------------------------
-- guest_summary
-- Joins guests with loyalty. Primary view for all guest
-- display, reporting, and Power BI guest-level analysis.
-- Returns one row per guest including full loyalty state.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.guest_summary AS
SELECT
  g.id,
  g.first_name,
  g.last_name,
  (g.first_name || ' ' || g.last_name)  AS full_name,
  g.email,
  g.phone,
  g.ghl_contact_id,
  COALESCE(l.total_visits, 0)            AS total_visits,
  COALESCE(l.total_spend,  0.00)         AS total_spend,
  COALESCE(l.tier, 'Bronze')             AS loyalty_tier,
  l.last_visit,
  g.created_at
FROM public.guests g
LEFT JOIN public.loyalty l ON l.guest_id = g.id;

COMMENT ON VIEW public.guest_summary IS
  'Guests joined with loyalty. One row per guest. '
  'Use for all guest display, Power BI guest-level reports, '
  'and GHL sync status monitoring.';


-- ------------------------------------------------------------
-- reservation_detail
-- Joins reservations with guest name (denormalized).
-- Primary view for reservation display, occupancy reporting,
-- and revenue analysis by date range, site, or status.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.reservation_detail AS
SELECT
  r.id,
  r.external_reservation_id,
  r.guest_id,
  (g.first_name || ' ' || g.last_name)  AS guest_name,
  g.email,
  r.site_number,
  r.check_in,
  r.check_out,
  (r.check_out - r.check_in)            AS num_nights,
  r.num_guests,
  r.nightly_rate,
  r.total_amount,
  r.status,
  r.notes,
  r.created_at
FROM public.reservations r
JOIN public.guests g ON g.id = r.guest_id;

COMMENT ON VIEW public.reservation_detail IS
  'Reservations with guest name denormalized. '
  'Use for reservation display, occupancy reporting, '
  'and revenue analysis. Filters on status, check_in, check_out, site_number.';


-- ------------------------------------------------------------
-- kpi_summary
-- Single-row aggregate. Feeds React dashboard KPI cards and
-- Power BI summary tiles without requiring the frontend to
-- run multiple queries.
--
-- NOTE: PostgreSQL CREATE OR REPLACE VIEW cannot insert columns
-- in the middle of an existing view. If this view already exists,
-- run: DROP VIEW public.kpi_summary; before executing this block.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.kpi_summary AS
SELECT
  (SELECT COUNT(*)
   FROM public.guests)                                                  AS total_guests,

  (SELECT COUNT(*)
   FROM public.reservations)                                            AS total_reservations,

  (SELECT COUNT(*)
   FROM public.loyalty
   WHERE total_visits > 1)                                              AS returning_guests,

  (SELECT COUNT(*)
   FROM public.loyalty WHERE tier = 'Bronze')                          AS bronze_guests,

  (SELECT COUNT(*)
   FROM public.loyalty WHERE tier = 'Silver')                          AS silver_guests,

  (SELECT COUNT(*)
   FROM public.loyalty WHERE tier = 'Gold')                            AS gold_guests,

  (SELECT COALESCE(SUM(total_amount), 0.00)
   FROM public.reservations
   WHERE status != 'cancelled')                                         AS estimated_revenue,

  (SELECT COUNT(*)
   FROM public.guests
   WHERE ghl_contact_id IS NOT NULL)                                    AS synced_contacts,

  (SELECT COUNT(*)
   FROM public.webhook_events
   WHERE status = 'pending')                                            AS pending_webhooks,

  (SELECT COUNT(*)
   FROM public.webhook_events
   WHERE status = 'failed')                                             AS failed_webhooks;

COMMENT ON VIEW public.kpi_summary IS
  'Single-row aggregate for React KPI cards and Power BI summary tiles. '
  'Returns totals for guests, reservations, loyalty tiers, revenue, '
  'and webhook health in one query.';


-- ============================================================
-- GRANTS
-- PostgreSQL has two separate access layers:
--   1. Table-level GRANT — controls whether a role can touch a relation at all
--   2. Row Level Security — controls which rows pass after the grant check
--
-- RLS policies alone are not sufficient. Views in particular require
-- an explicit GRANT SELECT because they are separate objects from the
-- underlying tables. The anon and authenticated roles also need USAGE
-- on the public schema.
--
-- All writes to loyalty go through the trigger — no INSERT/UPDATE grant
-- on loyalty is needed for the frontend.
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Tables: full CRUD for demo (anon key)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.properties     TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.guests         TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reservations   TO anon, authenticated;
GRANT SELECT                         ON public.loyalty        TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE         ON public.webhook_events TO anon, authenticated;

-- Views: must be granted separately from underlying tables
GRANT SELECT ON public.guest_summary       TO anon, authenticated;
GRANT SELECT ON public.reservation_detail  TO anon, authenticated;
GRANT SELECT ON public.kpi_summary         TO anon, authenticated;

-- Function: allow anon to call calculate_tier directly if needed
GRANT EXECUTE ON FUNCTION public.calculate_tier(INTEGER) TO anon, authenticated;
