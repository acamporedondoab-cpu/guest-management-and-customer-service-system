# PROJECT_CHECKPOINT_V4.md

**Project:** Campground OS — Multi-Tenant Guest Management & Revenue Intelligence Platform
**Checkpoint date:** 2026-06-15
**Supersedes:** PROJECT_CHECKPOINT_V3.md (architecture/security freeze)
**Status of this document:** SUPERSEDED by PROJECT_CHECKPOINT_V5.md (2026-06-15) after the V8 CRM Secure Credential Foundation was deployed and verified. Retained for history; the V8 completion record is appended below (see "V8 CRM Secure Credential Foundation — DEPLOYED & VERIFIED"). **Resume from V5.**

---

## Executive Summary

Campground OS is a multi-tenant SaaS platform for campground / RV-park operators. It is **not** a reservation system — the PMS (Campspot, RezWorks, Hostfully, etc.) remains the reservation source of truth. Campground OS is the **guest intelligence + retention layer**: it ingests reservations, computes loyalty/visit/spend state server-side, and syncs that intelligence into a CRM (GoHighLevel-first) to drive automated guest communications.

**Stack:** React 18 + Vite + TypeScript + Tailwind + react-router-dom v7 + `@supabase/supabase-js` 2.108 + date-fns. Backend = Supabase (Postgres + Auth + RLS). Automation layer = **N8N-first** (migrated away from Make.com). CRM = **GoHighLevel-first** (provider-abstracted).

**Current status:** Backend schema + security model are **frozen and validated** (migrations v1→v7 on disk). The React frontend is **functionally complete for read flows and the first write flow**. Authentication, JWT custom claims, multi-tenant RLS isolation, dashboard reads, and the **end-to-end reservation creation workflow are validated**. A class of JWT-claims and loyalty-trigger bugs discovered during reservation-creation bring-up have been **root-caused and resolved**. The next approved unit of work is **Phase 1 — CRM Secure Credential Foundation**.

---

## Architecture Status

Completed architecture milestones:

- ✅ **Multi-tenant model** — organization = tenant. All data scoped by `organization_id`; property is a sub-scope, not the tenant boundary.
- ✅ **JWT-claims tenancy** — org/role/property context delivered via signed JWT claims, set at token mint by `custom_access_token_hook`.
- ✅ **RLS-enforced isolation** — every tenant table carries org-scoped policies using JWT helper functions.
- ✅ **RPC-first writes** — guest/reservation writes go exclusively through `SECURITY DEFINER` RPCs; direct INSERT is revoked.
- ✅ **Safe-view reads** — all sensitive reads target `security_invoker` views that exclude secret columns.
- ✅ **Server-authoritative loyalty** — loyalty/visit/spend state is owned by DB triggers, not the client.
- ✅ **CRM provider abstraction** — `crm_integrations` table decouples provider specifics from the schema.
- ✅ **Event outbox** — `webhook_events` records every outbound automation event for N8N to drain.
- ✅ **Centralized auth context (frontend)** — `AuthProvider` is the single source of truth for JWT claims (via `getClaims()`).

---

## Backend Status

### Completed migrations (apply in order)

| File | Purpose |
|---|---|
| `supabase/schema.sql` | v1 foundation: guests, reservations, loyalty, webhook_events; `on_reservation_created` trigger; base views; grants |
| `supabase/migrate_v2_multi_tenant.sql` | organizations, users, user_roles, guest_org_profiles, loyalty_by_property; `organization_id` added across tables |
| `supabase/seed_simulation.sql` | Demo orgs + data; Phase D trigger **(contained the loyalty bug — see Bugs §5; superseded by v6)** |
| `supabase/migrate_v3_loyalty_lifecycle.sql` | Loyalty lifecycle fix: total_visits at booking; confirmed_visits/spend/last_visit credited at checkout |
| `supabase/migrate_v4_auth_context.sql` | `auth_user_id`/`active_org_id` on users; JWT helper functions; `custom_access_token_hook`; `user_accessible_orgs` |
| `supabase/migrate_v5_crm_integrations.sql` | `crm_integrations` table + `crm_integrations_safe` view; `crm_contact_ids` on guest_org_profiles |
| `supabase/migrate_v6_onboarding.sql` | loyalty_config (per-org thresholds); `calculate_tier(org_id)`; pms_integrations + safe view; invitations; onboarding_sessions; **current `handle_new_reservation()`** |
| `supabase/migrate_v7_tenant_rls.sql` | **The security flip**: drops all demo_allow_all policies; real tenant RLS; column-locked grants; trigger functions → SECURITY DEFINER; `upsert_guest()` / `create_reservation()` RPCs; column-protection triggers |

**Precondition:** v7 must only be applied after the v4 JWT hook is registered and verified in the Supabase dashboard, or all users lock out.

### Current production schema state

- **guests** (global identity, deduped by email) — app may read only `(id, email)`; PII lives in `guest_org_profiles`.
- **guest_org_profiles** — org-scoped PII (first/last/phone), `crm_contact_ids JSONB`, `crm_synced_at`, soft-delete `deleted_at`.
- **reservations** — org/property scoped; `status` lifecycle confirmed→checked_in→checked_out|cancelled; `CHECK (check_out > check_in)`; `external_reservation_id UNIQUE` (idempotency); direct INSERT revoked.
- **loyalty** / **loyalty_by_property** — server-maintained by triggers; `last_visit DATE`; read-only to API roles.
- **organizations** — column-locked SELECT; writable fields restricted; deprecated `ghl_location_id`/`make_webhook_secret` retained.
- **crm_integrations** / **pms_integrations** — provider configs; `credentials JSONB` never API-readable; `*_safe` views exclude it.
- **users / user_roles / invitations** — team model; `invitations.token` column-locked.
- **webhook_events** — outbound event outbox; `status pending|sent|failed`.
- **Views (security_invoker):** `kpi_summary`, `guest_summary`, `reservation_detail`, `crm_integrations_safe`, `pms_integrations_safe`, `user_accessible_orgs`.

### JWT claim architecture

`custom_access_token_hook(event)` enriches `claims.app_metadata` at token mint with:
`org_id`, `property_id`, `user_role` (owner|manager|staff|viewer), `user_id`, `is_org_wide`.
Org resolution: `users.active_org_id` preference → highest-privilege active role fallback.

Helper functions (SECURITY DEFINER STABLE) read `auth.jwt() -> 'app_metadata'`:
`jwt_org_id()`, `jwt_role()`, `jwt_user_id()`, `jwt_property_id()`, `jwt_is_org_wide()`.

**Critical distinction (see Bugs §1–2):** these claims live **only in the access-token JWT**, never in the persisted `auth.users.raw_app_meta_data`. The frontend must read them from the token (`supabase.auth.getClaims()`), not from `session.user.app_metadata`.

### RLS architecture

Every tenant table: `org = jwt_org_id()` plus role/scope predicates. Representative matrix:

| Table | SELECT | INSERT/UPDATE/DELETE |
|---|---|---|
| reservations | org + role∈(owner,manager,staff) (+property scope) | INSERT revoked (RPC only); UPDATE for status by owner/manager/staff |
| guests | `(id,email)` only; PII via views | all revoked (RPC only) |
| crm_integrations | org + role∈(owner,manager) | owner only |
| pms_integrations | org + role∈(owner,manager) | owner only |
| user_roles | own row or org | owner; manager limited to staff/viewer |
| invitations | org + role∈(owner,manager); token column-locked | owner/manager |
| loyalty | org-scoped | trigger/service-role only |

### RPC architecture

- **`upsert_guest(p_first_name, p_last_name, p_email, p_phone DEFAULT NULL) → uuid`** — only authenticated guest-write path. Roles owner/manager/staff. Org from JWT. Idempotent upsert; returns guest id without revealing cross-tenant pre-existence.
- **`create_reservation(p_guest_id, p_property_id, p_site_number, p_check_in, p_check_out, p_num_guests=1, p_nightly_rate=NULL, p_total_amount=NULL, p_notes=NULL) → uuid`** — only authenticated reservation-insert path. Validates: tenant+write role; guest has live profile in org; property in org; property scope; `check_out > check_in`. Fires loyalty trigger.
- Both `SECURITY DEFINER`, `search_path=public`, EXECUTE granted to `authenticated`/`service_role` only.

### Security model

- **RPC-only writes** for guests/reservations; **safe-view-only reads** for PII/secrets.
- **Credentials** (`crm_integrations.credentials`) are unreadable by `anon`/`authenticated` (REVOKE SELECT + column grant + view exclusion); only `service_role` reads them.
- **Server-authoritative loyalty** — only triggers (SECURITY DEFINER) and service role write loyalty tables.
- **Column-protection triggers** — `auth_user_id` immutable; `organizations.plan/status/slug` service-role only; last-owner lockout guard.
- **Red-team resolutions** (RT-A1/A2/A3/B1/B2) frozen in V3; preserved here.

---

## Frontend Status

### Completed pages

| Route | Page | Source | Mode |
|---|---|---|---|
| `/login` | LoginPage | Supabase Auth | auth |
| `/` | DashboardPage | `kpi_summary`, `guest_summary`, `reservation_detail` | read |
| `/guests` | GuestsPage | `guest_summary` | read |
| `/reservations` | ReservationsPage | `reservation_detail` | read |
| `/reservations/new` | NewReservationPage | `upsert_guest` + `create_reservation` RPCs | **write** |
| `/properties` | PropertiesPage | `properties` | read |
| `/team` | TeamPage | `users`+`user_roles` (client join), `invitations` | read |
| `/onboarding` | OnboardingPage | derived from org/team/integrations/guests/reservations | read |
| `/integrations` | IntegrationsPage | `crm_integrations_safe`, `pms_integrations_safe` | read |
| `/settings` | SettingsPage | `organizations` (explicit cols), integration counts, account | read |

### Completed features

- Supabase Auth sign-in/out, session persistence, `ProtectedRoute`, `AppLayout` (Sidebar + Topbar), "Campground OS" branding.
- KPI cards, guests/reservations tables, status pills/badges, shared `Card`/`PageHeader`/`DataState`/`Spinner`.
- **Reservation creation** with client validation, computed nights/total, role gating, friendly error mapping, post-create refresh-on-navigate.
- **Team v1** (members all roles; pending invitations owner/manager only; `auth_user_id`/`active_org_id`/`token` unselectable by type).
- **Onboarding Readiness** (7 derived steps from real data; no `onboarding_sessions` usage).
- **Centralized JWT claims** via `AuthProvider` exposing `role`/`orgId`/`propertyId`/`isOrgWide`.

### Current routing structure

`BrowserRouter` → `AuthProvider` → `Routes`: `/login` public; all app routes nested under one layout route `<ProtectedRoute><AppLayout/></ProtectedRoute>` with `<Outlet/>` (Dashboard, Guests, Reservations, Reservations/new, Properties, Team, Onboarding, Integrations, Settings).

### Auth architecture (frontend)

`AuthProvider` owns the Supabase `Session` **and** decodes JWT claims via `supabase.auth.getClaims(access_token)`, re-synced on initial load and every `onAuthStateChange` (SIGNED_IN / TOKEN_REFRESHED / SIGNED_OUT). Exposes `{ session, loading, role, orgId, propertyId, isOrgWide, signIn, signOut }`. Pages read claims from context — **no page reads `session.user.app_metadata`**.

### Known technical decisions

- **Column-allow-list typing** — the `Database` generic's Row types act as compile-time allow-lists (omitting a column makes selecting it a `tsc` error), enforcing "never expose" rules in the type system.
- **`supabase.rpc(..., args as never)`** — required because the Database `Row` types are TS **interfaces** (no implicit index signature) and so don't satisfy supabase-js `GenericSchema` (`Record<string, unknown>`), collapsing rpc `Args` inference to `never`. The strongly-typed wrapper parameter (`UpsertGuestArgs`/`CreateReservationArgs`) is the enforced contract; only the internal rpc arg is cast. A full fix (migrate every Row interface to a type alias) is deliberately deferred. *(Recorded in memory `rpc-typing-workaround.md`.)*
- **No OrgProvider yet** — claims read inline from `AuthProvider`; org switching deferred.
- **Refresh-on-navigate** — after a write, navigating to a list route remounts it and refetches (loyalty is server-updated, so refetch is the accurate update, not optimistic insert).
- **Build/typecheck:** `npm run build` = `tsc -b && vite build`; typecheck = `npx tsc -b`. (Note: a stale `node_modules/.tmp/*.tsbuildinfo` can cause a spurious TS5083 — clear it and rebuild.)

---

## Validated Workflows

| Workflow | What was tested | Result | Status |
|---|---|---|---|
| **Login** | Email/password sign-in, redirect to dashboard, sign-out | Works in browser | ✅ Validated |
| **Session persistence** | Reload restores session; ProtectedRoute gates unauth access | Works | ✅ Validated |
| **JWT claims** | Custom claims (`org_id`,`user_role`,…) read from token via `getClaims()`; owner resolves to `role='owner'` | Correct after fix | ✅ Validated |
| **Multi-tenant isolation** | Org-scoped RLS on reads/writes via `jwt_org_id()` | Enforced; no cross-tenant leakage | ✅ Validated |
| **Dashboard reads** | KPI cards + guests/reservations tables load from safe views | Loads successfully | ✅ Validated |
| **Guest management** | `guest_summary` listing, org-scoped PII, loyalty tier display | Renders | ✅ Validated (read) |
| **Reservation management** | `reservation_detail` listing, status badges, totals | Renders | ✅ Validated (read) |
| **Team page** | Members (all roles) + pending invitations (owner/manager); forbidden columns unselectable | Renders; typecheck enforces column rules | ✅ Implemented; read-path validated |
| **Onboarding page** | 7 readiness steps derived from live data; role-visibility of CRM/PMS steps | Renders | ✅ Implemented |
| **Reservation creation (end-to-end)** | Form → `upsert_guest` → `create_reservation` → `on_reservation_created` → loyalty + webhook_events → list refresh | Succeeds for owner; row + loyalty + event created | ✅ Validated |

---

## Major Bugs Resolved

### 1. JWT custom claims read from the wrong source
- **Root cause:** Pages read `session.user.app_metadata.user_role`, which is the persisted GoTrue user record (`{provider, providers}` only). The hook writes custom claims to the **token**, not the user record.
- **Investigation:** Confirmed `custom_access_token_hook` enriches `event.claims.app_metadata` and returns it; it never updates `auth.users`. Verified the token carried `user_role=owner` while `session.user.app_metadata` did not.
- **Resolution:** Centralized claim extraction in `AuthProvider` via `supabase.auth.getClaims()`; pages read `role/orgId/...` from context.

### 2. `session.user.app_metadata` vs JWT claims
- **Root cause:** Same source mismatch — the GoTrue User object is hydrated from the stored record, not by decoding the freshly minted access token.
- **Investigation:** Audited all four claim-reading pages (New Reservation, Team, Settings, Onboarding).
- **Resolution:** Removed every direct `session.user.app_metadata.*` read; replaced with `useAuth()` context values sourced from the token.

### 3. Reservation-creation permission issue (read-only notice for owners)
- **Root cause:** Downstream symptom of §1/§2 — `role` resolved to `null`, so `canWrite` was false and the form showed the read-only notice even for owners.
- **Investigation:** Confirmed the JWT contained `user_role=owner` but the page's source did not.
- **Resolution:** After the `getClaims()` fix, `role='owner'` → `canWrite=true`; form renders. Backend RPC role gate (`owner|manager|staff`) independently authorizes the write.

### 4. `handle_new_reservation()` stale-trigger issue
- **Root cause:** The deployed function was the **`seed_simulation.sql` Phase D version**, not the corrected v6 version (v3/v6 were either not applied or clobbered by re-running the seed).
- **Investigation:** Compared all three definitions; the live error signature was unique to seed_simulation. Provided a `pg_get_functiondef` verification query to confirm the active body.
- **Resolution:** Redeployed the v6 `CREATE OR REPLACE FUNCTION public.handle_new_reservation()` body (preserves trigger wiring, owner, grants). Reservation creation then validated end-to-end.

### 5. 42804 loyalty type-mismatch bug
- **Root cause:** In the seed_simulation `loyalty` INSERT, the `VALUES` list was **misaligned** with the column list: `last_visit` (DATE) received `calculate_tier(1)` (TEXT) → `column "last_visit" is of type date but expression is of type text` (SQLSTATE 42804).
- **Investigation:** Surfaced via temporary raw-error instrumentation on the form (`[create_reservation] code 42804 …`); traced to the swapped `tier`/`last_visit` values; the adjacent `DO UPDATE` clause proved the intended mapping.
- **Resolution:** Folded into §4 — the v6 body inserts `tier='Bronze', last_visit=NULL` (type-correct) and credits at checkout. Bug eliminated by the redeploy. Debug instrumentation subsequently removed.

### 6. SECURITY DEFINER restoration
- **Root cause / risk:** Under RLS, AFTER triggers run as the calling role; without `SECURITY DEFINER`, the loyalty/webhook writes inside `handle_new_reservation()` would be denied for authenticated users.
- **Investigation:** Confirmed v7 Step 3 `ALTER FUNCTION … SECURITY DEFINER SET search_path=public`, and that the v6 redeploy body itself declares `SECURITY DEFINER`/`search_path`.
- **Resolution:** The redeployed v6 body restored `SECURITY DEFINER` + pinned `search_path`; verified `prosecdef=true` / `proconfig={search_path=public}`. Loyalty writes succeed; loyalty remains server-authoritative.

---

## Current Data Flow (verified)

**Reservation creation — actual validated path:**

```
NewReservationPage (owner; role from getClaims → canWrite)
  │  client validation (required, email regex, check_out>check_in, guests>=1)
  ▼
upsert_guest(first,last,email,phone)            ← RPC, SECURITY DEFINER, role-gated, org from JWT
  │  ensures guests row + guest_org_profiles overlay; returns guest_id (idempotent)
  ▼
create_reservation(guest_id, property_id, …)    ← RPC, SECURITY DEFINER, validates guest-in-org/property/scope/dates
  │  INSERT INTO reservations (status='confirmed')
  ▼
on_reservation_created  →  handle_new_reservation()   ← AFTER INSERT trigger, SECURITY DEFINER (v6 body)
  │   ├─ upsert loyalty (total_visits +1; tier='Bronze'/last_visit=NULL at booking)
  │   ├─ upsert loyalty_by_property (provisioned, zeroed)
  │   └─ INSERT webhook_events ('reservation.created', payload incl. guest/loyalty/crm_contact_ids)
  ▼
navigate('/reservations')  →  remount  →  refetch reservation_detail / kpi_summary / guest_summary
  ▼
Dashboard + lists reflect the new reservation and updated loyalty
```

Outbound CRM delivery (N8N draining `webhook_events` → GoHighLevel) is **designed but not yet wired** (see Deferred).

---

## CRM Integration Audit Results

### Strengths
- `crm_integrations` table is provider-abstracted and GHL-aware; `UNIQUE(org, provider)`; indexed.
- RLS validated: owner-write / manager-read, org-scoped via JWT.
- **Credentials are not exposed** to API roles — REVOKE SELECT + column-level grant + `crm_integrations_safe` view all exclude `credentials`; only `service_role` can read them.
- Reusable **event outbox** (`webhook_events`) and **contact-id writeback** (`crm_contact_ids` + GIN index) already exist.

### Gaps
- **No secure write path** for secrets (today a credential write goes through the base table → value passes via client). *(High)*
- **Credentials stored as plaintext JSONB** — no Supabase Vault / app-level encryption. *(High)*
- **No GHL auth lifecycle modeling** (OAuth access/refresh/expiry/scopes). *(Med)*
- **No sync health columns** (`last_error`, `last_error_at`, sync cursor) backing `status='error'`. *(Med)*
- **Make.com-era naming** in config/credentials keys (`make_incoming_url`, `make_webhook_secret`) vs N8N-first. *(Med)*
- **Unstructured GHL config** (pipeline/calendar IDs, field-ID mappings, tag strategy). *(Med)*
- **No connect/disconnect UI**; Integrations page is read-only. *(Med)*

### Risks
- Plaintext secrets are a breach-blast-radius risk if the base table is ever exposed by a future grant/policy regression.
- Writing secrets through the client (without a write-only RPC) risks leakage via logs/state.
- Absent token-refresh modeling blocks OAuth-based GHL connections later.

### Recommendations
- Introduce an **owner-only `upsert_crm_integration` SECURITY DEFINER RPC** (write-only secrets, returns nothing sensitive) and revoke direct credential writes.
- Move secrets to **Supabase Vault**; keep only references in `credentials`.
- Add `last_error`/`last_error_at`/sync-cursor columns and **generalized N8N keys** (additive).
- Then build the **owner connect UI** and the **N8N outbound consumer**.

---

## Next Approved Priority — Phase 1: CRM Secure Credential Foundation

> ✅ **COMPLETED — deployed & verified 2026-06-15.** Delivered as `migrate_v8_crm_secure.sql`. See "V8 CRM Secure Credential Foundation — DEPLOYED & VERIFIED" below and PROJECT_CHECKPOINT_V5.md (authoritative).

**Goal:** make CRM secret storage breach-resistant and give owners a safe write path, without exposing any secret to the browser.

- **Vault strategy:** store GHL secrets (API key / Private Integration Token; later OAuth access+refresh) in **Supabase Vault** (`vault.secrets`). `crm_integrations.credentials` holds only non-secret refs (vault key id, token type, masked last-4, expiry). `service_role`/N8N resolve secrets at runtime.
- **`upsert_crm_integration` RPC:** owner-only, `SECURITY DEFINER`, org from JWT. Accepts provider, name, external_account_id (location_id), non-secret `config`, and **write-only** secret material (persisted to Vault). Returns the integration id and safe fields only — **never** credentials. Mirrors the `upsert_guest` pattern.
- **Secure secret storage:** revoke any direct credential write from `authenticated`; the RPC becomes the sole secret-write path. Safe view + column grants continue to exclude secrets on read.
- **Integration hardening goals:** add `last_error`/`last_error_at`/sync-cursor columns; generalize Make.com keys to N8N; structure GHL `config` (pipeline/calendar/field-ID maps, tag_prefix); add `connected_at`/`connected_by` audit. Decide manager non-secret-config edit vs owner-only.

**Exit criteria:** secrets never traverse a readable/client path; `crm_integrations_safe` still excludes credentials; SQL + `tsc` verification pass; an owner can persist a (test) GHL credential entirely via RPC.

---

# V8 CRM Secure Credential Foundation — DEPLOYED & VERIFIED

## Deployment Status

- `migrate_v8_crm_secure.sql` applied successfully.
- Transaction committed successfully.
- Vault preconditions passed.
- No rollback required.

## Verified Vault Facts

- supabase_vault version = **0.3.1**
- `create_secret` signature: `(new_secret text, new_name text, new_description text, new_key_id uuid)`
- `update_secret` signature: `(secret_id uuid, new_secret text, new_name text, new_description text, new_key_id uuid)`
- **service_role:** schema_usage = true, secrets_select = true, decrypted_select = true
- **authenticated:** no vault access
- **anon:** no vault access

## Design Decision

- **Resolver pattern retained as the architectural standard.**
- Even though service_role can directly access Vault, all automation continues to use `resolve_crm_secret()` for future portability and least-coupling.

## Verification Results

### Step 1 — PASS
- New columns verified; constraints verified; RPCs verified.
- `crm_integrations_safe` recreated successfully; `security_invoker = true` verified.

### Step 2 — PASS
- No legacy CRM secrets existed; backfill path validated as a safe no-op.

### Step 3 — PASS
- `credentials` excluded from `crm_integrations_safe`; `credential_ref` exposed instead.

### Step 4 — PASS
- authenticated cannot INSERT / UPDATE / DELETE, read `credentials`, read Vault, or execute the resolver.
- anon cannot execute the resolver.

### Step 5 — PASS (security validation)
- authenticated execution of `resolve_crm_secret()` denied (42501).
- Positive resolver test deferred (no committed CRM integration existed).

### Step 6 — PASS
- Owner successfully executed `upsert_crm_integration()`.
- Manager rejected with 42501; secret-leak-through-config rejected.
- Vault-only secret architecture enforced.

### Step 7 — PASS
- Tenant isolation verified; staff visibility blocked; direct INSERT blocked; RPC-only write path enforced.

## Security Outcome

Verified: Vault secret storage · browser isolation · owner-only CRM administration · resolver protection · multi-tenant isolation · direct-write prevention · secret-leak prevention.

## Deferred Validation

Positive resolver test remains deferred until a committed CRM integration exists. **Not a blocker** because:
- Resolver security path already verified.
- Vault access model already verified.
- Service-role Vault privileges empirically confirmed.

---

## Deferred Items (intentional)

- `claim_invitation()` RPC — functional invite acceptance is **blocked**; Team invites are display-only until this exists.
- Team management **writes** — invite creation, role editing, revocation (RLS-ready; no UI/RPC wired).
- **Org switching** + `OrgProvider` — claims read inline; `active_org_id` switching + `refreshSession()` deferred.
- **PMS ingestion** — inbound PMS→Campground OS reservation sync via N8N (PMS stays source of truth).
- **CRM outbound sync** — N8N draining `webhook_events` → GoHighLevel contact upsert + tag/field mapping + writeback.
- **Review-request / lifecycle automation** — pre-arrival, post-stay review, tier-milestone workflows.
- **Inbound CRM→OS** engagement sync (loop-guarded), AI pricing/forecasting layer.
- **Deprecated-column cleanup (v8)** — drop `organizations.ghl_location_id`/`make_webhook_secret`, `guest_org_profiles.ghl_contact_id` after N8N cutover.
- **Full rpc typing fix** — migrating Database Row interfaces to type aliases to remove `args as never`.

---

## Engineering Lessons Learned (reusable patterns)

- **Audit → Plan → Implement** — every feature began with a no-code audit and an explicit, scoped plan before implementation. Caught the CRM secret-write gap and the stale-trigger bug before they shipped.
- **Validate backend before frontend** — auditing RPC signatures/RLS first meant the frontend was built against verified contracts; reservation creation worked on first correct wiring once the trigger bug was fixed.
- **RPC-first architecture** — all sensitive writes go through `SECURITY DEFINER` RPCs with JWT-derived org/role; direct table writes revoked. Authorization is enforced server-side regardless of UI state.
- **Security-first design** — column-allow-list typing, safe views, credential column locking, server-authoritative loyalty. Defense in depth at the type system *and* the database.
- **Multi-tenant validation process** — confirm `jwt_org_id()` resolves correctly (token, not user record), then verify org-scoped reads/writes; the JWT-source bug taught: **always read claims from the token via `getClaims()`**.
- **Deployment verification process** — for any DB change: confirm active function body (`pg_get_functiondef`), `prosecdef`/`proconfig`, trigger enabled, owner privileged, then a transaction-wrapped smoke test with `ROLLBACK`. Temporary raw-error instrumentation (clearly tagged, later removed) is an effective way to surface the failing layer.

---

## Resume State — what to do next

1. **Implement Phase 1 (CRM Secure Credential Foundation)** — the only open 🔴. Order: (a) Vault layout + new columns + generalized N8N keys (additive migration, e.g. `migrate_v8_crm_secure.sql`); (b) `upsert_crm_integration` owner-only RPC + revoke direct credential writes; (c) verification queries; (d) owner connect UI on the Integrations page (managers read-only). Keep `crm_integrations_safe` as the read path.
2. **Then Phase 2–3** — GHL connect/test/activate UX, then the **N8N outbound consumer** draining `webhook_events` → GoHighLevel with loyalty/intelligence field+tag mapping and `crm_contact_ids` writeback.
3. **Pre-flight before any DB work** — verify the current deployed schema matches v7 + the v6 `handle_new_reservation()` body (the trigger-redeploy lesson); confirm the JWT hook is still registered.
4. **House rules to preserve** — backend schema/RLS/security model is **frozen** (modify only via additive forward migrations); do not implement OrgProvider/org-switching/writes/AI features unless explicitly approved; reads via safe views; writes via RPC; never expose `auth_user_id`/`active_org_id`/`token`/`credentials`.
5. **Working agreement** — proceed in tightly-scoped increments, each ending with a full `tsc -b`, a file-by-file diff summary, and a stop for review.

*End of PROJECT_CHECKPOINT_V4.md*
