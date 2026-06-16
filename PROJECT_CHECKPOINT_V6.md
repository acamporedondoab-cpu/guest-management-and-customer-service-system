# PROJECT_CHECKPOINT_V6.md

**Project:** Campground OS — Multi-Tenant Guest Management & Revenue Intelligence Platform
**Checkpoint date:** 2026-06-15
**Supersedes:** PROJECT_CHECKPOINT_V5.md (Phase 1 — CRM Secure Credential Foundation complete; Phase 2 planned)
**Status of this document:** Authoritative continuation point. An engineer with zero prior context should be able to resume from this file alone.

---

## Executive Summary

Campground OS is a multi-tenant SaaS platform for campground / RV-park operators. It is **not** a reservation system — the PMS (Campspot, RezWorks, Hostfully, etc.) remains the reservation source of truth. Campground OS is the **guest intelligence + retention layer**: it ingests reservations, computes loyalty/visit/spend state server-side, and syncs that intelligence into a CRM (GoHighLevel-first) to drive automated guest communications.

**Stack:** React 18 + Vite + TypeScript + Tailwind + react-router-dom v7 + `@supabase/supabase-js` 2.108 + date-fns. Backend = Supabase (Postgres + Auth + RLS + **Vault**). Automation layer = **N8N-first**. CRM = **GoHighLevel-first** (provider-abstracted).

**What changed since V5:** **Phase 2 — CRM Integrations UI & Workflow Layer is COMPLETE (frontend).** Owners can now Connect, Rotate, and Edit basic metadata for a GoHighLevel integration through an owner-only UI built entirely on the V8 architecture, and can trigger a server-mediated Connection Test. All CRM secret writes go exclusively through `upsert_crm_integration()`; the browser still has no readable or writable secret path. Backend schema + security model remain **frozen** (modify only via additive forward migrations).

**Current status:** Backend migrations **v1→v8** on disk and applied. Frontend is functionally complete for read flows, the reservation write flow, and **CRM credential management + connection-test UI**. The two remaining Phase-2-adjacent pieces are **out-of-repo infrastructure** (not yet built): the connection-test **Edge Function** and the **N8N outbound `webhook_events` consumer**. **Next approved unit of work: Phase 3 — CRM Automation Engine.**

---

## Phase 2 — CRM Integrations UI & Workflow Layer ✅ COMPLETE

Phase 2 was delivered as five reviewed, individually-approved increments, each ending green on a full `tsc -b`. The backend was **not** touched — every increment is frontend-only and builds on the frozen v8 objects (`upsert_crm_integration()`, `resolve_crm_secret()`, `crm_integrations_safe`).

### 1. Increment A — Type & Database-generic foundation
- `src/lib/types.ts`: introduced **`CrmCredentialRef`** (frontend-facing masked metadata only: `token_type`, `last4`, `expires_at`) — **`vault_secret_id` deliberately omitted** so the type system forbids surfacing the Vault pointer.
- Extended **`CrmIntegrationSafe`** to match the v8 view's 17 columns (added `auth_type`, `credential_ref`, `connected_at`, `connected_by`, `last_error`, `last_error_at`, `sync_cursor`); no `credentials` anywhere.
- Added **`UpsertCrmIntegrationArgs`** and masked **`UpsertCrmIntegrationResult`** (`last4`, never plaintext).
- Registered **`upsert_crm_integration`** in the `Database.Functions` generic; **`resolve_crm_secret` deliberately absent** (service_role-only; never browser-callable).

### 2. Increment B — API layer
- `src/api/integrations.ts`: added **`upsertCrmIntegration(args)`** — sole authenticated CRM-secret write path, using the documented `args as never` RPC workaround (mirrors `reservations.ts`). Returns masked fields only.
- Added **`testCrmConnection(integrationId)`** — sends only `{ integration_id }` + the caller's session JWT to `VITE_CRM_TEST_ENDPOINT_URL`; never touches a secret, never references `resolve_crm_secret`, never receives a secret back. Returns `{ ok, message, checkedAt }`.
- Added **`friendlyCrmError(e)`** — maps `42501` / config-secret-guard / invalid provider/auth_type / unconfigured-endpoint to safe copy; never surfaces raw DB errors or secrets.

### 3. Increment C — Read-surface upgrade
- `src/pages/IntegrationsPage.tsx`: dedicated CRM table surfacing v8 metadata — **provider, auth_type, masked last4, connected_at, last_sync_at, status**, plus a red sub-row for `last_error`/`last_error_at` when `status='error'`.
- Missing/empty `credential_ref` handled gracefully (`•••• {last4}` or `—`). Never exposes `credentials`, `vault_secret_id`, or resolver concepts. Manager/staff visibility preserved (RLS-driven; no role logic added at this step).

### 4. Increment D — Owner CRM management UI (GoHighLevel only)
- **New** `src/components/integrations/CrmIntegrationModal.tsx`: owner-only Connect / Manage form, **GHL-only** (provider locked). Fields: name, Location ID (`external_account_id`), `auth_type` (`api_key`/`private_token`/`oauth2`), secret, `expires_at`. **No config editor** — every write sends `p_config: {}`.
- Two modes: `connect` (secret required) and `manage` (secret optional → blank = edit basic metadata; filled = rotate). Blank secret is **omitted** from args so the RPC preserves the existing credential.
- **Secret held in local component state only** — `type="password"`, `autoComplete="new-password"`, never pre-filled, cleared before unmount, never logged/echoed. Submits via `upsertCrmIntegration`; errors via `friendlyCrmError`.
- `IntegrationsPage.tsx`: `canManage = role === 'owner'`; re-readable `loadIntegrations()` (refetch after writes); owner-only **Connect CRM** button (when no GHL row) + per-row **Manage** action; dismissible success notice with the returned masked `last4`. **Disconnect intentionally deferred** to a future additive migration (no v8 disable/secret-clear path).

### 5. Increment E — Connection testing UI (frontend only)
- `IntegrationsPage.tsx`: owner-only **Test** button per GHL row alongside Manage; per-row loading state (`testingId` → "Testing…", disabled in-flight); tone-aware success/failure notices (green for `ok`, red for `ok:false` / thrown via `friendlyCrmError`).
- Test button **disabled with tooltip** when `VITE_CRM_TEST_ENDPOINT_URL` is unset (`TEST_ENDPOINT_CONFIGURED`).
- **Refetches `crm_integrations_safe` after completion** so any server-side `status`/`last_error` write-back is reflected.
- The endpoint behind `VITE_CRM_TEST_ENDPOINT_URL` is **out-of-repo infra** (see frozen contract below) and is **not yet implemented**.

---

## Connection-Test Endpoint — Frozen Contract (NOT yet implemented)

Locked during the Increment E Design Freeze Review. Recommended implementation: **Supabase Edge Function** `crm-test-connection` (synchronous, JWT-authenticated, secret-resolving) — with N8N reserved for the asynchronous outbound consumer.

- **Request:** `POST`, `{ "integration_id": "<uuid>" }` + `Authorization: Bearer <user access_token>`. Nothing else trusted from the body.
- **Five confirmed Δ decisions:**
  1. JWT claims (`org_id`, `user_role`) read from the **verified token `app_metadata`**, NOT `getUser()` (custom claims are JWT-only, per `AuthProvider.readClaims`).
  2. **`last_sync_at` reserved for actual CRM synchronization** — a connection test must NOT write it.
  3. **Transient provider failures (429, timeout, 5xx, network) must NOT write `status='error'`** (avoid flapping); only definitive credential failures do.
  4. **Unknown/cross-org integration → 404**; **same-org non-owner → 403** (prevents cross-tenant enumeration oracle).
  5. **OAuth testing deferred**; supports **`api_key` and `private_token`** only this phase.
- **AuthZ order:** verify JWT → derive org/role from claims → service_role-load integration → cross-check org → owner gate → resolve **only after** authz passes.
- **GHL check (read-only, no side effects):** `GET /locations/{external_account_id}`; headers per `auth_type` (Bearer + pinned `Version: 2021-07-28` for private_token; v1 base for api_key).
- **Outcomes:** success → `200 {ok:true}` + write `status='active'`, clear `last_error/_at`, **leave `last_sync_at`**; definitive failure → `200 {ok:false,<reason>}` + write `status='error'`, `last_error/_at`; transient → `200 {ok:false,…}` or 502/504, **no status write**. Response always masked; never a token.
- **First successful test closes V8's deferred positive resolver test** (V8_DEPLOYMENT_VERIFICATION Step 5a).

---

## Architecture Status

Completed milestones (carried from V5, plus Phase 2):

- ✅ **Multi-tenant model** — organization = tenant; all data scoped by `organization_id`.
- ✅ **JWT-claims tenancy** — org/role/property context via signed JWT claims (`custom_access_token_hook`).
- ✅ **RLS-enforced isolation** — every tenant table org-scoped via JWT helper functions.
- ✅ **RPC-first writes** — guest/reservation/**CRM-integration** writes go through `SECURITY DEFINER` RPCs; direct INSERT revoked.
- ✅ **Safe-view reads** — sensitive reads target `security_invoker` views excluding secret columns.
- ✅ **Server-authoritative loyalty** — loyalty/visit/spend owned by DB triggers.
- ✅ **CRM provider abstraction** — `crm_integrations` decouples provider specifics.
- ✅ **Event outbox** — `webhook_events` records every outbound automation event for N8N.
- ✅ **Centralized auth context (frontend)** — `AuthProvider` is the single source of JWT claims via `getClaims()`.
- ✅ **Vault-backed CRM secrets (V8)** — secrets in `vault.secrets`; `crm_integrations.credential_ref` holds only non-secret references; browser fully isolated.
- ✅ **Resolver pattern (V8)** — `resolve_crm_secret()` is the standard server-side secret-read path for automation.
- ✅ **NEW: CRM credential management UI (Phase 2)** — owner-only Connect / Rotate / Edit-metadata via `upsert_crm_integration()`; managers read-only; secrets never on a browser-readable/writable path.
- ✅ **NEW: Connection-test UI (Phase 2)** — owner-only, server-mediated; browser sends only the integration id; endpoint contract frozen.

---

## Backend Status (FROZEN — unchanged since V5)

### Completed migrations (apply in order)

| File | Purpose |
|---|---|
| `supabase/schema.sql` | v1 foundation: guests, reservations, loyalty, webhook_events; trigger; base views; grants |
| `supabase/migrate_v2_multi_tenant.sql` | organizations, users, user_roles, guest_org_profiles, loyalty_by_property; `organization_id` across tables |
| `supabase/seed_simulation.sql` | Demo orgs + data (superseded loyalty trigger by v6) |
| `supabase/migrate_v3_loyalty_lifecycle.sql` | Loyalty lifecycle: total_visits at booking; confirmed/spend/last_visit at checkout |
| `supabase/migrate_v4_auth_context.sql` | JWT helper functions; `custom_access_token_hook`; `user_accessible_orgs` |
| `supabase/migrate_v5_crm_integrations.sql` | `crm_integrations` + `crm_integrations_safe`; `crm_contact_ids` on guest_org_profiles |
| `supabase/migrate_v6_onboarding.sql` | loyalty_config; `calculate_tier(org_id)`; pms_integrations + safe view; invitations; onboarding_sessions; current `handle_new_reservation()` |
| `supabase/migrate_v8_crm_secure.sql` | **CRM Secure Credential Foundation: Vault-backed secrets; `credential_ref`/`auth_type`/audit/sync-health columns; `upsert_crm_integration()` owner-only RPC; `resolve_crm_secret()` resolver; base-table CRM writes revoked; `crm_integrations_safe` recreated. Additive. APPLIED & VERIFIED.** |

Supporting docs: `supabase/V8_DEPLOYMENT_VERIFICATION.md`.

### Security model (frozen)
- **RPC-only writes** for guests/reservations/CRM integrations; **safe-view-only reads** for PII/secrets.
- **CRM secrets** never traverse a browser-readable/writable path: REVOKE base-table write + Vault storage + safe-view exclusion + resolver-gated reads + type-level allow-lists.
- **Server-authoritative loyalty**; **column-protection triggers**; red-team RT-A1/A2/A3/B1/B2 + audit A-1..A-4/B-2 preserved; V8 closes H-1/H-2.

---

## Frontend Status

| Route | Page | Source | Mode |
|---|---|---|---|
| `/login` | LoginPage | Supabase Auth | auth |
| `/` | DashboardPage | `kpi_summary`, `guest_summary`, `reservation_detail` | read |
| `/guests` | GuestsPage | `guest_summary` | read |
| `/reservations` | ReservationsPage | `reservation_detail` | read |
| `/reservations/new` | NewReservationPage | `upsert_guest` + `create_reservation` RPCs | **write** |
| `/properties` | PropertiesPage | `properties` | read |
| `/team` | TeamPage | `users`+`user_roles`, `invitations` | read |
| `/onboarding` | OnboardingPage | derived | read |
| `/integrations` | IntegrationsPage | `crm_integrations_safe`, `pms_integrations_safe` + `upsert_crm_integration` + connection test | **read + owner write + test** |
| `/settings` | SettingsPage | `organizations`, integration counts, account | read |

- `IntegrationsPage` now surfaces all v8 non-secret fields; owners get Connect / Manage (rotate + edit-metadata) / Test; managers/staff remain read-only (RLS-driven).
- New file: `src/components/integrations/CrmIntegrationModal.tsx`.
- `Database` generic + `CrmIntegrationSafe` + `CrmCredentialRef` + `upsert_crm_integration` typing all in place and secret-free; `tsc -b` green.

---

# Current System Status

| Capability | Status |
|---|---|
| **Reservations** | ✅ Production-ready |
| **Guest Management** | ✅ Production-ready |
| **Team Management** | ✅ Production-ready |
| **CRM Credential Management** | ✅ Production-ready |
| **CRM Automation Engine** | ⛔ Not started |
| **Connection Test Backend** | ⛔ Not started |

---

# Next Approved Priority

## Phase 3 — CRM Automation Engine

Build the outbound automation layer that turns committed CRM credentials + the `webhook_events` outbox into real GoHighLevel synchronization, using the frozen v8 resolver pattern.

**Focus:**
- **`webhook_events` consumer** — drain `status='pending'` events (N8N-first), with retry / failure semantics.
- **`resolve_crm_secret` usage** — server-side (service_role) secret resolution; the `vault` schema stays unexposed.
- **GoHighLevel contact sync** — create/update contacts from the self-contained event payloads.
- **`crm_contact_ids` writeback** — record the provider→contact-id map on `guest_org_profiles` for fast-path returning guests.
- **Outbound event processing** — mark events `sent`/`failed`; populate `crm_integrations.last_error`/`last_error_at` and `last_sync_at` on the integration.
- **Automation observability** — surface drain health, failures, and latency.

**Adjacent (recommended alongside, per Increment E freeze):** implement the **`crm-test-connection` Edge Function** to the frozen contract above (closes V8's deferred positive resolver test on first success) and wire `VITE_CRM_TEST_ENDPOINT_URL` per environment.

---

## Deferred Items (intentional)

- **Disconnect / disable CRM integration** — no v8 disable or secret-clear path; needs a future additive `disconnect_crm_integration()` migration.
- **Positive resolver test** — closes on the first committed CRM integration's successful connection test / sync.
- **Restricted `crm_automation` role** — retire blanket `service_role` for N8N (least-privilege follow-up to V8).
- **Deprecated-column cleanup (future migration)** — drop `crm_integrations.credentials`, `organizations.ghl_location_id`/`make_webhook_secret`, `guest_org_profiles.ghl_contact_id` after N8N cutover verified.
- **Config editor for CRM integrations** — Phase 2 writes empty `config {}`; a non-secret config editor (n8n_inbound_url, pipeline_id, etc.) is deferred.
- **Multi-provider CRM UI** — HubSpot / Salesforce connect flows (Phase 2 is GoHighLevel-only).
- `claim_invitation()` RPC + Team management writes; **Org switching** + `OrgProvider`; **PMS ingestion**; inbound CRM→OS engagement sync; AI pricing/forecasting layer; full rpc typing fix (`args as never` removal).

---

## Resume State — what to do next

1. **Begin Phase 3 (CRM Automation Engine)** — N8N outbound `webhook_events` consumer through `resolve_crm_secret()` → GoHighLevel contact upsert → `crm_contact_ids` writeback → `sent`/`failed` + `last_error`/`last_error_at`/`last_sync_at` updates → observability.
2. **Implement the `crm-test-connection` Edge Function** to the frozen contract (Connection-Test Endpoint section); set `VITE_CRM_TEST_ENDPOINT_URL` per environment; the frontend Test button is already wired and waiting.
3. **Backend is frozen** — modify only via additive forward migrations. Reads via safe views; writes via RPC; never expose `auth_user_id`/`active_org_id`/`token`/`credentials`/Vault.
4. **When the first CRM integration is committed/tested**, run the **deferred positive resolver test** (V8_DEPLOYMENT_VERIFICATION Step 5a).
5. **Pre-flight before any DB work** — confirm deployed schema matches v7 + v8 and the v6 `handle_new_reservation()` body; confirm the JWT hook is still registered.
6. **Working agreement** — tightly-scoped increments, each ending with a full `tsc -b`, a file-by-file diff summary, and a stop for review.

---

## Pointers

- **CRM migration:** `supabase/migrate_v8_crm_secure.sql`
- **Verification guide:** `supabase/V8_DEPLOYMENT_VERIFICATION.md`
- **Phase 2 frontend:** `src/lib/types.ts`, `src/api/integrations.ts`, `src/pages/IntegrationsPage.tsx`, `src/components/integrations/CrmIntegrationModal.tsx`
- **Prior authoritative checkpoint (history):** `PROJECT_CHECKPOINT_V5.md` (now superseded)

*End of PROJECT_CHECKPOINT_V6.md — authoritative resume point. Supersedes V5.*
