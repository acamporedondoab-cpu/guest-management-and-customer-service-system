# Supabase Database Layer

## Overview

This directory contains the complete database schema for the Campground Guest Management & Revenue Intelligence demo. Supabase is the **source of truth** for all guest, reservation, and loyalty data. It sits downstream of Make.com (which writes data after processing incoming webhooks) and upstream of the reporting layer (React dashboard, Power BI).

### Where Supabase fits in the stack

```
Reservation Source (demo form / real booking system)
  │
  │  fires webhook payload
  ▼
Make.com  ──────────────────────────────────────────────────────┐
  │  writes guests, reservations                                │
  │  reads loyalty                                              │
  ▼                                                            ▼
Supabase (this layer)                                    GoHighLevel
  │  guest_summary view                                   CRM contacts
  │  reservation_detail view                              Tags, fields
  │  kpi_summary view                                     Workflows
  ▼
Reporting Layer
  React Dashboard (real-time via supabase-js)
  Power BI (via PostgreSQL connection string)
```

---

## Files

| File | Purpose |
|---|---|
| `schema.sql` | All DDL: tables, indexes, RLS, functions, trigger, views |
| `seed.sql` | 8 demo guests with varied loyalty tiers (36 reservations total) |
| `README.md` | This document |

---

## Setup

1. Create a new project at [supabase.com](https://supabase.com)
2. Open the **SQL Editor**
3. Paste and run `schema.sql` — creates all tables, functions, trigger, and views
4. Paste and run `seed.sql` — populates demo data and exercises the trigger
5. Copy your **Project URL** and **anon public key** from Project Settings → API
6. Add them to `.env.local` in the React project root

```
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key-here
```

**Verification query** — run after seed.sql to confirm correct state:

```sql
SELECT full_name, total_visits, loyalty_tier, total_spend
FROM public.guest_summary
ORDER BY total_visits DESC;
```

---

## Schema Diagram

```
┌──────────────────────────────────────────────────────────┐
│                         guests                           │
│  id (PK)  •  first_name  •  last_name  •  email (UNIQUE)│
│  phone  •  ghl_contact_id  •  created_at                │
└──────────────────────────────────────────────────────────┘
         │ id                                │ id
         │ 1:many                            │ 1:1
         ▼                                   ▼
┌────────────────────────────┐  ┌────────────────────────────┐
│        reservations        │  │          loyalty           │
│  id (PK)                   │  │  id (PK)                   │
│  guest_id (FK → guests.id) │  │  guest_id (FK, UNIQUE)     │
│  site_number               │  │  total_visits              │
│  check_in                  │  │  total_spend               │
│  check_out                 │  │  tier (Bronze/Silver/Gold) │
│  num_guests                │  │  last_visit                │
│  nightly_rate              │  │  updated_at                │
│  total_amount              │  └────────────────────────────┘
│  status                    │
│  notes                     │  TRIGGER: on_reservation_created
│  created_at                │  ────────────────────────────
└────────────────────────────┘  AFTER INSERT on reservations
         │ id                   calls handle_new_reservation()
         │ 1:1
         ▼
┌────────────────────────────────────────────────────────────┐
│                      webhook_events                        │
│  id (PK)  •  event_type  •  reservation_id (FK)           │
│  payload (JSONB)  •  status  •  created_at                │
└────────────────────────────────────────────────────────────┘
```

---

## Tables

### `guests`

**Purpose:** Core identity table. One row per unique person, deduplicated by `email`. Email is the canonical identity key shared between Supabase and GoHighLevel — it is the field Make.com uses to search for an existing GHL contact before deciding to create or update.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | UUID | PK, default gen_random_uuid() | Supabase-internal identity |
| `first_name` | TEXT | NOT NULL | Guest first name |
| `last_name` | TEXT | NOT NULL | Guest last name |
| `email` | TEXT | UNIQUE NOT NULL | CRM identity key. Deduplication anchor. |
| `phone` | TEXT | nullable | E.164 format recommended (+15555550000) |
| `ghl_contact_id` | TEXT | nullable | GoHighLevel contact ID. Written back by Make.com after first CRM sync. Null until then. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Row creation timestamp |

**Why `email` is UNIQUE:** A guest who books twice must land on one row. If email were not unique, Make.com would create a duplicate GHL contact on every booking, corrupting the CRM.

**Why `ghl_contact_id` is stored here:** After Make.com creates or finds a GHL contact, it PATCHes this field with the GHL contact ID. Subsequent reservation webhooks can then include the contact ID in the payload, allowing Make.com to update the GHL contact directly by ID rather than searching by email — faster and idempotent.

---

### `reservations`

**Purpose:** Booking events. Multiple rows per guest — each booking creates a new row. The trigger fires on every INSERT.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | UUID | PK, default gen_random_uuid() | Internal booking identity (Supabase-generated) |
| `external_reservation_id` | TEXT | UNIQUE, nullable | ID from the upstream reservation system (Campspot, RezWorks, etc.) — enables idempotent inserts |
| `guest_id` | UUID | NOT NULL, FK → guests.id | Links reservation to guest |
| `site_number` | TEXT | NOT NULL | Physical site identifier (A-01, B-07, C-12) |
| `check_in` | DATE | NOT NULL | Arrival date |
| `check_out` | DATE | NOT NULL | Departure date |
| `num_guests` | INTEGER | NOT NULL DEFAULT 1 | Party size |
| `nightly_rate` | NUMERIC(10,2) | nullable | Rate at time of booking — stored to preserve revenue accuracy |
| `total_amount` | NUMERIC(10,2) | nullable | Pre-computed: nights × nightly_rate |
| `status` | TEXT | CHECK constraint | confirmed → checked_in → checked_out (or cancelled) |
| `notes` | TEXT | nullable | Special requests, arrival notes |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Booking timestamp |

**Status lifecycle:**
```
confirmed  →  checked_in  →  checked_out
     └──────────────────────→  cancelled
```

**Why `external_reservation_id` is nullable but unique:** Demo form submissions have no upstream system ID — `NULL` is allowed. But if a value is provided, it must be globally unique. This means Make.com can safely retry a failed webhook delivery using `INSERT ... ON CONFLICT (external_reservation_id) DO NOTHING` and the row will not be duplicated, and the trigger (loyalty upsert + webhook event) will not re-fire. Without this column, a network retry creates a duplicate reservation and double-increments `total_visits`.

**Why `total_amount` is stored (not computed):** Nightly rates change over time. Storing `total_amount` at booking time ensures revenue reports are accurate against the rate the guest actually paid, not the current rate.

**Why `check_out > check_in` is a constraint:** Invalid date ranges (same-day, reversed) are caught at the database level before reaching application logic or the trigger.

---

### `loyalty`

**Purpose:** Computed loyalty state per guest. Exactly one row per guest. This table is owned entirely by the `on_reservation_created` trigger — never write to it directly from application code.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | UUID | PK | Internal row identity |
| `guest_id` | UUID | UNIQUE NOT NULL, FK → guests.id | One loyalty record per guest |
| `total_visits` | INTEGER | NOT NULL DEFAULT 0 | Incremented by trigger on each reservation insert |
| `total_spend` | NUMERIC(10,2) | NOT NULL DEFAULT 0.00 | Running sum of total_amount across all reservations |
| `tier` | TEXT | CHECK (Bronze/Silver/Gold) | Recalculated by calculate_tier() on every new reservation |
| `last_visit` | DATE | nullable | check_in date of most recent reservation |
| `updated_at` | TIMESTAMPTZ | NOT NULL | Set to NOW() on every trigger update |

**Tier thresholds:**

| Tier | Visits | GoHighLevel Tag |
|---|---|---|
| Bronze | 1–2 | `Bronze` |
| Silver | 3–5 | `Silver` |
| Gold | 6+ | `Gold` |

**Why loyalty is a separate table (not columns on guests):** Loyalty is computed state derived from reservation history. Keeping it isolated means: (1) the trigger is the single authority on how it's calculated; (2) the guests table stays lean and identity-focused; (3) a future event-sourcing design can recompute loyalty from the reservations table at any time without touching guest identity.

---

### `webhook_events`

**Purpose:** Outbound automation audit log. Every `reservation.created` event is stored here as a self-contained JSONB payload. This table is the handoff point between Supabase and Make.com.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | UUID | PK | Event identity |
| `event_type` | TEXT | NOT NULL | Event name (`reservation.created`) |
| `reservation_id` | UUID | FK → reservations.id (nullable on delete) | Links event to the reservation that triggered it |
| `payload` | JSONB | NOT NULL | Full event payload — guest + reservation + loyalty embedded |
| `status` | TEXT | CHECK (pending/sent/failed) | Automation status lifecycle |
| `created_at` | TIMESTAMPTZ | NOT NULL | When the event was created by the trigger |

**Status lifecycle:**
```
pending  →  sent     (Make.com processed successfully)
pending  →  failed   (Make.com reported an error)
```

**Why the payload is self-contained:** Make.com receives the webhook and needs all the data to: create/update a GHL contact, apply tags, trigger workflows, and update loyalty. A self-contained payload means zero follow-up API calls back to Supabase during automation — fewer failure points, faster execution, simpler Make.com scenario logic.

**Monitoring:** `SELECT * FROM webhook_events WHERE status = 'pending'` reveals unprocessed events. `status = 'failed'` requires investigation — the payload column contains the full context for debugging.

---

## Relationships

| Relationship | Type | Key | Notes |
|---|---|---|---|
| guests → reservations | One-to-many | `reservations.guest_id → guests.id` | One guest, many bookings |
| guests → loyalty | One-to-one | `loyalty.guest_id → guests.id` (UNIQUE) | One loyalty record per guest |
| reservations → webhook_events | One-to-one | `webhook_events.reservation_id → reservations.id` | One event per reservation insert |

**Cascade behavior:**
- Deleting a guest cascades to `reservations` and `loyalty` (ON DELETE CASCADE)
- Deleting a reservation sets `webhook_events.reservation_id` to NULL (ON DELETE SET NULL) — preserves the audit log

---

## Indexes

| Index | Table | Columns | Purpose |
|---|---|---|---|
| `idx_guests_email` | guests | email | Email lookup by Make.com and CRM sync |
| `idx_reservations_guest_id` | reservations | guest_id | Guest → reservations joins |
| `idx_reservations_external_id` | reservations | external_reservation_id | Idempotency lookup — ON CONFLICT target for Make.com retries |
| `idx_reservations_check_in` | reservations | check_in | Date-range occupancy queries |
| `idx_reservations_status` | reservations | status | Filter by active/confirmed reservations |
| `idx_loyalty_guest_id` | loyalty | guest_id | Loyalty joins in views |
| `idx_loyalty_tier` | loyalty | tier | Tier distribution queries (Power BI) |
| `idx_webhook_events_status` | webhook_events | status | Monitor pending/failed events |
| `idx_webhook_events_created_at` | webhook_events | created_at DESC | Latest events first in dashboard log |
| `idx_webhook_events_reservation_id` | webhook_events | reservation_id | Event → reservation joins |

---

## Functions

### `calculate_tier(visits INTEGER) → TEXT`

Pure function. Declared `IMMUTABLE` — PostgreSQL can inline and cache the result, and it is safe to use inside index expressions.

```sql
SELECT calculate_tier(1);  -- → 'Bronze'
SELECT calculate_tier(2);  -- → 'Bronze'
SELECT calculate_tier(3);  -- → 'Silver'
SELECT calculate_tier(5);  -- → 'Silver'
SELECT calculate_tier(6);  -- → 'Gold'
SELECT calculate_tier(12); -- → 'Gold'
```

**Why IMMUTABLE?** The function has no side effects and always returns the same output for the same input. Declaring it `IMMUTABLE` allows PostgreSQL to fold it as a constant during query planning and potentially cache results — safe performance optimization.

---

### `handle_new_reservation() → TRIGGER`

Trigger function. Fires `AFTER INSERT ON reservations FOR EACH ROW`. Three steps execute atomically within the same transaction:

**Step 1 — Upsert loyalty**

```sql
INSERT INTO loyalty (guest_id, total_visits, total_spend, last_visit, updated_at)
VALUES (NEW.guest_id, 1, COALESCE(NEW.total_amount, 0), NEW.check_in, NOW())
ON CONFLICT (guest_id) DO UPDATE SET
  total_visits = loyalty.total_visits + 1,
  total_spend  = loyalty.total_spend + COALESCE(NEW.total_amount, 0),
  last_visit   = NEW.check_in,
  tier         = calculate_tier(loyalty.total_visits + 1),
  updated_at   = NOW();
```

- First reservation for a guest: `INSERT` — creates the loyalty row with `total_visits = 1`
- Subsequent reservations: `UPDATE` — increments visits, accumulates spend, recalculates tier

**Step 2 — Build webhook payload**

Constructs a JSONB object with four keys: `event`, `reservation`, `guest`, `loyalty`. The loyalty subquery reads the row written in Step 1 — within the same transaction, this returns the post-upsert values (updated visit count and tier).

**Step 3 — Store webhook event**

Inserts the payload into `webhook_events` with `status = 'pending'`. In production, Make.com's custom webhook URL is configured to listen for these, processes the payload, then PATCHes the status back.

**Why server-side?** Loyalty updates that run in a database trigger cannot be skipped by client bugs, network failures, or front-end code changes. The database is the authority on loyalty state.

---

## Triggers

### `on_reservation_created`

```sql
CREATE TRIGGER on_reservation_created
  AFTER INSERT ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_reservation();
```

- **Timing:** AFTER INSERT (row is committed before trigger fires — subqueries see the new row)
- **Scope:** FOR EACH ROW — fires once per inserted reservation
- **Effect:** Upserts loyalty, stores webhook payload
- **Atomicity:** All three steps in `handle_new_reservation()` execute in the same transaction as the INSERT — if any step fails, the entire reservation insert rolls back

---

## Views

Views are the **stable API layer** between raw tables and all consumers. The React dashboard, Power BI, and any future tool should query views, not raw tables. If the schema changes (new columns, renamed tables), views absorb the change — consumers are not affected.

---

### `guest_summary`

**Query:** `SELECT * FROM public.guest_summary`

Returns one row per guest with loyalty data denormalized from the `loyalty` table.

| Column | Source | Notes |
|---|---|---|
| `id` | guests.id | |
| `first_name` | guests.first_name | |
| `last_name` | guests.last_name | |
| `full_name` | computed | `first_name || ' ' || last_name` |
| `email` | guests.email | |
| `phone` | guests.phone | |
| `ghl_contact_id` | guests.ghl_contact_id | Null until Make.com syncs |
| `total_visits` | loyalty.total_visits | COALESCE to 0 for guests with no reservations |
| `total_spend` | loyalty.total_spend | COALESCE to 0.00 |
| `loyalty_tier` | loyalty.tier | COALESCE to 'Bronze' |
| `last_visit` | loyalty.last_visit | |
| `created_at` | guests.created_at | |

**Uses:** React guests table, Power BI guest-level segmentation, GHL sync status monitoring.

**Example query — Gold guests ordered by spend:**
```sql
SELECT full_name, total_visits, total_spend
FROM guest_summary
WHERE loyalty_tier = 'Gold'
ORDER BY total_spend DESC;
```

---

### `reservation_detail`

**Query:** `SELECT * FROM public.reservation_detail`

Returns one row per reservation with `guest_name` and `email` denormalized from the `guests` table.

| Column | Source | Notes |
|---|---|---|
| `id` | reservations.id | |
| `guest_id` | reservations.guest_id | |
| `guest_name` | computed | `first_name || ' ' || last_name` |
| `email` | guests.email | |
| `site_number` | reservations.site_number | |
| `check_in` | reservations.check_in | |
| `check_out` | reservations.check_out | |
| `num_nights` | computed | `check_out - check_in` (integer days) |
| `num_guests` | reservations.num_guests | |
| `nightly_rate` | reservations.nightly_rate | |
| `total_amount` | reservations.total_amount | |
| `status` | reservations.status | |
| `notes` | reservations.notes | |
| `created_at` | reservations.created_at | |

**Uses:** React reservations table, occupancy reporting, revenue by site/date.

**Example query — upcoming confirmed reservations:**
```sql
SELECT guest_name, site_number, check_in, check_out, total_amount
FROM reservation_detail
WHERE status = 'confirmed'
  AND check_in >= CURRENT_DATE
ORDER BY check_in ASC;
```

---

### `kpi_summary`

**Query:** `SELECT * FROM public.kpi_summary`

Returns a single row with all aggregated metrics for the operations dashboard. Designed to be fetched once per dashboard load.

| Column | Description |
|---|---|
| `total_guests` | Count of all guest records |
| `total_reservations` | Count of all reservation records |
| `returning_guests` | Count of guests with more than 1 visit |
| `bronze_guests` | Count of Bronze-tier loyalty members |
| `silver_guests` | Count of Silver-tier loyalty members |
| `gold_guests` | Count of Gold-tier loyalty members |
| `estimated_revenue` | Sum of `total_amount` for non-cancelled reservations |
| `pending_webhooks` | Count of webhook events not yet processed by Make.com |
| `failed_webhooks` | Count of webhook events that Make.com reported as failed |

**Uses:** React KPI cards, Power BI summary tiles, automation health monitoring.

**Power BI note:** Connect Power BI to Supabase via the PostgreSQL connector using the connection string from Project Settings → Database. Point it at these views. Schema changes will not break the Power BI reports as long as view column names remain stable.

---

## Seed Data Summary

After running `seed.sql`, the database contains:

| Guest | Tier | Visits | Total Spend |
|---|---|---|---|
| Michael Hayes | Gold | 8 | $1,619.76 |
| Lisa Nguyen | Gold | 7 | $1,019.83 |
| Angela Torres | Gold | 6 | $1,199.80 |
| Robert Davis | Silver | 5 | $799.85 |
| Sandra Kim | Silver | 4 | $719.88 |
| Tyler Brooks | Silver | 3 | $399.92 |
| Maria Chen | Bronze | 2 | $174.95 |
| James Walker | Bronze | 1 | $149.97 |

- **Total reservations:** 36
- **Total webhook_events rows:** 36 (one per reservation insert — trigger fired 36 times)
- **Loyalty table rows:** 8 (one per guest — built entirely by the trigger)

---

## Design Decisions

### 1. Email as the deduplication key
GoHighLevel and Make.com both use email as the primary identity for contact matching. By making `guests.email` UNIQUE, we ensure that a returning guest's second booking updates the existing row rather than creating a duplicate — which would create a duplicate GHL contact.

### 2. Loyalty as a separate table
Loyalty is computed state, not identity. Isolating it means: (a) the trigger is the single authority on calculation; (b) the guests table stays lean; (c) the loyalty table can be truncated and rebuilt from reservations at any time without touching guest identity.

### 3. Self-contained webhook payload
Make.com receives one JSONB object with everything it needs: event metadata, reservation details, guest details, and current loyalty state. Zero follow-up API calls are required during automation. This reduces latency, reduces failure surface, and simplifies the Make.com scenario.

### 4. Server-side trigger (not application code)
Loyalty updates cannot be bypassed by a client bug, a direct API call, or a future code change. The trigger fires on every INSERT regardless of the source — Make.com, React, Supabase dashboard, bulk import.

### 5. Views as a stable reporting API
Power BI and any external tool connect to views, not raw tables. If we later add columns, split tables, or rename things, we update the view definition — consumers see no change. This is the database equivalent of a versioned API contract.

### 6. `ghl_contact_id` writeback pattern
After Make.com creates a GHL contact, it PATCHes `guests.ghl_contact_id`. On the next reservation, the webhook payload can include this ID. Make.com can then directly update the GHL contact by ID instead of searching by email — faster, idempotent, and resilient to email changes.

### 7. Row Level Security with `operator_id` as the next step
RLS is enabled on all tables with permissive demo policies. In production (multi-property SaaS), each campground operator gets an `operator_id`. Adding `operator_id` to `guests` and `reservations`, then updating the RLS policies to `USING (operator_id = auth.jwt() -> 'operator_id')`, converts this single-tenant demo into a fully isolated multi-tenant system with no other schema changes required.
