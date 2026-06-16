# Systems Architecture Review & Phase 2 Roadmap
**Campground Guest Management & Revenue Intelligence Platform**
Review Date: 2026-06-11
Status: Post-MVP, End-to-End Tested

---

## Executive Summary

The MVP has passed end-to-end testing across both the new-guest and returning-guest paths. The core data pipeline — form → Make.com → Supabase → GHL — is functional, idempotent, and producing correct loyalty state. This review assesses the architecture as a completed v1, identifies production-readiness gaps, and lays out a prioritized Phase 2 roadmap to elevate the platform to enterprise-grade.

---

## Architecture Scorecard

| Dimension | Score | Notes |
|---|---|---|
| **Data Model** | 8 / 10 | Normalized, UUID PKs, proper FK cascade, clean separation of identity vs. transaction vs. state |
| **Automation Design** | 7 / 10 | Functional end-to-end; lacks retry, error branching, and environment isolation |
| **CRM Integration** | 8 / 10 | Upsert pattern correct, custom fields synced, `ghl_contact_id` writeback eliminates redundant lookups |
| **Database Logic** | 9 / 10 | DB trigger is server-authoritative; loyalty is impossible to corrupt from the client; IMMUTABLE tier function is a sound design choice |
| **Observability** | 5 / 10 | `webhook_events` is a solid audit trail; no alerting, no Make.com execution log surfaced in UI, no latency tracking |
| **Security** | 4 / 10 | No webhook signature validation; anon key in frontend; RLS policy coverage unverified |
| **Reliability** | 5 / 10 | No retry on Make.com failure; partial-state possible if scenario errors mid-run |
| **Multi-Property Readiness** | 2 / 10 | Schema has no `property_id`; single Make.com scenario; single GHL account assumed |
| **Scalability** | 6 / 10 | Supabase scales horizontally; Make.com is operation-count limited; no queue buffering |
| **AI / Reporting Readiness** | 7 / 10 | Views provide stable query layer; `nightly_rate` + `total_amount` stored; occupancy derivable |
| **OVERALL MVP** | **6.7 / 10** | Strong foundation with clear, targeted gaps |

---

## Technical Debt Assessment

### High Priority
| Item | Risk | Effort |
|---|---|---|
| No webhook HMAC signature validation | Anyone who discovers the Make.com URL can inject reservations | Low — add secret header check in Module 1 |
| No retry / dead-letter queue | Mid-scenario Make.com failure leaves guest created but no GHL sync; no recovery path | Medium |
| No Row Level Security on Supabase | Anon key grants broad read access to all guest PII | Medium — write RLS policies per table |
| Single Make.com scenario, no environment separation | Dev testing hits production GHL and Supabase | Low — duplicate scenario, parameterize by env var |

### Medium Priority
| Item | Risk | Effort |
|---|---|---|
| `webhook_events` status never transitions to `failed` | Silent failures look like pending events | Low — add error handler route to Make.com |
| No schema migration system | Manual SQL edits in Supabase dashboard don't version-control cleanly | Medium — adopt Supabase Migrations CLI |
| `ghl_contact_id` writeback is async, not confirmed | Race condition: second booking before writeback completes falls through to email search | Low — acceptable for MVP, needs note in Phase 2 |
| Dashboard has no loading skeletons | Supabase query latency shows blank tables briefly | Low |

### Low Priority
| Item | Risk | Effort |
|---|---|---|
| Nightly rate hardcoded at $49.99 in React | Demo artifact; would need to be dynamic per site/season | Low |
| `num_nights` calculated client-side | Server should own this derivation | Low |
| No TypeScript types for Make.com payloads | Payload shape is documented but not enforced | Low |

---

## Production Readiness Assessment

### Ready for Production Today
- Data model is sound. Schema can be promoted to production as-is.
- DB trigger logic is server-authoritative — no client can corrupt loyalty state.
- Idempotency key pattern (`external_reservation_id`) prevents duplicate reservations from retries.
- `ghl_contact_id` fast-path pattern scales to high-volume returning guests.
- SQL views provide a stable API layer for reporting tools.

### Must Be Fixed Before Real Guest Data
1. **Webhook signature validation** — add `X-Webhook-Secret` header check in Make.com Module 1
2. **Supabase RLS** — enable and write policies for `guests`, `reservations`, `loyalty`, `webhook_events`
3. **Error handler in Make.com** — catch route that PATCHes `webhook_events.status = 'failed'`
4. **Environment separation** — staging scenario pointing to staging Supabase project

### Nice to Have Before Launch
- Make.com execution history surfaced in the webhook event log
- Email alerting on `failed` webhook_events
- Rate limiting on the Make.com webhook URL (Make.com supports IP allowlisting)

---

## What Would Impress a Hiring Manager

1. **The DB trigger is the tell.** Most candidates write loyalty updates inside Make.com. Putting loyalty computation inside a server-authoritative PostgreSQL trigger shows understanding of where state should live. Make.com can fail, retry, or be reconfigured — the trigger cannot be bypassed from any path.

2. **`ghl_contact_id` writeback.** Storing the GHL contact ID after first sync and using it as a fast-path on subsequent calls shows production CRM thinking, not tutorial thinking. It eliminates a search API call on every returning guest booking.

3. **Idempotency key on reservations.** `external_reservation_id` with a UNIQUE constraint means the entire pipeline is safe to replay. Retries, webhook duplicates, and test submissions cannot create corrupt data.

4. **Webhook_events as an audit log.** Having a structured JSONB record of every outbound automation event — with status transitions — is enterprise pattern. Most demos have no paper trail.

5. **SQL views as a stable reporting API.** Connecting Power BI (or any BI tool) to views instead of tables means the underlying schema can evolve without breaking reports. This is a genuine enterprise concern that most candidates ignore.

6. **The architecture is honest about the data flow.** The form POSTs to Make.com, not directly to Supabase. This matches the real production pattern where the reservation source (Campspot, RezWorks) fires a webhook. The demo is structurally identical to production.

---

## What Separates This From Most Applicants

Most applicants at this level build a CRUD form that writes to a database and call it done. This architecture demonstrates:

- **Event-driven thinking** — the reservation is an event, not a form submission. Everything downstream reacts to it.
- **System composition** — three separate platforms (Supabase, Make.com, GHL) are wired together with clean contracts.
- **CRM lifecycle design** — not just "create a contact" but a full contact lifecycle with tags, custom fields, tier management, and workflow triggers.
- **Reporting layer discipline** — views, KPI aggregation, and a data model that's BI-ready on day one.
- **Operational awareness** — `webhook_events` audit log, `ghl_contact_id` writeback, idempotency keys — these are the things you only know to build if you've been burned by not having them.

The Phase 2 roadmap below is what demonstrates the ceiling. A candidate who can hand a hiring manager a document like this is demonstrating that they've already solved the next 18 months of engineering decisions in their head.

---

## Phase 2 Roadmap

---

### Priority 1 — Reliability & Error Handling
**Goal:** Zero silent failures. Every automation either succeeds or leaves an auditable, recoverable failure record.

**2A — Make.com Error Handler Module**
- Add a catch/error route to the Make.com scenario
- On any module failure: PATCH `webhook_events.status = 'failed'`, store error message in payload
- Add `error_details` JSONB column to `webhook_events`
- Surface failed events in dashboard with a retry button (manual resubmit)

**2B — Dead-Letter Queue**
- Add `webhook_events.retry_count` INTEGER column (default 0)
- Add `webhook_events.next_retry_at` TIMESTAMPTZ column
- Build a second Make.com scenario: scheduled every 15 minutes, queries `webhook_events` where `status = 'failed'` AND `retry_count < 3` AND `next_retry_at <= NOW()`
- Exponential backoff: retry at +5min, +15min, +45min

```sql
ALTER TABLE webhook_events
  ADD COLUMN error_details  JSONB,
  ADD COLUMN retry_count    INTEGER DEFAULT 0,
  ADD COLUMN next_retry_at  TIMESTAMPTZ;
```

**2C — Idempotency Validation at Supabase**
- Add a Make.com HTTP call before guest upsert: check if `external_reservation_id` already exists
- If exists and `status = 'confirmed'`: short-circuit the scenario (already processed)
- Prevents double-processing on Make.com webhook retries

---

### Priority 2 — Security Hardening
**Goal:** No unauthenticated writes. No PII accessible without authorization.

**2D — Webhook Signature Validation**
- Generate a shared secret (32-char hex string)
- Store in Make.com scenario variable + React `.env.local`
- Form sends `X-Webhook-Secret: {secret}` header
- Make.com Module 1: filter → reject if header does not match
- Rotate secret without downtime: accept both old + new for a 5-minute overlap window

**2E — Supabase Row Level Security**
```sql
-- guests: only service role can write; anon can read own record via JWT sub
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_only_write" ON guests
  FOR ALL TO authenticated USING (true);
CREATE POLICY "anon_read_own" ON guests
  FOR SELECT TO anon USING (email = current_setting('app.user_email', true));

-- reservations: readable by dashboard (authenticated), writable by service role only
ALTER TABLE reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dashboard_read" ON reservations
  FOR SELECT TO authenticated USING (true);

-- webhook_events: service role only
ALTER TABLE webhook_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_only" ON webhook_events
  FOR ALL TO service_role USING (true);
```

**2F — Environment Separation**
- Create `campground-staging` Supabase project
- Duplicate Make.com scenario → staging variant
- Staging scenario uses staging Supabase URL + staging GHL sandbox
- React: `VITE_ENV=staging` controls which webhook URL is used

---

### Priority 3 — Reservation Lifecycle Events
**Goal:** The system reacts to the full guest journey, not just the booking moment.

**2G — Lifecycle Event Schema**
```sql
-- Extend status enum
ALTER TABLE reservations
  DROP CONSTRAINT reservations_status_check,
  ADD CONSTRAINT reservations_status_check
    CHECK (status IN ('confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show'));

-- Lifecycle events audit table
CREATE TABLE reservation_events (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID NOT NULL REFERENCES reservations(id),
  event_type     TEXT NOT NULL
                 CHECK (event_type IN (
                   'reservation.created', 'guest.checked_in',
                   'guest.checked_out', 'reservation.cancelled',
                   'loyalty.tier_upgraded'
                 )),
  payload        JSONB NOT NULL,
  triggered_by   TEXT DEFAULT 'system',
  created_at     TIMESTAMPTZ DEFAULT NOW()
);
```

**2H — Make.com Lifecycle Scenarios**
Three additional Make.com scenarios (not modules — separate scenarios):

| Scenario | Trigger | Actions |
|---|---|---|
| `guest.checked_in` | Supabase webhook on `status → checked_in` | Update GHL tag: remove `Active Reservation` → add `Currently Staying`; trigger In-Stay workflow |
| `guest.checked_out` | Supabase webhook on `status → checked_out` | Remove `Currently Staying` tag; add `Past Guest`; trigger Post-Stay Review Request workflow (24h delay in GHL) |
| `reservation.cancelled` | Supabase webhook on `status → cancelled` | Remove `Active Reservation` tag; update loyalty total_spend; trigger Cancellation workflow |

**2I — Supabase Database Webhooks**
Enable Supabase Database Webhooks (pg_net extension) to fire HTTP POST to Make.com on status column changes:
```sql
-- Fires when reservation status changes
CREATE OR REPLACE FUNCTION notify_reservation_status_change()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM net.http_post(
      url := current_setting('app.make_lifecycle_webhook_url'),
      body := jsonb_build_object(
        'event', 'reservation.' || NEW.status,
        'reservation_id', NEW.id,
        'previous_status', OLD.status,
        'new_status', NEW.status,
        'guest_id', NEW.guest_id
      )::text,
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_reservation_status_change
  AFTER UPDATE OF status ON reservations
  FOR EACH ROW EXECUTE FUNCTION notify_reservation_status_change();
```

---

### Priority 4 — Welcome Email & SMS Automation
**Goal:** Every booking triggers a personalized communication within 60 seconds.

**2J — GHL Workflow Architecture**

Four workflows to build in GoHighLevel:

| Workflow | Trigger | Timing | Channels |
|---|---|---|---|
| Welcome — New Guest | Contact tag added: `Active Reservation` + NOT `Past Guest` | Immediately | Email + SMS |
| Welcome — Returning Guest | Contact tag added: `Active Reservation` + `Past Guest` present | Immediately | Email + SMS |
| Pre-Arrival Reminder | 48 hours before `campground_check_in` date field | Wait step in GHL | SMS only |
| Post-Stay Review Request | 24 hours after `campground_check_out` date field | Wait step in GHL | Email |

**New Guest Email template variables:**
```
Hi {{contact.first_name}},

Your reservation at Campground is confirmed!

Site: {{contact.campground_last_site}}
Check-in: {{contact.campground_check_in}}
Check-out: {{contact.campground_check_out}}

You're starting your journey as a {{contact.campground_loyalty_tier}} member.
```

**Returning Guest Email:**
```
Welcome back, {{contact.first_name}}!

This is visit #{{contact.campground_total_visits}} — you're a {{contact.campground_loyalty_tier}} member.
[Tier-specific reward message based on tier custom field]
```

**2K — Loyalty Tier Upgrade Detection in Make.com**
- After loyalty retrieval module: compare `loyalty.tier` from DB against GHL custom field value
- If different → tier upgrade detected
- Remove old tier tag from GHL contact
- Add new tier tag
- Trigger GHL Workflow: "Loyalty Milestone — {tier}" (congratulations message)
- Log `loyalty.tier_upgraded` event to `reservation_events`

---

### Priority 5 — Loyalty System Evolution
**Goal:** Loyalty state drives behavior, not just labels.

**2L — Tier Benefit Differentiation**
```sql
CREATE TABLE tier_benefits (
  tier           TEXT PRIMARY KEY CHECK (tier IN ('Bronze', 'Silver', 'Gold')),
  early_checkin  BOOLEAN DEFAULT false,
  late_checkout  BOOLEAN DEFAULT false,
  site_upgrade   BOOLEAN DEFAULT false,
  discount_pct   NUMERIC(5,2) DEFAULT 0.00,
  welcome_gift   TEXT
);

INSERT INTO tier_benefits VALUES
  ('Bronze', false, false, false, 0,    'Welcome packet'),
  ('Silver', true,  false, false, 5.00, 'S''mores kit'),
  ('Gold',   true,  true,  true,  10.00,'Premium gift basket');
```

**2M — Loyalty Anniversary Trigger**
- New Make.com scenario: runs daily (scheduled)
- Queries `loyalty` where `last_visit` is 365 days ago ± 3 days
- Triggers GHL Workflow: "We Miss You" re-engagement campaign

**2N — Referral Tracking Groundwork**
```sql
ALTER TABLE guests ADD COLUMN referred_by_guest_id UUID REFERENCES guests(id);
ALTER TABLE reservations ADD COLUMN referral_code TEXT;
```

---

### Priority 6 — Multi-Property Support
**Goal:** One platform, N campground operators. Deploy once, replicate per property.

**2O — Schema Expansion**
```sql
CREATE TABLE properties (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  slug         TEXT UNIQUE NOT NULL,
  timezone     TEXT NOT NULL DEFAULT 'America/New_York',
  nightly_rate NUMERIC(10,2),
  ghl_location_id TEXT,  -- GHL sub-account per property
  make_webhook_url TEXT, -- property-specific Make.com webhook
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE reservations ADD COLUMN property_id UUID REFERENCES properties(id);
ALTER TABLE guests       ADD COLUMN home_property_id UUID REFERENCES properties(id);
ALTER TABLE loyalty      ADD COLUMN property_id UUID REFERENCES properties(id);

-- Composite unique: one loyalty record per guest per property
ALTER TABLE loyalty
  DROP CONSTRAINT loyalty_guest_id_key,
  ADD CONSTRAINT loyalty_guest_property_unique UNIQUE (guest_id, property_id);
```

**2P — Make.com Template Scenario**
- Build one "master" scenario as a template
- Each property gets a cloned scenario with:
  - Property-specific Supabase connection (or row filter on `property_id`)
  - Property-specific GHL sub-account connection
  - Property name injected into email/SMS templates
- Onboarding a new property = clone + configure, not rebuild

**2Q — Cross-Property Reporting View**
```sql
CREATE OR REPLACE VIEW cross_property_kpi AS
  SELECT
    p.name                                        AS property_name,
    COUNT(DISTINCT g.id)                          AS total_guests,
    COUNT(r.id)                                   AS total_reservations,
    COUNT(DISTINCT CASE WHEN l.total_visits > 1
      THEN g.id END)                              AS returning_guests,
    COALESCE(SUM(r.total_amount), 0)              AS total_revenue,
    COALESCE(AVG(r.total_amount), 0)              AS avg_booking_value
  FROM properties p
  LEFT JOIN reservations r ON r.property_id = p.id AND r.status != 'cancelled'
  LEFT JOIN guests g       ON g.id = r.guest_id
  LEFT JOIN loyalty l      ON l.guest_id = g.id AND l.property_id = p.id
  GROUP BY p.id, p.name;
```

---

### Priority 7 — Observability
**Goal:** Know when something breaks before a guest notices.

**2R — Webhook Event Dashboard Enhancements**
- Add `failed` badge with red styling and retry button in WebhookEventLog component
- Show Make.com module that failed (stored in `error_details.failed_module`)
- Filter by status: all / pending / sent / failed
- Time-to-process column: `sent_at - created_at` latency

**2S — Health Check Endpoint**
- Add a Supabase Edge Function: `GET /functions/v1/health`
- Returns: `{ status: "ok", pending_events: N, failed_events: N, last_processed_at: "..." }`
- Dashboard header shows a green/red system status indicator

**2T — Alerting**
- Make.com: on error handler activation, send email to `acamporedondo.ab@gmail.com`
- Subject: `[ALERT] Webhook processing failed — {guest_name} reservation #{external_id}`
- Supabase: pg_cron job runs hourly, counts `webhook_events` where `status = 'failed'` AND `created_at > NOW() - INTERVAL '1 hour'`, inserts into an `alerts` table if count > 0

---

### Priority 8 — AI Revenue Intelligence
**Goal:** Turn the existing data model into a dynamic pricing and demand forecasting engine.

**2U — Occupancy Data Model**
```sql
-- Derive occupancy from existing reservations table
CREATE OR REPLACE VIEW daily_occupancy AS
  SELECT
    d::date                                      AS date,
    COUNT(r.id)                                  AS occupied_sites,
    (COUNT(r.id)::NUMERIC / 50) * 100            AS occupancy_pct, -- 50 sites assumed
    COALESCE(SUM(r.nightly_rate), 0)             AS daily_revenue,
    COALESCE(AVG(r.nightly_rate), 0)             AS avg_nightly_rate
  FROM generate_series(
    (SELECT MIN(check_in) FROM reservations),
    (SELECT MAX(check_out) FROM reservations),
    '1 day'::interval
  ) AS d
  LEFT JOIN reservations r
    ON d::date >= r.check_in AND d::date < r.check_out
    AND r.status != 'cancelled'
  GROUP BY d::date
  ORDER BY d::date;
```

**2V — Revenue Intelligence Schema**
```sql
CREATE TABLE pricing_rules (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id  UUID REFERENCES properties(id),
  rule_name    TEXT NOT NULL,
  rule_type    TEXT CHECK (rule_type IN ('seasonal', 'demand', 'loyalty', 'length_of_stay')),
  conditions   JSONB NOT NULL,
  adjustment   JSONB NOT NULL, -- { "type": "percent", "value": 15 }
  active       BOOLEAN DEFAULT true,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE revenue_forecasts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id     UUID REFERENCES properties(id),
  forecast_date   DATE NOT NULL,
  predicted_occupancy NUMERIC(5,2),
  predicted_revenue   NUMERIC(10,2),
  recommended_rate    NUMERIC(10,2),
  model_version       TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

**2W — AI Integration Points**
The data model is already AI-ready. Integration points:

| Signal | Location | AI Use |
|---|---|---|
| Historical nightly rates | `reservations.nightly_rate` | Price elasticity baseline |
| Booking lead time | `reservations.created_at` vs `check_in` | Demand signal — early bookings = low price sensitivity |
| Occupancy by date | `daily_occupancy` view | Peak/shoulder/off-season detection |
| Guest tier distribution | `loyalty.tier` | Revenue mix — Gold guests tolerate higher rates |
| Cancellation rate | `reservation_events` | Risk adjustment for pricing |
| Site-level performance | `reservations.site_number` | Premium site identification |

Recommended integration: Supabase Edge Function that calls an LLM or ML endpoint with a 30-day occupancy + revenue summary, returns a recommended rate adjustment, stores in `revenue_forecasts`. The React dashboard surfaces this as a "Recommended Rate" card.

---

### Priority 9 — Enterprise Architecture Improvements
**Goal:** The system runs like a product, not a demo.

**2X — Schema Migration System**
Adopt Supabase CLI + Migrations:
```bash
supabase init          # creates supabase/ directory structure
supabase migration new add_retry_queue
# writes: supabase/migrations/20260611000001_add_retry_queue.sql
supabase db push       # applies to remote
```
Every schema change becomes a versioned, reversible migration file. Production deployments are `supabase db push`, not manual SQL editor edits.

**2Y — API Versioning**
Prefix all Supabase RPC functions and Edge Functions with `/v1/`:
```
GET  /functions/v1/health
POST /functions/v1/reservations
GET  /functions/v1/properties/{id}/kpi
```
Breaking changes go to `/v2/` — old integrations continue to work.

**2Z — Power BI Connection**
- Supabase exposes a direct PostgreSQL connection string
- Power BI Desktop: Get Data → PostgreSQL → connect to Supabase host
- Connect to views: `guest_summary`, `reservation_detail`, `kpi_summary`, `daily_occupancy`, `cross_property_kpi`
- Publish to Power BI Service for stakeholder reporting
- Scheduled refresh: every 30 minutes

---

## Phase 2 Implementation Sequence

| Wave | Items | Why First |
|---|---|---|
| **Wave 1** (Security + Reliability) | 2D webhook secret, 2E RLS, 2A error handler, 2B retry queue | Required before real guest data |
| **Wave 2** (Lifecycle + Comms) | 2G lifecycle schema, 2H Make.com scenarios, 2J GHL workflows | Core product value — guests feel looked after |
| **Wave 3** (Loyalty + Observability) | 2K tier upgrade detection, 2L tier benefits, 2R dashboard enhancements, 2S health check | Deepens retention and operational confidence |
| **Wave 4** (Multi-Property) | 2O schema expansion, 2P template scenario, 2Q cross-property view | Required before second campground onboards |
| **Wave 5** (AI + Enterprise) | 2U occupancy view, 2V revenue schema, 2W AI integration, 2X migrations | Revenue intelligence and platform maturity |

---

## Architecture Scorecard After Phase 2

| Dimension | MVP | Post-Phase 2 |
|---|---|---|
| Data Model | 8 | 9 |
| Automation Design | 7 | 9 |
| CRM Integration | 8 | 9 |
| Database Logic | 9 | 9 |
| Observability | 5 | 8 |
| Security | 4 | 8 |
| Reliability | 5 | 9 |
| Multi-Property Readiness | 2 | 8 |
| Scalability | 6 | 8 |
| AI / Reporting Readiness | 7 | 9 |
| **OVERALL** | **6.7** | **8.6** |

---

## One-Line Summary

The MVP proves the architecture works. Phase 2 proves it was designed to scale.
