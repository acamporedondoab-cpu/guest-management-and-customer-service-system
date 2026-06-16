# PROJECT_CHECKPOINT_V3.md
# Campground OS — Official Project Restoration Document & Source of Truth

**Document Status:** AUTHORITATIVE — Architecture & Security Freeze
**Checkpoint Date:** 2026-06-13
**Supersedes:** PROJECT_CHECKPOINT_V2.md
**Scope:** Final approved state after all architecture reviews, security audits, red-team reviews (two passes), migration-chain validation, and production-readiness reviews are complete.

> This document captures the **final approved state exactly as it exists today**. It does not redesign, propose alternatives, or speculate. It is sufficient to restore full project context, onboard a new developer, or resume a Claude session with no access to prior conversations.

---

## SECTION 1 — Executive Summary

### Product Vision

**Campground OS** is a multi-tenant guest management, retention, communication, loyalty, and CRM-enrichment platform for campground and RV park operators — especially portfolio operators running multiple properties under one organization.

**Primary Goal:** Guest Retention.

**Secondary Goals:**
- Guest Communication
- Check-In Automation
- Review Requests
- AI Concierge (deferred)
- Maintenance Routing (deferred)
- CRM Enrichment
- Multi-Property Management

**Key Principle:**
> "The reservation is the input. Guest retention is the outcome."

The platform does not originate reservations — it reacts to them. Every downstream behavior (loyalty crediting, CRM sync, welcome/pre-arrival/post-stay automations) is triggered by reservation events arriving from an external PMS.

### Joe's Clarified Vision (from interview)

- **Not a PMS replacement.** Campground OS does not manage availability, pricing calendars, or inventory.
- **The PMS remains the system of record for reservations.** It is the upstream source of truth for booking data.
- **Campground OS is the guest intelligence layer** — it aggregates guest identity across stays and properties, tracks loyalty, and drives retention.
- **GoHighLevel (GHL) remains the CRM layer** — all guest-facing email/SMS automation lives in GHL workflows.
- **N8N is preferred over Make.com** — more flexible, self-hostable, better routing for complex flows.
- **A dashboard is required** — operators need a real-time view without opening GHL.
- **Template-first onboarding** — every new operator runs the same guided setup.
- **Goal is 80–90% reusable onboarding** — minimal per-customer configuration; the platform is a managed SaaS product, not a bespoke build per client.

### Target Customer

Portfolio campground / RV park operators (typically 5+ properties) who need centralized, cross-property guest management rather than per-site point solutions.

---

## SECTION 2 — Final Approved Architecture

### Data Flow

```
[PMS: Campspot / RezWorks / Hostfully / RVshare / Hipcamp / Direct]
        │  reservation events (webhook / polling)
        ▼
[N8N — Automation Hub]   ── HMAC verify → upsert guest → insert reservation →
        │                    sync GHL contact → trigger GHL workflows →
        │                    update loyalty → mark webhook_events
        ▼
[Supabase — System of Record]   guests, reservations, loyalty, integrations, RLS
        │
        ▼
[GoHighLevel — CRM Execution]   contacts, tags, custom fields, email + SMS workflows
        │
        ▼
[Guest Retention]   returning guests, loyalty tiers, reviews, retention campaigns

[React Dashboard]  reads Supabase (auth + RLS) for operator-facing views
[OpenAI]           future AI concierge layer (deferred); reads Supabase KB via N8N
```

### Component Responsibilities

| Component | Responsibility |
|---|---|
| **PMS** | Source of truth for reservations. Emits booking/status events. Campground OS never writes availability or pricing back as MVP. |
| **Supabase** | System of record for guest identity, org/tenant data, reservations mirror, loyalty ledger, integration config, auth, and RLS enforcement. PostgreSQL + Auth + Realtime + (future) pgvector. |
| **N8N** | Automation hub between PMS, Supabase, and GHL. Webhook ingestion, validation (HMAC), idempotency, retries, reconciliation, CRM sync orchestration. Runs as `service_role` against Supabase. |
| **GoHighLevel** | CRM execution layer. Holds contacts, tags, custom fields; runs all guest-facing email/SMS workflows. One sub-account per organization. |
| **React Dashboard** | Operator-facing UI. Authenticates users, reads org-scoped data through RLS + views, writes guests/reservations through RPCs. |
| **OpenAI** | Future AI concierge (deferred). Receives guest chat (via GHL widget → N8N), retrieves org-scoped knowledge from Supabase pgvector, returns responses. No write tools. |

---

## SECTION 3 — Core Architecture Principles

### Organization Scope
`organization_id` is the tenant key present on every data table. An **organization** is a campground owner/management group — the top-level tenant. All properties, guests-in-context, reservations, loyalty, and integrations belong to exactly one organization.

### Property Scope
A **property** is one physical campground location belonging to an organization. Users may be org-wide or scoped to a single property via `user_roles.property_id`. Property scope is carried in the JWT (`property_id`, `is_org_wide`) and enforced in RLS for property-scoped staff.

### Global Guest Identity
The `guests` table is **global** — one row per unique person, deduplicated by email, shared across all organizations. A guest who stays with two different operators has **one** `guests` row. This prevents CRM contact duplication and enables cross-property/cross-operator identity. The global row holds only opaque identity (`id`, `email`) for tenant consumers; its deprecated PII columns are not readable by application users.

### Guest Org Profile
`guest_org_profiles` is the **per-organization overlay** on a global guest: one row per (guest, organization). It holds the org-scoped PII (first/last name, phone), the per-org CRM contact IDs, and soft-delete (`deleted_at`) for GDPR erasure. **All guest PII the application reads comes from here, never from the global `guests` row.**

### Data Isolation
Every tenant table has Row-Level Security enabled. Application roles (`anon`, `authenticated`) see only rows scoped to their JWT organization. Secrets (integration credentials, invitation tokens, deprecated org secrets) are additionally protected by column-level grants so they are structurally unreadable regardless of policy.

### Tenant Isolation
The hard security boundary. A user authenticated to Org A must never read, infer, or write Org B's data — including guest PII, existence signals, loyalty, or integration config. Enforced by RLS policies keyed on `jwt_org_id()`, `security_invoker` views, column grants, and SECURITY DEFINER RPCs that take org context from the JWT (never from arguments). This is the project's **highest priority**.

### Reservation Lifecycle
States (CHECK constraint on `reservations.status`): `confirmed → checked_in → checked_out`, plus `cancelled`. (`no_show` is referenced defensively in trigger code but is NOT in the CHECK constraint — dead code, non-blocking.) The reservation drives all loyalty and CRM events.

### Loyalty Lifecycle
- `total_visits` increments at **reservation INSERT** (booking intent — used for welcome messaging).
- `confirmed_visits` and `total_spend` are credited only at the **status transition to `checked_out`** (earned loyalty).
- Cancellations and no-shows require **no loyalty rollback** because earned loyalty was never credited at booking.
- Tier is recalculated at checkout using per-org thresholds.

---

## SECTION 4 — Database Architecture

All tables are in schema `public`. All have RLS enabled. Application reads/writes are gated by the v7 tenant policies (Section 8). `service_role` (N8N/admin) bypasses RLS.

### organizations
- **Purpose:** Top-level tenant. One row per campground owner/group.
- **Primary key:** `id UUID`.
- **Relationships:** Parent of properties, users' roles, guest_org_profiles, reservations, loyalty, all integration/config tables (via `organization_id`).
- **Key columns:** `name`, `slug` (UNIQUE), `plan` (`starter|pro|enterprise`), `status` (`active|suspended|cancelled`), deprecated `ghl_location_id` / `make_webhook_secret`.
- **Security notes:** `authenticated` SELECT is column-locked (excludes `ghl_location_id`, `make_webhook_secret`). UPDATE: owner only, and a trigger blocks changes to `slug`/`plan`/`status`/secrets via the API (platform/service-role managed). No INSERT/DELETE for `authenticated`.

### properties
- **Purpose:** Individual campground locations within an organization.
- **Primary key:** `id UUID`.
- **Relationships:** `organization_id → organizations`. Referenced by reservations, loyalty_by_property, user_roles.
- **Key columns:** `name`, `location`, `status` (`active|inactive`).
- **Security notes:** SELECT scoped to org + property scope; INSERT/UPDATE owner/manager and org-wide. No DELETE (retire via `status='inactive'`).

### users
- **Purpose:** Platform user accounts (staff/owners), decoupled from Supabase Auth to allow pre-provisioning.
- **Primary key:** `id UUID` (this is the `user_id` carried in the JWT).
- **Relationships:** `auth_user_id → auth.users(id)`; `active_org_id → organizations(id)`; referenced by user_roles.
- **Security notes:** SELECT = own row or fellow members of the active org. UPDATE = own row only; a BEFORE trigger makes `id`/`email`/`auth_user_id`/`created_at` immutable via the API (closes account-takeover). WITH CHECK validates `active_org_id` points at a real membership. No INSERT/DELETE for `authenticated`.

### user_roles
- **Purpose:** Role assignments. `property_id = NULL` → org-wide; set → property-scoped. Multiple rows per user allowed.
- **Primary key:** `id UUID`.
- **Relationships:** `user_id → users`, `organization_id → organizations`, `property_id → properties`.
- **Key columns:** `role` (`owner|manager|staff|viewer`), `revoked_at` (soft revocation; never delete).
- **Security notes:** The privilege-escalation boundary. Writes confined to `jwt_org_id()`; owners may grant any role; managers may grant/edit **only** `staff`/`viewer` (enforced in USING and WITH CHECK). A trigger forbids revoking/demoting the **last active owner**. No DELETE (revoke via `revoked_at`).

### guests
- **Purpose:** Global, deduplicated identity (one row per person, keyed by email).
- **Primary key:** `id UUID`; UNIQUE `email`.
- **Relationships:** Parent of guest_org_profiles, reservations, loyalty (by `guest_id`).
- **Security notes:** `authenticated` SELECT is column-locked to `(id, email)` — name/phone/`ghl_contact_id`/`created_at` are unreadable (cross-tenant first-writer PII and an existence-oracle timestamp). All direct writes revoked; the only authenticated write path is `upsert_guest()`. SELECT policy = EXISTS a live `guest_org_profiles` row for `jwt_org_id()`.

### guest_org_profiles
- **Purpose:** Per-org overlay of a global guest: org-scoped PII + CRM contact IDs.
- **Primary key:** `id UUID`; UNIQUE `(guest_id, organization_id)`.
- **Relationships:** `guest_id → guests`, `organization_id → organizations`.
- **Key columns:** `first_name` (NOT NULL), `last_name` (NOT NULL), `phone`, `ghl_contact_id` (deprecated), `crm_contact_ids JSONB`, `crm_synced_at`, `deleted_at` (GDPR soft delete).
- **Security notes:** SELECT/INSERT/UPDATE scoped to `jwt_org_id()` for owner/manager/staff. No DELETE (erase via `deleted_at`). This is the sole source of guest PII for the application.

### reservations
- **Purpose:** One row per booking event; the input that drives loyalty + CRM.
- **Primary key:** `id UUID`; UNIQUE `external_reservation_id` (PMS idempotency key).
- **Relationships:** `guest_id → guests`, `organization_id → organizations`, `property_id → properties`.
- **Key columns:** `site_number`, `check_in`, `check_out`, `num_guests`, `nightly_rate`, `total_amount`, `status` (`confirmed|checked_in|checked_out|cancelled`), `notes`.
- **Security notes:** SELECT scoped to org + property scope. UPDATE (status transitions) owner/manager/staff. **Direct INSERT is revoked**; the only authenticated insert path is `create_reservation()`, which binds `guest_id` and `property_id` to the JWT org. N8N inserts directly as `service_role` (with `external_reservation_id`).

### loyalty
- **Purpose:** Org-wide loyalty ledger. One row per (guest, organization).
- **Primary key:** `id UUID`; UNIQUE `loyalty_guest_org_unique (guest_id, organization_id)`.
- **Relationships:** `guest_id → guests`, `organization_id → organizations`.
- **Key columns:** `total_visits`, `confirmed_visits`, `total_spend`, `tier` (`Bronze|Silver|Gold`), `last_visit`.
- **Security notes:** Read-only to all API roles (SELECT scoped to org). Writes happen ONLY inside SECURITY DEFINER triggers and `service_role` — loyalty is server-authoritative; no caller can inflate visits/spend.

### loyalty_by_property
- **Purpose:** Per-property visit analytics. One row per (guest, property).
- **Primary key:** `id UUID`; UNIQUE `(guest_id, property_id)`.
- **Relationships:** `guest_id → guests`, `property_id → properties`, `organization_id → organizations`.
- **Key columns:** `confirmed_visits`, `total_spend`, `last_visit`.
- **Security notes:** Read-only, scoped to org + property scope. Written by triggers/service_role.

### crm_integrations
- **Purpose:** CRM provider config per org (one row per provider per org).
- **Primary key:** `id UUID`; UNIQUE `(organization_id, provider)`.
- **Key columns:** `provider` (`gohighlevel|hubspot|salesforce|none`), `external_account_id` (GHL location_id / HubSpot portal_id / Salesforce org_id), `credentials JSONB` (secrets), `config JSONB` (non-secret), `status`, `last_sync_at`.
- **Security notes:** `credentials` has NO SELECT to `authenticated` (column grant excludes it); all UI reads go through `crm_integrations_safe`. SELECT owner/manager; INSERT/UPDATE/DELETE owner only. `service_role` reads credentials for N8N.

### pms_integrations
- **Purpose:** PMS source config per org (same secure pattern as CRM).
- **Primary key:** `id UUID`; UNIQUE `(organization_id, provider)`.
- **Key columns:** `provider` (`campspot|rezworks|hostfully|rvshare|hipcamp|direct|none`), `external_property_id`, `credentials JSONB`, `config JSONB`, `sync_direction` (`inbound|bidirectional|outbound`), `status`, `last_sync_at`.
- **Security notes:** `credentials` unreadable by `authenticated`; reads via `pms_integrations_safe`. SELECT owner/manager; writes owner only.

### invitations
- **Purpose:** Token-based staff invitations.
- **Primary key:** `id UUID`; UNIQUE `token`.
- **Key columns:** `invited_email`, `role`, `property_id`, `token` (64-char hex, `gen_random_bytes(32)`), `expires_at` (7 days), `accepted_at`, `accepted_by`, `created_by`, `revoked_at`. Partial UNIQUE index blocks duplicate **pending** invites (`WHERE accepted_at IS NULL AND revoked_at IS NULL`).
- **Security notes:** `token` column unreadable by `authenticated` (column grant). INSERT/UPDATE mirror user_roles escalation rules (managers limited to staff/viewer). The claim path requires a future `claim_invitation()` SECURITY DEFINER RPC (deferred).

### onboarding_sessions
- **Purpose:** 7-step onboarding wizard state per org. One row per org.
- **Primary key:** `id UUID`; UNIQUE `organization_id`.
- **Key columns:** `current_step` (1–7), `completed_steps INTEGER[]`, `step_data JSONB`, `is_complete`, `completed_at`. Steps: 1 org basics, 2 first property, 3 loyalty config, 4 CRM, 5 PMS, 6 staff invitations, 7 test reservation.
- **Security notes:** SELECT scoped to org; INSERT/UPDATE owner only.

### webhook_events
- **Purpose:** Audit log of every outbound automation event; self-contained JSONB payload.
- **Primary key:** `id UUID`.
- **Relationships:** `reservation_id → reservations`, `organization_id`, `property_id`.
- **Key columns:** `event_type`, `payload JSONB`, `status` (`pending|sent|failed`), `retry_count`, `last_error`, `processed_at`.
- **Security notes:** Read-only audit for the dashboard, scoped to org + property scope. Writes by triggers/`service_role`. (Retention + PII minimization of `payload` is a deferred hardening item.)

### loyalty_config
- **Purpose:** Per-org loyalty tier thresholds.
- **Primary key:** `id UUID`; UNIQUE `organization_id`.
- **Key columns:** `silver_threshold` (default 3), `gold_threshold` (default 6); CHECK `silver >= 1 AND gold > silver`.
- **Security notes:** SELECT all org members; INSERT/UPDATE owner/manager.

### Supporting views
- **guest_summary** — `security_invoker`; org-scoped guest + loyalty; PII from `guest_org_profiles` only.
- **reservation_detail** — `security_invoker`; reservations + org-scoped guest name + property.
- **kpi_summary** — `security_invoker`; per-tenant aggregates (guests, reservations, returning, tiers, revenue, synced contacts, active CRM, pending/failed webhooks).
- **crm_integrations_safe** / **pms_integrations_safe** — `security_invoker`; exclude `credentials`.
- **user_accessible_orgs** — `security_invoker`; all orgs/roles for the current user (powers org switcher).

---

## SECTION 5 — Migration Chain (Final Approved)

**Apply in this exact order. The chain is self-sufficient and does NOT require `seed_simulation.sql`.**

| # | File | Purpose |
|---|---|---|
| 1 | `schema.sql` | v1 foundation: `properties`, `guests`, `reservations`, `loyalty`, `webhook_events`; `calculate_tier()`; `handle_new_reservation()` trigger; base views; RLS enabled + demo policies; grants. |
| 2 | `migrate_v2_multi_tenant.sql` | Multi-tenant: `organizations`, `users`, `user_roles`, `guest_org_profiles`, `loyalty_by_property`; adds `organization_id`/`property_id`/`confirmed_visits`/`external_reservation_id` to existing tables; `reservation_detail` view; demo policies (idempotent). |
| 3 | `migrate_v3_loyalty_lifecycle.sql` | **STEP 0: creates `loyalty_guest_org_unique (guest_id, organization_id)` (B2).** Corrects loyalty to checkout-only crediting; defines `handle_new_reservation`, `handle_reservation_status_change`, `handle_loyalty_tier_change` (all **SECURITY DEFINER** — B1); wires status/tier triggers; recalibrates data (no-op on a fresh DB). |
| 4 | `migrate_v4_auth_context.sql` | Auth context: `users.auth_user_id` + `active_org_id`; JWT helpers (`jwt_org_id/property_id/role/is_org_wide`); `custom_access_token_hook`; `user_accessible_orgs` view. |
| 5 | `migrate_v5_crm_integrations.sql` | CRM abstraction: `crm_integrations` + `crm_integrations_safe`; `guest_org_profiles.crm_contact_ids`; backfills from deprecated org columns; updates `guest_summary`/`kpi_summary`. |
| 6 | `migrate_v6_onboarding.sql` | `loyalty_config`; `calculate_tier()` rebuilt as STABLE org-aware `(INTEGER, UUID DEFAULT NULL)`; updates `handle_reservation_status_change` + `handle_new_reservation` (both **SECURITY DEFINER** — B1); `pms_integrations` + safe view; `invitations`; `onboarding_sessions`. |
| 7 | `migrate_v7_tenant_rls.sql` | **The security flip.** Drops all 15 demo policies; tenant RLS via `jwt_org_id()`/`jwt_role()`/`jwt_user_id()`; revokes all `anon` access; column-locks secrets + global guest PII; `upsert_guest()` + `create_reservation()` RPCs; flips trigger functions to SECURITY DEFINER (now redundant backstop after B1); rewrites `guest_summary`/`reservation_detail`/`kpi_summary` to `security_invoker` + org-scoped PII; `REVOKE EXECUTE … FROM PUBLIC` + explicit re-grants. |

### Important Dependencies
- v7 **requires** the v4 JWT hook to be **registered and verified** before applying, or every JWT lacks `org_id` and all users are locked out.
- v3 STEP 0 requires v2 (which adds `loyalty.organization_id` + `confirmed_visits`); v1's `loyalty.guest_id` UNIQUE (`loyalty_guest_id_key`) is dropped there.
- All trigger functions depend on `loyalty_guest_org_unique` at runtime (the `ON CONFLICT (guest_id, organization_id)` target).

### B1 — SECURITY DEFINER Replay Protection
The three loyalty trigger functions are defined `SECURITY DEFINER` + `SET search_path = public` in their **original definitions** in v3 (×3) and v6 (×2). Previously only v7's `ALTER FUNCTION` set this, so re-running v6/v3 after v7 would silently revert them to `SECURITY INVOKER` and break loyalty writes under RLS. Baking the attribute into the definitions makes it survive any replay. v7's `ALTER` remains as a harmless idempotent backstop.

### B2 — `loyalty_guest_org_unique` Moved Into the Migration Chain
The composite unique constraint previously lived only in `seed_simulation.sql` (Phase C, demo data). It is now created idempotently in **`migrate_v3` STEP 0** (`DROP CONSTRAINT IF EXISTS loyalty_guest_id_key` + guarded `ADD CONSTRAINT loyalty_guest_org_unique`). The constraint now exists whether or not the demo seed is ever run.

### seed_simulation.sql
**Optional demo data — no longer structurally required.** It seeds two demo orgs (Aries `…0001`, Blue Ridge `…0002`), demo users (`aries@test.com` `…0020`, `blue@test.com` `…0021`, both `owner`), and Sam Smith cross-org guest data. Its Phase C constraint block is retained only as an idempotent backstop for out-of-order runs. A production tenant deploys cleanly without it.

---

## SECTION 6 — Authentication Architecture

- **Supabase Auth** issues JWTs. Platform `users` rows are decoupled from `auth.users` via `users.auth_user_id` to allow pre-provisioning.
- **`auth_user_id`** links a platform user to a Supabase Auth identity (`auth.users.id`). UNIQUE; `ON DELETE SET NULL` preserves the user row for audit. Immutable via the API (BEFORE trigger).
- **`active_org_id`** persists a multi-org user's current org selection across sessions. `NULL` → the hook auto-resolves the highest-privilege org. Updated by the org-switcher; JWT re-enriched on `refreshSession()`.

### JWT Claims (in `app_metadata`)
`org_id`, `property_id`, `user_role`, `user_id` (= `public.users.id`), `is_org_wide`. `app_metadata` is server-controlled (not user-writable), and the hook overwrites it on every issuance.

### custom_access_token_hook
SECURITY DEFINER, `SET search_path = public`, granted to `supabase_auth_admin` only. Fires on every JWT issuance. Resolution order:
1. Find `users` where `auth_user_id = event.user_id`.
2. If `active_org_id` is set **and the user still holds an unrevoked role there**, use it; else fall through.
3. Else pick the highest-privilege active role (owner > manager > staff > viewer; tie-break earliest `created_at`).
4. Enrich `app_metadata`. **Never blocks auth** — any error is caught and the event returned unchanged (worst case: a JWT with no org context, which under v7 RLS can read nothing).

### JWT Helper Functions
All SQL, STABLE, SECURITY DEFINER, `SET search_path = public`, granted to `authenticated`:
- `jwt_org_id() → UUID`
- `jwt_role() → TEXT`
- `jwt_property_id() → UUID` (NULL for org-wide)
- `jwt_is_org_wide() → BOOLEAN`
- `jwt_user_id() → UUID` (added in v7; returns `public.users.id`)

### Active Organization Switching
1. UI updates `users.active_org_id` (own row; WITH CHECK validates membership).
2. UI calls `supabase.auth.refreshSession()`.
3. The hook re-issues a JWT scoped to the new org.
4. All subsequent queries auto-scope via `jwt_org_id()`.

### Multi-Organization Users
A user may hold roles in several orgs. `tenant_organizations_select` and `tenant_user_roles_select` expose the user's own rows across all their orgs (so `user_accessible_orgs` can populate the switcher), while data tables stay scoped to the single active `jwt_org_id()`.

---

## SECTION 7 — Authorization Model

### Roles
`owner`, `manager`, `staff`, `viewer` — assigned per (user, organization, optional property) in `user_roles`.

### Permission Philosophy
Least privilege, enforced in two layers: **grants** gate whether a role can touch a relation at all; **RLS policies** gate which rows and which role may act. Deletion is replaced by lifecycle columns (`status`, `revoked_at`, `deleted_at`) except for integrations (owner DELETE allowed). Privileged identity mutations are blocked by BEFORE triggers that RLS cannot express.

### Permission Matrix

| Action | owner | manager | staff | viewer |
|---|:--:|:--:|:--:|:--:|
| Read org data (guests, reservations, loyalty) | ✓ | ✓ | ✓ | ✓ |
| Create/Update guests (`upsert_guest`) | ✓ | ✓ | ✓ | ✗ |
| Create reservations (`create_reservation`) | ✓ | ✓ | ✓ | ✗ |
| Update reservation status | ✓ | ✓ | ✓ | ✗ |
| Manage properties | ✓ | ✓ | ✗ | ✗ |
| Manage loyalty config | ✓ | ✓ | ✗ | ✗ |
| Manage integrations (CRM/PMS) | ✓ | ✗ | ✗ | ✗ |
| Read integrations config (safe views) | ✓ | ✓ | ✗ | ✗ |
| Invite / revoke staff | ✓ | ✓* | ✗ | ✗ |
| Manage org settings (name) | ✓ | ✗ | ✗ | ✗ |

`*` Managers may grant/edit/invite **only** `staff` and `viewer` roles.

### Privilege-Escalation Protections
- `user_roles` writes confined to `jwt_org_id()`; managers capped at staff/viewer in both USING and WITH CHECK (cannot mint owners, cannot self-elevate — their own row is `manager`, outside their USING set).
- `invitations` mirror the same ceiling (an invite is a future role grant).
- `protect_last_owner` trigger blocks revoking/demoting the last active owner of an org.

### auth_user_id Protections
- `protect_users_columns` BEFORE trigger makes `id`, `email`, `auth_user_id`, `created_at` immutable for the `authenticated` role (RLS cannot restrict columns) — closes account takeover by re-pointing the auth link.
- `tenant_users_update` is own-row only, and its WITH CHECK requires any non-null `active_org_id` to correspond to a real unrevoked membership.

---

## SECTION 8 — Tenant Security Model

### RLS Architecture
RLS is enabled on all 15 tenant tables (5 in schema.sql, 5 in v2, 1 in v5, 4 in v6). v7 drops the 15 `demo_allow_all_*` policies and creates `tenant_<table>_<op>` policies keyed on `jwt_org_id()` + role helpers, within a single transaction (no unprotected window). `anon` loses all table and function access. With RLS enabled and no matching policy, PostgreSQL defaults to deny.

### security_invoker Views
`guest_summary`, `reservation_detail`, `kpi_summary`, `crm_integrations_safe`, `pms_integrations_safe`, `user_accessible_orgs` all use `WITH (security_invoker = true)` so RLS evaluates in the **caller's** context. Column grants make the safe views work (invoker views require the caller to hold SELECT on referenced base columns) while keeping `credentials` unreadable.

### Guest Identity Boundary
The hardest case. A guest is visible to an org only via a **live `guest_org_profiles` row** for `jwt_org_id()` (EXISTS policy — not column equality, because identity is global). Direct `guests` SELECT is column-locked to `(id, email)`; all writes go through `upsert_guest()`.

### guest_org_profiles Isolation
SELECT/INSERT/UPDATE strictly scoped to `jwt_org_id()`. This table is the only source of guest PII for the application; cross-org reads are impossible.

### Global Guest Restrictions
The global `guests` row exposes only `id` + `email` to `authenticated`. Name/phone/`ghl_contact_id`/`created_at` are withheld (first-writer cross-tenant PII and an existence-oracle timestamp). `upsert_guest()` does not propagate `phone` to the global row.

### create_reservation() RPC
SECURITY DEFINER, `search_path = public`, granted `authenticated`/`service_role`. The only authenticated reservation-insert path (direct INSERT revoked). Validates from JWT claims: tenant + write role, guest has a live profile in `jwt_org_id()`, property belongs to the org, property scope, `check_out > check_in`. Hard-codes `status = 'confirmed'`. Foreign/nonexistent `guest_id` and `property_id` return identical errors (no oracle).

### upsert_guest() RPC
SECURITY DEFINER, `search_path = public`, granted `authenticated`/`service_role`. The only authenticated write path into `guests`. Validates tenant + role (owner/manager/staff) + email format. Ensures the global identity row and the caller-org profile atomically; returns the `guest_id` without revealing whether the guest pre-existed in another tenant. Org id comes from the JWT, never from arguments.

### Red-Team Findings & Final Resolutions

| ID | Finding | Resolution |
|---|---|---|
| **RT-A1** | Self-provisioned profile → read global `guests` PII (direct SELECT was retained). | `REVOKE SELECT ON guests FROM authenticated`; `GRANT SELECT (id, email)` only. Names/phone/`ghl_contact_id` unreadable. |
| **RT-A2** | `guest_summary`/`reservation_detail` leaked global `g.*` (incl. `ghl_contact_id`) via COALESCE fallback and `g.first_name` name source. | Both views rewritten to source PII from `guest_org_profiles` only; no `g.*` PII fallback; `guest_summary` INNER JOINs a live profile. |
| **RT-A3** | `guests.created_at` (left in the column grant) re-opened the cross-tenant existence oracle (old timestamp = guest pre-existed platform-wide). | `created_at` removed from the grant; "guest since" exposed via `guest_summary.gop.created_at` instead. |
| **RT-B1** | `PUBLIC` holds default EXECUTE on functions; `REVOKE … FROM anon` was a no-op against PUBLIC, leaving SECURITY DEFINER RPCs callable by anon. | `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC` + explicit re-grants to `authenticated`/`service_role`/`supabase_auth_admin` only. |
| **RT-B2** | `reservations` INSERT did not bind `guest_id` to the caller's org (any global `guest_id` bookable; data pollution + reservation_detail leak channel). | `create_reservation()` RPC validates guest profile ∈ `jwt_org_id()`; direct INSERT revoked. |

---

## SECTION 9 — Loyalty Engine

### Domain Events & Effects

| Event | Effect |
|---|---|
| `reservation.created` (INSERT) | `total_visits += 1` (booking intent). No spend/confirmed credit. `loyalty_by_property` provisioned with zero counters. Webhook `reservation.created` fired. |
| `reservation.checked_out` (status → checked_out) | `confirmed_visits += 1`, `total_spend += total_amount`, `last_visit` set, **tier recalculated** via `calculate_tier(confirmed_visits, organization_id)`. Webhook fired; `loyalty.tier_updated` fired if tier changed. |
| `reservation.cancelled` | Status event + webhook only. **No loyalty reversal** (never credited at booking). |
| `reservation.no_show` | Defensive trigger branch only; **not** in the status CHECK constraint (dead code, non-blocking). No loyalty change. |

### Fields
- `total_visits` — booking-intent counter (increments at INSERT).
- `confirmed_visits` — earned visits (increments at checkout); drives tier.
- `total_spend` — lifetime spend (credited at checkout).
- `tier` — `Bronze | Silver | Gold`, recomputed at checkout.

### Per-Org Thresholds
`loyalty_config` holds `silver_threshold` (default 3) and `gold_threshold` (default 6) per org. `calculate_tier(visits INTEGER, p_org_id UUID DEFAULT NULL)` is **STABLE**, reads `loyalty_config`, and falls back to platform defaults (3/6) when no config exists. Loyalty writes occur ONLY inside SECURITY DEFINER triggers (server-authoritative).

---

## SECTION 10 — CRM Architecture

- **GoHighLevel strategy:** GHL is the CRM execution layer and holds all guest-facing email/SMS workflows. **One GHL sub-account per organization** (not per property).
- **`crm_integrations`:** one row per provider per org; `credentials` (secrets, never exposed to UI), `config` (non-secret), `external_account_id` (GHL location_id). Reads via `crm_integrations_safe`.
- **`crm_contact_ids` (on `guest_org_profiles`):** JSONB map of provider → contact ID per guest per org, e.g. `{"gohighlevel": "abc123"}`. Replaces the deprecated single `ghl_contact_id`.
- **GHL sub-account strategy:** `external_account_id` = GHL location_id; N8N reads it (and credentials) as `service_role` to sync contacts, tags, custom fields, and trigger workflows.
- **Future CRM abstraction:** the provider enum already supports `hubspot`, `salesforce`, `none`; the abstraction is in place for later, but MVP assumption is **GoHighLevel First**.

---

## SECTION 11 — PMS Architecture

- **PMS abstraction layer:** `pms_integrations` mirrors the CRM pattern — `provider`, `external_property_id`, `credentials` (secret), `config` (non-secret), `sync_direction` (`inbound` default), `status`. Reads via `pms_integrations_safe`.
- **Webhook ingestion strategy:** the PMS emits reservation events; N8N receives them, verifies an HMAC signature (per-org secret from `credentials`), and upserts to Supabase.
- **Normalization layer:** N8N maps provider-specific payloads to the canonical Supabase shape (guest via `upsert_guest`/service-role upsert, reservation via direct service-role insert keyed on `external_reservation_id`).
- **Future supported PMS examples:** Campspot, RezWorks, Hostfully (enum also includes RVshare, Hipcamp, Direct).
- **Source of truth:** the **PMS remains the system of record for reservations.** Campground OS mirrors and enriches; it does not own booking inventory.

---

## SECTION 12 — Dashboard Architecture

### Planned MVP Pages

| Page | Status |
|---|---|
| Login | Not implemented |
| Dashboard (KPIs) | Not implemented |
| Properties | Not implemented |
| Guests | Not implemented |
| Reservations | Not implemented |
| Staff (invitations) | Not implemented |
| CRM Settings | Not implemented |
| PMS Settings | Not implemented |
| Onboarding (7-step wizard) | Not implemented |
| Organization Settings | Not implemented |

### Implementation Notes (binding constraints)
- Authenticate before any query; the anonymous demo dashboard stops working under v7 by design.
- Provide an `OrgContext` (reads `user_accessible_orgs`) + Navbar org-switcher.
- Create guests via `supabase.rpc('upsert_guest', …)`; create reservations via `supabase.rpc('create_reservation', …)`.
- Read guest names/phone/CRM ids **only** from `guest_summary`/`reservation_detail` (never name columns from `guests`).
- Never `SELECT *` on `organizations`/`crm_integrations`/`pms_integrations`/`invitations`; use safe views or explicit columns. Credential entry is write-only.

**The entire React frontend is not yet implemented** — the v1 single-tenant app exists but is not multi-tenant aware.

---

## SECTION 13 — AI Concierge Roadmap (DEFERRED)

### Approved Future Architecture
```
Guest → GHL Chat Widget → N8N → Supabase Knowledge Base (pgvector) → OpenAI → Response
```

### Capabilities
- FAQ Routing (org-authored knowledge base content)
- Reservation Support (read-only, the guest's own reservation context pre-fetched server-side)
- Maintenance Requests (routing — deferred workflow)
- Human Escalation

### Required Data Model (before implementation)
`kb_documents`, `kb_chunks` (with denormalized `organization_id` + `embedding vector`), `concierge_threads`, `concierge_messages` — RLS on all from day one.

### Decisions
- **Use Supabase pgvector first. Do NOT introduce Pinecone initially.** Per-org KB is small; pgvector with HNSW keeps vectors under the same RLS roof and avoids a second tenant-isolation surface.
- Retrieval must filter `organization_id` server-side (from the N8N-verified webhook source, never model/prompt-supplied). The model gets zero write tools and no cross-guest read tools.

**Status: Deferred. Not blocking MVP.**

---

## SECTION 14 — N8N Architecture

- **Webhook Processing:** HTTPS, unguessable paths; first node verifies HMAC over the raw body (per-org secret from `pms_integrations.credentials`); reject + log on mismatch.
- **Retry Strategy:** per-node retry (≈3 attempts, exponential backoff) on Supabase + GHL HTTP nodes; terminal failures write `webhook_events.status='failed'` + `last_error`.
- **Idempotency Strategy:** upsert reservations on `external_reservation_id` (UNIQUE); upsert guests by email (`upsert_guest`/service-role). Prevents double-counting on PMS retries.
- **Reconciliation Jobs:** (1) daily replay of `webhook_events` in `pending`/`failed`; (2) **daily PMS reconciliation poll** (pull recent reservations, idempotent upsert) — converts any webhook-loss/N8N-outage into ≤24h delay instead of silent data loss.
- **Error Handling:** N8N error-workflow → alert; failed-event counters surfaced on the dashboard.
- **Monitoring:** alert on any failed execution; alert on `webhook_events.status='failed' > 0`; **zero-traffic heartbeat** per org (silent PMS disconnection detection).
- **Why N8N is preferred:** flexibility, complex routing, and **self-hostable**. Joe's stated preference over Make.com.
- **Self-hosted VPS recommendation:** run N8N on a self-hosted VPS (queue mode for HA at scale). N8N authenticates to Supabase with the `service_role` key (BYPASSRLS).

---

## SECTION 15 — Security Baseline

| Domain | Approved Decision |
|---|---|
| **JWT** | Enriched by `custom_access_token_hook` with org/property/role/user_id/is_org_wide in `app_metadata` (server-controlled). Helpers read claims for RLS. |
| **RLS** | Enabled on all 15 tenant tables; tenant policies keyed on `jwt_org_id()` + role; default-deny. |
| **Tenant Isolation** | The hard boundary; enforced by RLS + security_invoker views + column grants + DEFINER RPCs taking org from JWT. |
| **Least Privilege** | Two-layer (grants + policies); deletion via lifecycle columns; `REVOKE EXECUTE … FROM PUBLIC` + explicit re-grants; `anon` has zero data/function access. |
| **Webhook Validation** | HMAC signature verification in N8N (per-org secret), first node; reject + log on mismatch. |
| **Secrets Management** | Integration `credentials` + invitation `token` + deprecated org secrets are column-locked away from `authenticated`; readable only by `service_role`. (Vault/pgsodium migration is a deferred hardening item.) |
| **SQL Injection Protection** | No dynamic SQL anywhere; all access parameterized via PostgREST/static plpgsql. |
| **XSS Protection** | React escapes by default; treat guest-supplied fields (notes, names) as untrusted on render. (Frontend not yet built.) |
| **Prompt Injection Protection** | (AI layer, deferred) model gets no write/cross-guest tools; retrieval is server-scoped by org; untrusted KB content treated as data. |
| **Audit Logging Roadmap** | An `audit_log` table for role grants, credential changes, exports, deletions is a deferred item. |

**Top security priority: Cross-Tenant Data Leakage Prevention.** Every red-team finding (RT-A1/A2/A3/B1/B2) was a variant of this and is resolved.

---

## SECTION 16 — Deferred Features

All marked **Deferred — Not Blocking MVP**:

| Feature | Notes |
|---|---|
| Feature Entitlements | `organizations.plan` exists but nothing reads it; plan-based gating deferred. |
| Advanced Revenue Reporting | Per-site occupancy/ADR/time-series beyond current `kpi_summary`. |
| Audit Logs | `audit_log` table for sensitive actions. |
| Maintenance Workflow | Guest-initiated maintenance request routing. |
| AI Concierge | Full GHL→N8N→pgvector→OpenAI layer (Section 13). |
| Knowledge Base | `kb_documents`/`kb_chunks` + ingestion. |
| Customer Offboarding Automation | Cancel → disable integrations → export → grace → purge (incl. webhook payload PII). |
| Data Export Automation | Per-org export of guests/reservations/loyalty. |
| `claim_invitation()` RPC | SECURITY DEFINER token-claim flow (hash-compare, single-use) — invitations table exists, claim path not built. |
| `no_show` status | Add to `reservations.status` CHECK constraint (currently dead code). |
| Credentials → Vault | Move `crm/pms_integrations.credentials` to Supabase Vault/pgsodium. |
| webhook_events retention/PII minimization | TTL/partitioning + minimize payload to IDs. |
| Restricted `automation` role | Scope N8N below full `service_role`. |
| Billing / Stripe | No billing system yet. |
| Property-scoped enforcement in UI | JWT carries `property_id`; full UI property filtering deferred. |

---

## SECTION 17 — Production Readiness Status

| Area | Status |
|---|---|
| Architecture | **Complete** |
| Database (schema + migrations) | **Complete** |
| Security (RLS, isolation, red-team fixes) | **Complete** |
| Authentication (hook, JWT, helpers) | **Complete** (hook registration is a deploy step) |
| Authorization (roles, matrix, escalation guards) | **Complete** |
| CRM (crm_integrations + safe views + GHL-first) | **Complete** (schema); N8N scenario build = In Progress |
| PMS (pms_integrations + safe views) | **Complete** (schema); ingestion build = In Progress |
| Onboarding (tables/wizard state) | **Complete** (schema); wizard UI = Deferred/Not started |
| Dashboard (React) | **Deferred / Not started** |
| AI Concierge | **Deferred** |
| N8N (workflows) | **In Progress** (design complete, build pending) |
| Monitoring/Alerting | **Deferred** |

---

## SECTION 18 — Deployment Procedure

### Apply (fresh Supabase project)
1. Create a fresh Supabase project. Confirm `pgcrypto` is available (Supabase default).
2. Run `schema.sql`.
3. Run `migrate_v2_multi_tenant.sql`.
4. Run `migrate_v3_loyalty_lifecycle.sql`.
5. Run `migrate_v4_auth_context.sql`.
6. Run `migrate_v5_crm_integrations.sql`.
7. Run `migrate_v6_onboarding.sql`.
8. **Before v7:** create Auth users, backfill `users.auth_user_id`, register and **verify** `custom_access_token_hook` (Authentication → Hooks → Custom Access Token; Schema `public`).
9. Run `migrate_v7_tenant_rls.sql` (the security flip — only after the hook is verified).
10. Configure the Auth Hook in the dashboard if not already (Step 8).
11. Verify JWT enrichment (`app_metadata` contains `org_id`, `user_role`, `is_org_wide`).
12. Verify RLS (impersonation tests V0–V13 in v7).
13. Verify loyalty (insert → `total_visits++`; checkout → `confirmed_visits`/`total_spend`/tier).
14. Verify CRM (`crm_integrations_safe` readable; `credentials` denied).
15. Verify onboarding (wizard state rows / config).

> `seed_simulation.sql` is **optional** (demo data). Run it only to populate the two demo orgs; it is not required for a clean production tenant.

### Post-Deployment Validation Checklist
- [ ] No `demo_allow_all_*` policy remains (`pg_policies`); 30+ `tenant_*` policies present.
- [ ] `anon` denied on all tables and the SECURITY DEFINER RPCs (V1, V13a).
- [ ] Tenant isolation both directions: Org A cannot see Org B rows; `kpi_summary` is per-tenant (V2).
- [ ] Cross-org self-grant on `user_roles` rejected (V3); manager cannot mint owners (V4).
- [ ] `auth_user_id` immutable via API (V5); `active_org_id` must match membership (V6).
- [ ] `credentials` unreadable; safe views work (V7).
- [ ] Staff can book via `create_reservation`; DEFINER trigger writes loyalty (V8).
- [ ] Viewer is read-only (V9); last-owner lockout guard fires (V10).
- [ ] RT-A1: self-provisioned profile yields no global PII (V11).
- [ ] RT-A2: `guest_summary` shows only caller-org profile; no GHL fallback (V12).
- [ ] RT-B2: foreign `guest_id` rejected by `create_reservation`; direct reservation INSERT denied (V13b/c).
- [ ] JWT hook verified live for at least one user (else all locked out).

---

## SECTION 19 — Lessons Learned

### From Architecture, Security & Red-Team Reviews

**Why tenant isolation became the highest priority.** The first production-readiness audit found the database was effectively world-readable/writable via the public anon key (demo policies + anon grants). With real guest data, that is a reportable breach. Every other concern was downstream of switching real isolation on — so v7 (the security flip) was prioritized above all feature work.

**Why guest identity boundaries matter.** Because `guests` is a global table, the naive isolation model leaked: a user could self-provision a `guest_org_profiles` row (via `upsert_guest`) and then read another tenant's first-writer PII off the shared global row — directly, through the "safe" views' `g.*` fallbacks, and even via the `created_at` timestamp as an existence oracle (RT-A1/A2/A3). The resolution (column-lock `guests` to `(id,email)`, source all PII from `guest_org_profiles`, bind `guest_id` to org in `create_reservation`) established that **global identity must never carry tenant-visible PII, and membership rows must not be self-grantable into read access.**

**Why security moved ahead of dashboard development.** Every line of frontend/automation written against the permissive demo policies is untested against the real security model and breaks the day RLS flips. Writing v7 first (and validating it with impersonation tests) means the dashboard is built against the final contract: authenticate first, read via org-scoped views, write via RPCs, never `SELECT *` on secret-bearing tables.

**Why GHL-first became the MVP strategy.** Joe confirmed GHL stays the primary guest-communication platform and the dashboard should not duplicate email/SMS UI. The CRM abstraction (`crm_integrations`, provider enum, `crm_contact_ids`) is in place for future providers, but MVP targets GoHighLevel only — fastest path to value and aligned with the operator's existing operational core.

### From the Joe Interview
N8N over Make.com; dashboard required; non-technical employee UX; fast template-first onboarding (80–90% reusable); ongoing managed-service maintenance; property-centric GHL (one sub-account per org). These shaped scope: onboarding wizard and settings pages are MVP, not nice-to-haves; automation blueprints are N8N, not Make.com.

### From Migration Reviews (B1/B2)
Two replay/deploy hazards were closed: SECURITY DEFINER on the loyalty triggers is now baked into their v3/v6 definitions (survives re-runs), and `loyalty_guest_org_unique` lives in the schema chain (v3 STEP 0), so the stack deploys correctly without the demo seed.

---

## SECTION 20 — Current Project Status

**Campground OS — Final State Summary (2026-06-13)**

- **Architecture Phase = Complete.** Multi-tenant model, global-guest/org-profile split, PMS→Supabase→N8N→GHL flow, and AI/CRM/PMS abstractions are frozen.
- **Security Phase = Complete.** Production RLS (v7), JWT-based tenant context, two-layer least privilege, and all red-team findings (RT-A1/A2/A3/B1/B2) resolved and verification-tested. Cross-tenant data-leakage prevention is the established top priority and is closed on every known channel.
- **Migration Design Phase = Complete.** Seven-file chain (`schema → v2 → v3 → v4 → v5 → v6 → v7`) validated end-to-end; self-sufficient without `seed_simulation.sql`; B1/B2 fixes applied.
- **Implementation Phase = Ready.** The database, security model, auth, and authorization are deployable today. Remaining build work: N8N workflows, the React multi-tenant dashboard + onboarding wizard, monitoring, and the deferred features in Section 16.

**This document is the authoritative restoration reference.** A future developer or Claude session can rebuild full project context from Sections 1–20 alone: deploy via Section 18, enforce the security contract in Sections 7–8 and 15, and build against the constraints in Sections 12–14 without consulting any prior conversation.

---

*End of PROJECT_CHECKPOINT_V3.md — Architecture & Security Freeze, 2026-06-13.*
