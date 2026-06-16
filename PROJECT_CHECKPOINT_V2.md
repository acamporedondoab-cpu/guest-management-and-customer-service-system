# PROJECT_CHECKPOINT_V2.md
# Campground Guest Management & Revenue Intelligence Platform
**Checkpoint Date:** 2026-06-12  
**Status:** Schema complete. All 6 migration files on disk, production-hardened, ready for first Supabase apply.

---

## 1. Executive Summary

**Product Vision:**  
A multi-tenant SaaS platform for RV park and campground operators. Not a Property Management System (PMS) replacement — the PMS remains the source of reservation data. This platform sits downstream of the PMS and focuses on guest retention, communication automation, loyalty tracking, and CRM enrichment.

**The Core Insight:**  
> "The reservation is the input. Guest retention is the goal."

**Platform Capabilities (Current + Roadmap):**

| Capability | Status |
|---|---|
| Guest Communication Automation | Designed — N8N + GHL |
| Virtual Concierge | Roadmap |
| Review Generation | Roadmap |
| Loyalty Engine | Schema complete |
| CRM Enrichment (GoHighLevel) | Schema complete |
| Cross-Property Intelligence | Schema complete (loyalty_by_property) |
| Guest Retention Workflows | Designed |
| AI Concierge Layer | Deferred |

**Target Customer:**  
Portfolio campground operators — groups running 5+ properties who need centralized guest management, not per-site solutions. One platform deployment serves all their properties under a single organization account.

**Technology Stack:**
- **Database / API:** Supabase (PostgreSQL, RLS, JWT Auth, Realtime)
- **Automation Hub:** N8N (preferred over Make.com per Joe's direction)
- **CRM:** GoHighLevel (primary; schema supports HubSpot, Salesforce)
- **Frontend:** React + Tailwind CSS + Vite
- **PMS Sources:** Campspot, RezWorks, Hostfully, RVshare, Hipcamp, direct (abstracted)

---

## 2. Business Model Understanding

### What This Platform Is NOT
- Not a PMS — does not manage site availability, pricing calendars, or inventory
- Not a billing system — reservation amounts are received as data, not computed
- Not a booking engine — guests book through the PMS or existing channels

### What This Platform IS
- A guest data layer that aggregates identity across multiple property stays
- An automation trigger layer that reacts to reservation events
- A loyalty ledger that tracks visit counts, spend, and tier progression
- A CRM sync layer that keeps GoHighLevel contacts current
- A communication orchestration layer (welcome emails, pre-arrival, post-stay reviews)
- A dashboard and reporting layer for operators

### Joe's Interview Learnings (Captured 2026-06-12)
1. **GHL remains the primary platform** — all guest-facing communication stays in GHL workflows
2. **N8N preferred over Make.com** — more flexible, self-hostable, better for complex routing
3. **Dashboard is required** — operators need a real-time view without opening GHL
4. **User-friendly employee experience** — staff should be able to use this without training
5. **Fast onboarding is critical** — 80–90% reusable template per new operator; minimal setup time
6. **Ongoing maintenance expected** — platform is a managed service, not a one-time deployment
7. **Property-centric GHL architecture** — one GHL sub-account per organization (not per property)

### How Joe's Vision Shapes Development
- Onboarding wizard (Steps 1–7 in v6) must be functional before selling to new customers
- Settings pages (CRM config, loyalty thresholds, staff management) are MVP, not nice-to-have
- N8N scenario blueprints replace Make.com blueprints in all documentation
- The React dashboard is the operator's primary interface — GHL is for guest-facing automation only

---

## 3. Approved Architecture

### Data Flow

```
[PMS: Campspot / RezWorks / Hostfully / RVshare / Direct]
           │
           │  reservation.created event (webhook or polling)
           ▼
    [N8N — Automation Hub]
      ├─ Step 1:  Parse + validate incoming payload
      ├─ Step 2:  Upsert guest → Supabase (guests + guest_org_profiles)
      ├─ Step 3:  Insert reservation → Supabase
      ├─ Step 4:  Search GHL contact by email
      ├─ Step 5:  Create or Update GHL Contact (fields + tags)
      ├─ Step 6:  Trigger GHL Workflow → Welcome Email
      ├─ Step 7:  Trigger GHL Workflow → Welcome SMS
      ├─ Step 8:  Update loyalty record → Supabase
      └─ Step 9:  PATCH webhook_events status = 'sent'
           │
     ┌─────┴──────────────┐
     ▼                    ▼
[Supabase]            [GoHighLevel]
Source of truth       CRM execution layer
guests                Contacts (upserted)
reservations          Custom fields
loyalty               Tags
webhook_events        Workflows (email + SMS)
     │
     ▼
[React Dashboard]
Real-time via supabase-js
SQL Views → future BI tools
     │
     ▼
[Future: AI Layer]
Dynamic pricing engine
Revenue forecasting
Upsell recommendations
```

### Table Inventory and Purpose

| Table | Purpose |
|---|---|
| `organizations` | Top-level tenant. One row per campground owner or group. All data scopes here. |
| `properties` | Individual campground locations belonging to an organization. |
| `users` | Platform staff accounts. Decoupled from Supabase Auth for pre-provisioning. |
| `user_roles` | Flexible role assignments. `property_id = NULL` = org-wide; `property_id = set` = property-scoped. |
| `guests` | Global guest identity, deduplicated by email. Shared across organizations. |
| `guest_org_profiles` | Org-scoped guest attributes — name overrides, phone, CRM contact IDs per provider. |
| `reservations` | One row per booking event. Source of all downstream loyalty and CRM events. |
| `loyalty` | One row per guest per organization. Tracks `total_visits`, `confirmed_visits`, `total_spend`, `tier`. |
| `loyalty_by_property` | One row per guest per property. Enables property-level visit analytics. |
| `loyalty_config` | Per-org Silver/Gold thresholds. Platform defaults: Silver=3, Gold=6. |
| `webhook_events` | Audit log for every outbound automation event. Stores full JSONB payload. |
| `crm_integrations` | CRM provider config per org. Secrets in `credentials JSONB` (never exposed to frontend). |
| `pms_integrations` | PMS source config per org. Same secure pattern as crm_integrations. |
| `invitations` | Token-based staff invitations. 7-day expiry, single-use, partial unique index. |
| `onboarding_sessions` | 7-step onboarding wizard state per org. `completed_steps INTEGER[]`, `step_data JSONB`. |

---

## 4. Core Architecture Principles

### Multi-Tenant Architecture
Every data table carries `organization_id`. RLS policies enforce that users can only read and write rows belonging to their organization. The JWT token carries the org context so every query is automatically scoped.

**Organization Scope:** `organization_id` is the tenant key. All properties, guests, reservations, loyalty records, and integrations belong to exactly one organization.

**Data Isolation:** Row-Level Security on all tables. In demo mode: permissive `demo_allow_all_*` policies. In production: policies use `jwt_org_id()` helper to enforce tenant boundaries.

### Global Guest Identity
`guests` is a global table — a guest with the same email who stays at two different campground groups (organizations) has **one row** in `guests` but **two rows** in `guest_org_profiles`. This prevents contact duplication in GHL while enabling each org to maintain their own relationship with that guest.

### Reservation is the Input
The platform does not originate reservations. It reacts to them. Everything — loyalty credits, CRM updates, welcome automations — is triggered by reservation events arriving from the PMS.

### Loyalty Earned on Completed Stays
- `total_visits` increments at **reservation INSERT** (booking intent — for welcome messaging)
- `confirmed_visits` and `total_spend` credit only at **status transition to `checked_out`** (earned loyalty)
- Cancellations require **no loyalty rollback** because earned loyalty was never credited at booking time

### CRM Abstraction
`crm_integrations` table replaces the direct `ghl_location_id` column on `organizations`. Each org can have one integration per CRM provider. The `credentials JSONB` column has **no SELECT grant** to any role — all frontend reads go through `crm_integrations_safe` view which excludes the credentials column.

**Supported CRM providers:** `gohighlevel` | `hubspot` | `salesforce` | `none`

### PMS Abstraction
Same pattern as CRM. `pms_integrations` table allows each org to configure their reservation source. `pms_integrations_safe` view excludes credentials.

**Supported PMS providers:** `campspot` | `rezworks` | `hostfully` | `rvshare` | `hipcamp` | `direct` | `none`

### Template-First Onboarding
Every new operator runs the same 7-step onboarding wizard. Steps create loyalty config, configure CRM integration, connect PMS, and invite staff. Design goal: 80–90% of setup is automated, requiring only org-specific credentials.

---

## 5. Approved Migrations

### Execution Order (MUST follow this sequence)
```
1. schema.sql
2. migrate_v2_multi_tenant.sql
3. seed_simulation.sql
4. migrate_v3_loyalty_lifecycle.sql
5. migrate_v4_auth_context.sql
6. migrate_v5_crm_integrations.sql
7. migrate_v6_onboarding.sql
```

---

### schema.sql — v1 Foundation

**Purpose:** Creates the initial single-tenant schema. The base that all migrations build on.

**Tables Created:**
- `properties` — campground locations
- `guests` — identity table, unique on email, stores `ghl_contact_id` for CRM writeback
- `reservations` — booking events; status CHECK constraint: `confirmed | checked_in | checked_out | cancelled`
- `loyalty` — computed state per guest; maintained by trigger
- `webhook_events` — automation audit log

**Functions + Triggers:**
- `calculate_tier(INTEGER)` — IMMUTABLE (v1); thresholds: Bronze <3, Silver 3–5, Gold 6+
- `handle_new_reservation()` — AFTER INSERT on reservations; upserts loyalty + stores webhook payload
- `on_reservation_created` — trigger wiring

**Views:**
- `guest_summary` — guests joined with loyalty; columns: id, full_name, email, phone, ghl_contact_id, total_visits, total_spend, loyalty_tier, last_visit
- `reservation_detail` — reservations joined with guest name and property name
- `kpi_summary` — aggregated: total_guests, total_reservations, returning_guests, estimated_revenue

**RLS + Grants:**
- RLS enabled on all 5 tables
- Demo policies (permissive `FOR ALL USING (true)`) — **idempotency-hardened with DROP POLICY IF EXISTS** (C-6 patch applied)
- SELECT on all views granted to `anon, authenticated`
- `calculate_tier()` EXECUTE granted to `anon, authenticated`

---

### migrate_v2_multi_tenant.sql — Multi-Tenant Architecture

**Purpose:** Transforms the v1 single-tenant schema into a multi-tenant SaaS architecture. All additive — no columns dropped.

**New Tables:**
- `organizations` — top-level tenant (plan: starter/pro/enterprise; status: active/suspended/cancelled)
- `users` — platform user accounts (decoupled from Supabase Auth)
- `user_roles` — role assignments (owner/manager/staff/viewer; org-wide or property-scoped)
- `guest_org_profiles` — org-scoped guest attributes (first/last name overrides, phone, ghl_contact_id per org)
- `loyalty_by_property` — per-property visit counts and spend

**Columns Added to Existing Tables:**
- `properties.organization_id`
- `reservations.organization_id`, `reservations.property_id`, `reservations.external_reservation_id`
- `loyalty.organization_id`, `loyalty.confirmed_visits` (UNIQUE constraint changed to `(guest_id, organization_id)`)
- `webhook_events.organization_id`, `webhook_events.property_id`

**Views:**
- `reservation_detail` — updated to join `properties`; **`WITH (security_invoker = true)`** (C-4 patch applied)

**RLS:**
- 5 new demo policies across organizations, users, user_roles, guest_org_profiles, loyalty_by_property
- All **idempotency-hardened** with DROP POLICY IF EXISTS (C-6 patch applied)

---

### seed_simulation.sql — Demo Data

**Purpose:** Seeds two demo organizations with realistic guest and reservation data for development and demonstration.

**Seeded Organizations:**
| Org | UUID | Slug |
|---|---|---|
| Aries Hospitality | `00000000-0000-0000-0000-000000000001` | `aries-hospitality` |
| Blue Ridge Hospitality | `00000000-0000-0000-0000-000000000002` | `blue-ridge-hospitality` |

**Seeded Users:**
| User | UUID | Role |
|---|---|---|
| `aries@test.com` | `00000000-0000-0000-0000-000000000020` | `owner` |
| `blue@test.com` | `00000000-0000-0000-0000-000000000021` | `owner` |

**Seeded Guest:** Sam Smith — demonstrates cross-org guest identity (has reservations at both orgs)

**Known Issue (W-7, non-blocking):** `user_roles` INSERT uses `ON CONFLICT DO NOTHING` without a conflict target column. Would create duplicates on re-run. Fix: add UNIQUE constraint on `(user_id, organization_id, property_id)`.

---

### migrate_v3_loyalty_lifecycle.sql — Loyalty Lifecycle Correction

**Purpose:** Fixes the Phase D trigger in seed_simulation.sql which incorrectly credited loyalty at reservation INSERT time.

**Domain Events:**
| Event | What Happens |
|---|---|
| `reservation.created` | `total_visits` increments — booking intent, used for welcome messaging only |
| `reservation.checked_in` | Status event logged; no loyalty change |
| `reservation.checked_out` | `confirmed_visits` + `total_spend` credited; tier recalculated; `loyalty.tier_updated` event fired if tier changes |
| `reservation.cancelled` | Status event logged; **no loyalty reversal** — earned loyalty was never credited at booking |

**Functions Created/Replaced:**
- `handle_new_reservation()` — replaced; now increments `total_visits` only (no spend/confirmed_visits)
- `handle_reservation_status_change()` — new; credits confirmed_visits + total_spend at `checked_out`
- `handle_loyalty_tier_change()` — new; fires `loyalty.tier_updated` webhook event when tier changes

**Triggers Added (Gap 1 fix):**
- `reservation_status_change_events` — AFTER UPDATE OF status ON reservations
- `loyalty_tier_change_events` — AFTER UPDATE OF tier ON loyalty

**Data Recalibration (Step 5):**
After applying, existing demo data is corrected to match checkout-only logic:
- Sam + Aries: `total_visits=2, confirmed_visits=1, total_spend=149.97, tier=Bronze`
- Sam + Blue Ridge: `total_visits=1, confirmed_visits=0, total_spend=0.00, tier=Bronze`

---

### migrate_v4_auth_context.sql — Auth Context + JWT Enrichment

**Purpose:** Links platform users to Supabase Auth, enables multi-org switching, and enriches JWTs with tenant context on every login.

**Schema Additions:**
- `users.auth_user_id UUID` — links to `auth.users.id`; ON DELETE SET NULL preserves history
- `users.active_org_id UUID` — persistent org preference; NULL = auto-resolve from highest-privilege role

**JWT Helper Functions (SECURITY DEFINER, STABLE):**
| Function | Returns | Purpose |
|---|---|---|
| `jwt_org_id()` | UUID | Current tenant org from JWT |
| `jwt_property_id()` | UUID (nullable) | Property scope from JWT |
| `jwt_role()` | TEXT | Current user role from JWT |
| `jwt_is_org_wide()` | BOOLEAN | Whether user has org-wide access |

**custom_access_token_hook:**
- Fires on every Supabase Auth JWT issuance
- Enriches `app_metadata` with: `org_id`, `property_id`, `user_role`, `user_id`, `is_org_wide`
- Org resolution: `active_org_id` preference → highest-privilege role fallback
- **Never breaks auth** — EXCEPTION handler returns the event unchanged on any error
- Grant: `supabase_auth_admin` only (never anon or authenticated)

**Views:**
- `user_accessible_orgs` — shows all orgs and roles for the authenticated user; powers org-switcher; `WITH (security_invoker = true)`

**Multi-Org Switching Flow:**
1. Staff selects different org in React org-switcher
2. React calls: `UPDATE public.users SET active_org_id = $newOrgId WHERE auth_user_id = auth.uid()`
3. React calls: `supabase.auth.refreshSession()`
4. JWT re-issued with new org context in `app_metadata`
5. All subsequent queries automatically scoped to new org via `jwt_org_id()`

**Post-Migration Manual Steps (required before demo):**
1. Create Supabase Auth users for `aries@test.com` and `blue@test.com` (Authentication → Users → Invite User)
2. Backfill `auth_user_id`: `UPDATE public.users SET auth_user_id = '<auth-uuid>' WHERE email = 'aries@test.com'`
3. Register `custom_access_token_hook` in Authentication → Hooks → Custom Access Token Hook (Schema: public)
4. Verify JWT contains: `org_id`, `user_role = "owner"` for both demo users

---

### migrate_v5_crm_integrations.sql — CRM Integration Abstraction

**Purpose:** Replaces the direct GHL-specific columns on `organizations` with a reusable `crm_integrations` table. Enables multi-CRM support per org without future schema changes.

**New Tables:**
- `crm_integrations` — one row per CRM provider per org
  - `provider`: `gohighlevel | hubspot | salesforce | none`
  - `credentials JSONB` — **NEVER SELECT in frontend**; no SELECT grant to anon/authenticated
  - `config JSONB` — non-secret config (pipeline IDs, field maps, tag prefixes); safe for authenticated reads
  - `external_account_id` — GHL: location_id; HubSpot: portal_id; Salesforce: org_id

**New Views:**
- `crm_integrations_safe` — excludes `credentials` column; `WITH (security_invoker = true)`; SELECT granted to authenticated

**Schema Additions:**
- `guest_org_profiles.crm_contact_ids JSONB` — multi-provider contact ID map e.g. `{"gohighlevel": "abc123", "hubspot": "xyz789"}`
- GIN index on `crm_contact_ids` for fast provider lookups

**Data Migrations:**
- Backfills `crm_integrations` from existing `organizations.ghl_location_id` and `make_webhook_secret`
- Backfills `crm_contact_ids` on `guest_org_profiles` from existing `ghl_contact_id`
- `organizations.ghl_location_id` and `make_webhook_secret` columns deprecated via COMMENT (NOT dropped — scheduled for migrate_v7)

**Views Updated:**
- `guest_summary` — now includes `crm_contact_ids`, organization_id scoped; **`WITH (security_invoker = true)`** (C-4 patch applied)
- `kpi_summary` — updated for org-scoped aggregations

**Security Rule (non-negotiable):**
```
crm_integrations base table:   NO SELECT grant to anon or authenticated
crm_integrations_safe view:    SELECT granted to authenticated (credentials excluded)
All frontend reads MUST use:   crm_integrations_safe
```

---

### migrate_v6_onboarding.sql — Onboarding Infrastructure

**Purpose:** Adds per-org configurable loyalty thresholds, fixes the `calculate_tier()` volatility issue, adds PMS integration abstraction, staff invitation system, and onboarding wizard state tracking.

**New Tables:**

**`loyalty_config`** — per-org Silver/Gold visit thresholds
- `silver_threshold INTEGER DEFAULT 3`
- `gold_threshold INTEGER DEFAULT 6`
- CHECK: `silver_threshold >= 1 AND gold_threshold > silver_threshold`
- UNIQUE on `organization_id`

**`pms_integrations`** — PMS source config per org (same secure pattern as crm_integrations)
- `provider`: `campspot | rezworks | hostfully | rvshare | hipcamp | direct | none`
- `credentials JSONB` — NEVER exposed to frontend; use `pms_integrations_safe` view
- `pms_integrations_safe` view excludes credentials; `WITH (security_invoker = true)`

**`invitations`** — token-based staff invitations
- `token BYTEA` — `gen_random_bytes(32)` via pgcrypto (pre-installed on Supabase)
- 7-day expiry from `created_at`
- Partial UNIQUE index: `WHERE accepted_at IS NULL AND revoked_at IS NULL`
- Prevents duplicate pending invites; allows re-invitation after expiry or revocation

**`onboarding_sessions`** — 7-step wizard state per org
- `completed_steps INTEGER[]` — array of completed step numbers
- `step_data JSONB` — arbitrary per-step state (field values, config captured)
- Existing orgs backfilled with all 7 steps marked complete on migration

**Gap 3 Fix — calculate_tier() volatility:**
```sql
-- Cannot use CREATE OR REPLACE to change IMMUTABLE → STABLE
DROP FUNCTION IF EXISTS public.calculate_tier(INTEGER);

CREATE FUNCTION public.calculate_tier(
  visits     INTEGER,
  p_org_id   UUID DEFAULT NULL
) RETURNS TEXT AS $$
  -- Looks up loyalty_config for org-specific thresholds
  -- Falls back to platform defaults (3/6) if no config found
$$ LANGUAGE plpgsql STABLE;
```
This is backward compatible — existing callers with one argument still work via the DEFAULT NULL.

**RLS:**
- 4 new demo policies: loyalty_config, pms_integrations, invitations, onboarding_sessions
- All **idempotency-hardened** with DROP POLICY IF EXISTS (C-6 patch applied)

---

## 6. Production Hardening Decisions

All patches from the Production Readiness Audit have been applied to disk.

### C-1: Email Mismatch Fixed
**File:** `migrate_v4_auth_context.sql`  
**Issue:** Post-migration Step A referenced non-existent emails (`alex@arieshospitality.com`, `maya@blueridgehospitality.com`). UPDATE statements would silently match 0 rows, leaving `auth_user_id` NULL for all demo users.  
**Fix:** All 3 comment locations updated to use seeded emails: `aries@test.com` and `blue@test.com`.

### C-2: Wrong Role in Verification Docs Fixed
**File:** `migrate_v4_auth_context.sql`  
**Issue:** Step C expected `"user_role": "manager"` for Blue Ridge user. Seed plants `role = 'owner'`. Developer verifying JWT enrichment would think the hook was broken.  
**Fix:** Expected role corrected to `"owner"` for both demo users throughout Step C documentation.

### C-4: security_invoker Added to Views
**Files:** `migrate_v2_multi_tenant.sql` (reservation_detail), `migrate_v5_crm_integrations.sql` (guest_summary)  
**Issue:** Both views lacked `WITH (security_invoker = true)`. In demo mode (permissive RLS) this is safe. When real tenant policies are applied, the views would run as `postgres` and bypass RLS on all joined tables — a critical data leak.  
**Fix:** Both views recreated with `WITH (security_invoker = true)`. Safe to apply now; critical before production tenant policies.

### C-6: Policy Idempotency Fixed
**Files:** schema.sql, migrate_v2_multi_tenant.sql, migrate_v5_crm_integrations.sql, migrate_v6_onboarding.sql  
**Issue:** PostgreSQL `CREATE POLICY` has no `IF NOT EXISTS` syntax. Any migration re-run would error at the first policy creation ("policy already exists").  
**Fix:** `DROP POLICY IF EXISTS` added before every `CREATE POLICY` across all 4 files (15 total policy sites).

### JWT-Based Org Context
All RLS policies designed to use `jwt_org_id()` helper (v4) when demo policies are swapped for production policies. The JWT hook populates org context at login — no per-query overhead.

### CRM + PMS Credential Security
```
Base table SELECT grant:  NONE (anon, authenticated have no SELECT)
Frontend reads:           Always via *_safe views (credentials column excluded)
Write access:             authenticated only: INSERT, UPDATE, DELETE on base tables
Service role only:        Can read credentials (for N8N server-side automation)
```

### Active Organization Switching
Users with access to multiple orgs can switch context via `active_org_id` on `users` table + JWT refresh. Eliminates the need for separate login sessions per org.

---

## 7. Interview Learnings From Joe

These findings directly shape MVP scope and development priorities.

| Finding | Development Impact |
|---|---|
| GHL remains primary platform | Do not build duplicate email/SMS UI in React; focus dashboard on data and guest records |
| N8N preferred over Make.com | Update all automation blueprints and documentation from Make.com to N8N |
| Dashboard required | React dashboard is MVP, not optional |
| User-friendly employee experience | Settings and onboarding UX must be non-technical; avoid SQL or code exposure |
| Fast onboarding is critical | Onboarding wizard (v6) must be functional before launch; 7-step guided setup |
| 80–90% reusable template | Loyalty config defaults, GHL workflow templates, N8N scenario templates must ship as defaults |
| Ongoing maintenance expected | Build for operator self-service where possible; avoid requiring dev involvement for config changes |

**Architecture Implication:** The platform is a managed SaaS product sold to campground groups, not a custom-built system per client. Template-first design is a business requirement, not an engineering preference.

---

## 8. Known Deferred Items

All items below are intentional non-blocking deferrals. None block MVP.

| Item | Description | Priority |
|---|---|---|
| `no_show` status | Referenced in trigger code but absent from `reservations.status` CHECK constraint. Dead code — non-blocking. | Low |
| `claim_invitation()` function | SECURITY DEFINER function needed to validate invitation token and create user_roles entry. Invitations table exists but claim flow is not complete. | Medium (before staff invitations work) |
| Advanced revenue reporting | Per-site revenue, occupancy rate, ADR calculations. Views exist for basic revenue; detailed analytics requires additional views. | Medium |
| Feature entitlement system | Plan-based feature flags (starter/pro/enterprise). `organizations.plan` column exists but nothing reads it yet. | Low |
| Webhook retention strategy | `webhook_events` table has no TTL or archival. Will grow unbounded in production. | Medium (before production load) |
| AI concierge layer | Dynamic pricing engine, upsell recommendations, revenue forecasting. Reads from existing Supabase views. | Future |
| Chatbot layer | Guest-facing virtual concierge. Depends on AI layer. | Future |
| Maintenance request workflow | Guest-initiated site issue reporting. Out of scope for current platform version. | Future |
| migrate_v7 cleanup | Drop deprecated columns: `organizations.ghl_location_id`, `organizations.make_webhook_secret`, `guest_org_profiles.ghl_contact_id`. Only after Make.com/N8N scenarios and React confirmed not referencing them. | After production validation |
| W-7: user_roles UNIQUE constraint | `ON CONFLICT DO NOTHING` in seed has no conflict target. Requires UNIQUE constraint on `(user_id, organization_id, property_id)`. | Low (seed-only impact) |
| W-2: Invitation claim flow | `claim_invitation()` SECURITY DEFINER function not yet written. | Medium |

---

## 9. Current Project Status

| Layer | Component | Status |
|---|---|---|
| **Architecture** | Multi-tenant design, data model, org scoping | ✅ Complete |
| **Architecture** | N8N automation flow design | ✅ Designed (not built) |
| **Architecture** | GHL integration design | ✅ Designed (not built) |
| **Database Design** | All 6 migration files | ✅ Complete |
| **Database Design** | Production hardening (C-1, C-2, C-4, C-6 patches) | ✅ Applied to disk |
| **Database Design** | Applied to Supabase | ⬜ Not yet applied |
| **Loyalty Engine** | v3 lifecycle (checkout-only credits) | ✅ Complete |
| **Loyalty Engine** | Per-org configurable thresholds (v6) | ✅ Complete |
| **Auth Layer** | JWT enrichment hook | ✅ Complete |
| **Auth Layer** | Multi-org switching | ✅ Complete |
| **Auth Layer** | Demo users created in Supabase Auth | ⬜ Not yet done |
| **Auth Layer** | Hook registered in Supabase dashboard | ⬜ Not yet done |
| **CRM Layer** | crm_integrations table + safe view | ✅ Complete |
| **CRM Layer** | GHL contact lifecycle design | ✅ Designed |
| **CRM Layer** | N8N scenario built | ⬜ Not started |
| **PMS Layer** | pms_integrations table + safe view | ✅ Complete |
| **PMS Layer** | PMS webhook ingestion | ⬜ Not started |
| **Onboarding Layer** | invitations + onboarding_sessions tables | ✅ Complete |
| **Onboarding Layer** | React onboarding wizard UI | ⬜ Not started |
| **Dashboard** | Planning complete | ✅ Complete |
| **Dashboard** | React implementation | ⬜ Not started |
| **React Frontend** | Original v1 single-tenant app (exists on disk) | ✅ Exists |
| **React Frontend** | Updated for multi-tenant schema | ⬜ Not started |

---

## 10. Recommended Next Steps

Assume development resumes after this checkpoint. Follow this exact order:

### Step 1 — Verify Migration Files
Confirm all 6 SQL files are present and unmodified:
```
supabase/schema.sql
supabase/migrate_v2_multi_tenant.sql
supabase/seed_simulation.sql
supabase/migrate_v3_loyalty_lifecycle.sql
supabase/migrate_v4_auth_context.sql
supabase/migrate_v5_crm_integrations.sql
supabase/migrate_v6_onboarding.sql
```

### Step 2 — Verify Supabase Environment
- Confirm Supabase project URL and anon key in `.env`
- Confirm service role key available (needed for JWT hook registration)
- Confirm pgcrypto extension is enabled (required for invitations.token)

### Step 3 — Backup Database
If any data exists in the current Supabase project, export a backup before applying migrations.

### Step 4 — Apply Migrations in Order
Run each file in the Supabase SQL Editor in this exact sequence:
```
1. schema.sql
2. migrate_v2_multi_tenant.sql
3. seed_simulation.sql
4. migrate_v3_loyalty_lifecycle.sql
5. migrate_v4_auth_context.sql
6. migrate_v5_crm_integrations.sql
7. migrate_v6_onboarding.sql
```
Each file is idempotent — safe to re-run if a step fails mid-file.

### Step 5 — Post-Migration: Create Auth Users
In Supabase Dashboard → Authentication → Users → Invite User:
- Create `aries@test.com`
- Create `blue@test.com`

Then backfill `auth_user_id` in the SQL Editor:
```sql
UPDATE public.users
SET auth_user_id = (SELECT id FROM auth.users WHERE email = 'aries@test.com')
WHERE email = 'aries@test.com';

UPDATE public.users
SET auth_user_id = (SELECT id FROM auth.users WHERE email = 'blue@test.com')
WHERE email = 'blue@test.com';
```

### Step 6 — Validate JWT Enrichment
1. Register `custom_access_token_hook` in Authentication → Hooks → Custom Access Token Hook (Schema: `public`, Function: `custom_access_token_hook`)
2. Log in as `aries@test.com` in the React app
3. In browser console: `const { data } = await supabase.auth.getSession(); console.log(data.session.user.app_metadata)`
4. Verify output contains:
```json
{
  "org_id": "00000000-0000-0000-0000-000000000001",
  "user_role": "owner",
  "is_org_wide": true
}
```
5. Repeat for `blue@test.com` — expect `org_id` ending in `000000000002`, `user_role: "owner"`

### Step 7 — Validate Loyalty Lifecycle
1. Submit a test reservation via the React form (or INSERT directly via SQL)
2. Verify: `loyalty.total_visits` increments at INSERT; `confirmed_visits` does NOT
3. Update status to `checked_out`: `UPDATE reservations SET status = 'checked_out' WHERE id = '<id>'`
4. Verify: `loyalty.confirmed_visits` increments, `total_spend` updates, tier recalculated
5. Verify: `webhook_events` contains both `reservation.created` and `reservation.checked_out` events

### Step 8 — Validate CRM Integrations Security
```sql
-- These should return 0 rows (no SELECT grant on base table)
SET ROLE authenticated;
SELECT * FROM public.crm_integrations; -- should fail with permission denied
SELECT * FROM public.crm_integrations_safe; -- should succeed, credentials column absent
RESET ROLE;
```

### Step 9 — Begin MVP Dashboard
With the database validated, begin the React dashboard update:
1. Add `OrgContext` provider — reads `user_accessible_orgs` view, stores active org UUID
2. Add org-switcher to Navbar
3. Update all Supabase queries to filter by `organization_id` from OrgContext
4. Implement `guest_summary`, `reservation_detail`, `kpi_summary` views in dashboard components
5. Implement Settings pages: CRM config (reads `crm_integrations_safe`), loyalty config, PMS config, staff/invitations

---

## Appendix: Security-Critical Rules (Do Not Violate)

1. **NEVER SELECT from `crm_integrations` base table in frontend code.** Use `crm_integrations_safe`.
2. **NEVER SELECT from `pms_integrations` base table in frontend code.** Use `pms_integrations_safe`.
3. **NEVER expose `organizations.make_webhook_secret` to the frontend.** This column is deprecated and scheduled for removal in migrate_v7.
4. **`custom_access_token_hook` must only be granted to `supabase_auth_admin`.** Never grant EXECUTE to `anon` or `authenticated`.
5. **Do not swap demo_allow_all_* RLS policies for tenant-scoped policies until the JWT hook is verified working.** If the hook is misconfigured and you've applied real RLS, no one can read any data.
6. **All views used by the frontend must have `WITH (security_invoker = true)`** to ensure RLS is evaluated in the calling user's context, not the view owner's context.

---

*This document was generated 2026-06-12. It reflects the approved state of all migration files on disk after the Production Readiness Audit and patch application. No design decisions were changed in generating this document.*
