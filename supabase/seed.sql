-- ============================================================
-- Campground Guest Management — Seed Data
-- v1.1  (adds external_reservation_id to all reservations)
--
-- Populates 8 demo guests spanning all three loyalty tiers.
-- Reservations are inserted in chronological order so the
-- on_reservation_created trigger builds loyalty state correctly.
--
-- Tier distribution after seed:
--   Bronze (1–2 visits) : James Walker, Maria Chen
--   Silver (3–5 visits) : Tyler Brooks, Sandra Kim, Robert Davis
--   Gold   (6+ visits)  : Angela Torres, Michael Hayes, Lisa Nguyen
--
-- Site numbering convention:
--   A-## : Premium RV sites  ($59.99/night)
--   B-## : Standard RV sites ($49.99/night)
--   C-## : Tent / primitive  ($34.99/night)
--
-- external_reservation_id format: CAMP-YYYYMMDD-NNNN
--   Simulates IDs assigned by an upstream reservation system
--   (Campspot, RezWorks, Hostfully, etc.).
--   The UNIQUE constraint on this column means re-running
--   the same INSERT is safely idempotent — ON CONFLICT DO NOTHING
--   can be added to Make.com writes for production use.
--
-- Run AFTER schema.sql. Safe to re-run if tables are empty.
-- ============================================================


-- ============================================================
-- GUESTS
-- Inserted first. Reservations reference these rows by email
-- subquery so no hardcoded UUIDs are required.
-- ============================================================

INSERT INTO public.guests (first_name, last_name, email, phone) VALUES
  ('James',   'Walker',  'james.walker@example.com',   '+15551110001'),
  ('Maria',   'Chen',    'maria.chen@example.com',     '+15551110002'),
  ('Tyler',   'Brooks',  'tyler.brooks@example.com',   '+15551110003'),
  ('Sandra',  'Kim',     'sandra.kim@example.com',     '+15551110004'),
  ('Robert',  'Davis',   'robert.davis@example.com',   '+15551110005'),
  ('Angela',  'Torres',  'angela.torres@example.com',  '+15551110006'),
  ('Michael', 'Hayes',   'michael.hayes@example.com',  '+15551110007'),
  ('Lisa',    'Nguyen',  'lisa.nguyen@example.com',    '+15551110008');


-- ============================================================
-- RESERVATIONS
-- Inserted in strict chronological order per guest.
-- Each INSERT fires on_reservation_created trigger which:
--   1. Upserts loyalty (total_visits++, tier recalculated)
--   2. Builds and stores JSONB webhook payload
-- Loyalty table is populated entirely by the trigger —
-- no direct loyalty inserts in this file.
--
-- total_amount = (check_out - check_in) * nightly_rate
-- ============================================================


-- ------------------------------------------------------------
-- James Walker — Bronze (1 visit)
-- First-time guest. Loyalty tier: Bronze after seed.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260515-0001', id, 'B-07', '2026-05-15', '2026-05-18', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'james.walker@example.com';
-- After: total_visits=1, tier=Bronze


-- ------------------------------------------------------------
-- Maria Chen — Bronze (2 visits)
-- Returned once. Loyalty tier: Bronze after seed.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250912-0002', id, 'C-04', '2025-09-12', '2025-09-14', 1, 34.99, 69.98, 'checked_out'
FROM public.guests WHERE email = 'maria.chen@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260328-0003', id, 'C-04', '2026-03-28', '2026-03-31', 1, 34.99, 104.97, 'checked_out'
FROM public.guests WHERE email = 'maria.chen@example.com';
-- After: total_visits=2, tier=Bronze


-- ------------------------------------------------------------
-- Tyler Brooks — Silver (3 visits)
-- Hit Silver on 3rd visit. Loyalty tier: Silver after seed.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240704-0004', id, 'B-11', '2024-07-04', '2024-07-07', 3, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'tyler.brooks@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250524-0005', id, 'B-11', '2025-05-24', '2025-05-26', 3, 49.99, 99.98, 'checked_out'
FROM public.guests WHERE email = 'tyler.brooks@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260214-0006', id, 'B-11', '2026-02-14', '2026-02-17', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'tyler.brooks@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion


-- ------------------------------------------------------------
-- Sandra Kim — Silver (4 visits)
-- Consistent seasonal visitor. Loyalty tier: Silver after seed.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240615-0007', id, 'A-02', '2024-06-15', '2024-06-18', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'sandra.kim@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20241005-0008', id, 'A-02', '2024-10-05', '2024-10-08', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'sandra.kim@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250620-0009', id, 'A-05', '2025-06-20', '2025-06-23', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'sandra.kim@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260117-0010', id, 'A-05', '2026-01-17', '2026-01-20', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'sandra.kim@example.com';
-- After: total_visits=4, tier=Silver


-- ------------------------------------------------------------
-- Robert Davis — Silver (5 visits)
-- Long-tenure camper approaching Gold. Loyalty tier: Silver.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20230810-0011', id, 'B-03', '2023-08-10', '2023-08-14', 2, 49.99, 199.96, 'checked_out'
FROM public.guests WHERE email = 'robert.davis@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240420-0012', id, 'B-03', '2024-04-20', '2024-04-23', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'robert.davis@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240907-0013', id, 'B-03', '2024-09-07', '2024-09-10', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'robert.davis@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250501-0014', id, 'B-03', '2025-05-01', '2025-05-04', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'robert.davis@example.com';
-- After: total_visits=4, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20251226-0015', id, 'B-03', '2025-12-26', '2025-12-29', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'robert.davis@example.com';
-- After: total_visits=5, tier=Silver


-- ------------------------------------------------------------
-- Angela Torres — Gold (6 visits)
-- Just reached Gold on 6th visit. Loyalty tier: Gold after seed.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20220704-0016', id, 'A-08', '2022-07-04', '2022-07-08', 4, 59.99, 239.96, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20230617-0017', id, 'A-08', '2023-06-17', '2023-06-20', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20231123-0018', id, 'A-08', '2023-11-23', '2023-11-26', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240713-0019', id, 'A-08', '2024-07-13', '2024-07-17', 4, 59.99, 239.96, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=4, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250419-0020', id, 'A-08', '2025-04-19', '2025-04-22', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=5, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260125-0021', id, 'A-08', '2026-01-25', '2026-01-28', 4, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'angela.torres@example.com';
-- After: total_visits=6, tier=Gold    ← tier promotion


-- ------------------------------------------------------------
-- Michael Hayes — Gold (8 visits)
-- Most loyal guest. Ideal demo subject for VIP narrative.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20210807-0022', id, 'A-01', '2021-08-07', '2021-08-11', 2, 59.99, 239.96, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20220528-0023', id, 'A-01', '2022-05-28', '2022-05-31', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20220903-0024', id, 'A-01', '2022-09-03', '2022-09-06', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20230701-0025', id, 'A-01', '2023-07-01', '2023-07-05', 2, 59.99, 239.96, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=4, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240518-0026', id, 'A-01', '2024-05-18', '2024-05-21', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=5, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20241012-0027', id, 'A-01', '2024-10-12', '2024-10-15', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=6, tier=Gold    ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250621-0028', id, 'A-01', '2025-06-21', '2025-06-25', 2, 59.99, 239.96, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=7, tier=Gold

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260412-0029', id, 'A-01', '2026-04-12', '2026-04-15', 2, 59.99, 179.97, 'checked_out'
FROM public.guests WHERE email = 'michael.hayes@example.com';
-- After: total_visits=8, tier=Gold


-- ------------------------------------------------------------
-- Lisa Nguyen — Gold (7 visits)
-- Steady long-term guest. Mix of tent and standard sites.
-- ------------------------------------------------------------
INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20220917-0030', id, 'C-12', '2022-09-17', '2022-09-19', 2, 34.99, 69.98, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=1, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20230324-0031', id, 'B-09', '2023-03-24', '2023-03-27', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=2, tier=Bronze

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20230909-0032', id, 'B-09', '2023-09-09', '2023-09-12', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=3, tier=Silver  ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240315-0033', id, 'B-09', '2024-03-15', '2024-03-18', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=4, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20240824-0034', id, 'B-09', '2024-08-24', '2024-08-27', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=5, tier=Silver

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20250308-0035', id, 'B-09', '2025-03-08', '2025-03-11', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=6, tier=Gold    ← tier promotion

INSERT INTO public.reservations
  (external_reservation_id, guest_id, site_number, check_in, check_out, num_guests, nightly_rate, total_amount, status)
SELECT 'CAMP-20260221-0036', id, 'B-09', '2026-02-21', '2026-02-24', 2, 49.99, 149.97, 'checked_out'
FROM public.guests WHERE email = 'lisa.nguyen@example.com';
-- After: total_visits=7, tier=Gold


-- ============================================================
-- POST-SEED LIFECYCLE UPDATES
--
-- Simulates the natural state of a live system:
--   - Older events have been processed by Make.com (sent)
--   - One recent event failed due to a GHL API timeout (failed)
--   - The newest booking hasn't been picked up yet (pending)
--   - Guests with processed events have been synced to GHL CRM
--
-- These UPDATE statements are safe to re-run (idempotent).
-- ============================================================

-- Mark all events for pre-April 2026 reservations as sent.
-- In production Make.com PATCHes status → 'sent' after successful processing.
UPDATE public.webhook_events
SET status = 'sent'
WHERE reservation_id IN (
  SELECT id FROM public.reservations
  WHERE check_in < '2026-04-01'
);

-- Michael Hayes April 2026 — simulated failure.
-- Scenario: GoHighLevel API returned 429 (rate limit) during Make.com run.
-- Make.com caught the error and PATCHed status → 'failed'.
-- Retry: PATCH status back to 'pending', Make.com reprocesses on next poll.
UPDATE public.webhook_events
SET status = 'failed'
WHERE reservation_id IN (
  SELECT r.id FROM public.reservations r
  JOIN public.guests g ON g.id = r.guest_id
  WHERE g.email = 'michael.hayes@example.com'
  AND r.check_in = '2026-04-12'
);

-- CAMP-20260515-0001 (James Walker, B-07, 2026-05-15) — remains pending.
-- Most recent booking; Make.com has not yet picked up this event.
-- No update needed — webhook_events.status defaults to 'pending'.

-- Set ghl_contact_id for the 6 guests whose events are fully processed.
-- In production Make.com writes this ID back after the first GHL upsert.
-- Subsequent bookings by the same guest skip the search step and use
-- this ID directly — faster and idempotent.
--
-- Not synced: Maria Chen (recent, 2 visits), James Walker (1 pending event).
UPDATE public.guests SET ghl_contact_id = 'Vc3mQ9hU5oR7pT1iWnFk' WHERE email = 'tyler.brooks@example.com';
UPDATE public.guests SET ghl_contact_id = 'Dk4jY6tE2aS8vN0rGwXb' WHERE email = 'sandra.kim@example.com';
UPDATE public.guests SET ghl_contact_id = 'Bx5nW1cL7gP0fM3sHqZu' WHERE email = 'robert.davis@example.com';
UPDATE public.guests SET ghl_contact_id = 'NzK9pR2mT4wJsYv8eXdQ' WHERE email = 'angela.torres@example.com';
UPDATE public.guests SET ghl_contact_id = 'Hm7xKpN3vR9wQdL5tJcE' WHERE email = 'michael.hayes@example.com';
UPDATE public.guests SET ghl_contact_id = 'F2vH8mKnRs4wTdJp6yCq' WHERE email = 'lisa.nguyen@example.com';


-- ============================================================
-- EXPECTED STATE AFTER SEED + POST-SEED UPDATES
--
-- Guest loyalty tiers:
--   SELECT full_name, total_visits, loyalty_tier, total_spend
--   FROM public.guest_summary ORDER BY total_visits DESC;
--
--   Michael Hayes   | 8 | Gold   | 1,619.76
--   Lisa Nguyen     | 7 | Gold   | 1,019.83
--   Angela Torres   | 6 | Gold   | 1,199.80
--   Robert Davis    | 5 | Silver |   799.85
--   Sandra Kim      | 4 | Silver |   719.88
--   Tyler Brooks    | 3 | Silver |   399.92
--   Maria Chen      | 2 | Bronze |   174.95
--   James Walker    | 1 | Bronze |   149.97
--
-- Webhook event status distribution (36 total):
--   sent    : 34  (all events for check_in < 2026-04-01)
--   failed  :  1  (Michael Hayes April 2026 — GHL rate limit simulation)
--   pending :  1  (James Walker May 2026 — awaiting Make.com pickup)
--
-- CRM sync state (guests with ghl_contact_id set):
--   6 of 8 guests synced to GoHighLevel
--   Not synced: Maria Chen, James Walker (pending/recent events)
--
-- Verify idempotency column:
--   SELECT external_reservation_id, site_number, check_in
--   FROM public.reservations ORDER BY external_reservation_id;
-- ============================================================
