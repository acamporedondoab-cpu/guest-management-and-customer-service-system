# PROJECT_CHECKPOINT_V5.md

**Project:** Campground OS — Multi-Tenant Guest Management & Revenue Intelligence Platform
**Checkpoint date:** 2026-06-15
**Supersedes:** PROJECT_CHECKPOINT_V4.md (architecture/security freeze + Phase 1 plan)
**Status of this document:** Authoritative continuation point. An engineer with zero prior context should be able to resume from this file alone.

---

## Executive Summary

Campground OS is a multi-tenant SaaS platform for campground / RV-park operators. It is **not** a reservation system — the PMS (Campspot, RezWorks, Hostfully, etc.) remains the reservation source of truth. Campground OS is the **guest intelligence + retention layer**: it ingests reservations, computes loyalty/visit/spend state server-side, and syncs that intelligence into a CRM (GoHighLevel-first) to drive automated guest communications.

**Stack:** React 18 + Vite + TypeScript + Tailwind + react-router-dom v7 + `@supabase/supabase-js` 2.108 + date-fns. Backend = Supabase (Postgres + Auth + RLS + **Vault**). Automation layer = **N8N-first**. CRM = **GoHighLevel-first** (provider-abstracted).

**What changed since V4:** **Phase 1 — CRM Secure Credential Foundation is COMPLETE.** The additive migration `migrate_v8_crm_secure.sql` was deployed and verified on the live project: CRM secrets now live in **Supabase Vault**, the browser has no readable or writable secret path, owners manage credentials through an owner-only `SECURITY DEFINER` RPC, and automation reads secrets server-side through a resolver function. Backend schema + security model remain **frozen** (modify only via additive forward migrations).

**Current status:** Backend migrations **v1→v8** on disk and applied. Frontend is functionally complete for read flows and the reservation write flow. **Next approved unit of work: Phase 2 — CRM Integrations UI & Workflow Layer.**

---

## Architecture Status

Completed milestones (carried from V4, plus V8):

- ✅ **Multi-tenant model** — organization = tenant; all data scoped by `organization_id`.
- ✅ **JWT-claims tenancy** — org/role/property context via signed JWT claims set by `custom_access_token_hook`.
- ✅ **RLS-enforced isolation** — every tenant table org-scoped via JWT helper functions.
- ✅ **RPC-first writes** — guest/reservation/**CRM-integration** writes go through `SECURITY DEFINER` RPCs; direct INSERT revoked.
- ✅ **Safe-view reads** — all sensitive reads target `security_invoker` views excluding secret columns.
- ✅ **Server-authoritative loyalty** — loyalty/visit/spend owned by DB triggers.
- ✅ **CRM provider abstraction** — `crm_integrations` decouples provider specifics.
- ✅ **Event outbox** — `webhook_events` records every outbound automation event for N8N.
- ✅ **Centralized auth context (frontend)** — `AuthProvider` is the single source of JWT claims via `getClaims()`.
- ✅ **NEW (V8): Vault-backed CRM secrets** — secrets in `vault.secrets`; `crm_integrations.credential_ref` holds only non-secret references; browser fully isolated from secrets.
- ✅ **NEW (V8): Resolver pattern** — `resolve_crm_secret()` is the standard server-side secret-read path for automation (even though service_role could read Vault directly).

---

## Backend Status

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
| `supabase/migrate_v7_tenant_rls.sql` | The security flip: real tenant RLS; column-locked grants; SECURITY DEFINER triggers; `upsert_guest()` / `create_reservation()` RPCs |
| **`supabase/migrate_v8_crm_secure.sql`** | **CRM Secure Credential Foundation: Vault-backed secrets; `credential_ref`/`auth_type`/audit/sync-health columns; `upsert_crm_integration()` owner-only RPC; `resolve_crm_secret()` resolver; base-table CRM writes revoked; `crm_integrations_safe` recreated (DROP+CREATE). Additive. APPLIED & VERIFIED.** |

Supporting docs: `supabase/V8_DEPLOYMENT_VERIFICATION.md` (8-step execution guide).

### V8 schema deltas (crm_integrations)

- **New columns:** `auth_type` (`api_key`|`private_token`|`oauth2`|`none`), `credential_ref JSONB` (non-secret Vault pointer + masked metadata: `vault_secret_id`, `token_type`, `last4`, `expires_at`), `connected_at`, `connected_by` (→ users.id), `last_error`, `last_error_at`, `sync_cursor JSONB`.
- **Deprecated, RETAINED:** `credentials JSONB` — no longer a write target; kept as a dual-read fallback for N8N until a future cleanup migration drops it.
- **`crm_integrations_safe`** recreated with the new non-secret fields; still **excludes `credentials`**; `security_invoker = true`.

### V8 RPC / function architecture

- **`upsert_crm_integration(p_provider, p_name, p_external_account_id, p_auth_type, p_config, p_secret, p_expires_at) → jsonb`** — only authenticated CRM-secret write path. `SECURITY DEFINER`, `search_path=public`, **owner-only** (JWT-derived org/role/user). Write-only secret → Vault (`vault.create_secret`, default key); rotation via `vault.update_secret`; rejects secrets smuggled in `config`; returns **safe fields only** (id, provider, status, `last4`, connected_at) — never plaintext. EXECUTE granted to authenticated + service_role; revoked from PUBLIC/anon.
- **`resolve_crm_secret(p_integration_id) → text`** — server-side resolver. `SECURITY DEFINER` (owner postgres) reads `vault.decrypted_secrets`. EXECUTE granted to **service_role only** (not authenticated/anon). N8N calls it over `rpc/`; the `vault` schema is never REST-exposed.
- **Grant change:** `INSERT, UPDATE, DELETE ON crm_integrations` revoked from `authenticated` (closes the v5/v7 base-table credential-write path; the RPC is now the sole write path). v7 column-level SELECT extended to the new non-secret columns; `credentials` stays ungranted.

### Verified Vault facts (live project)

- supabase_vault version = **0.3.1**.
- `create_secret(new_secret text, new_name text, new_description text, new_key_id uuid) → uuid`.
- `update_secret(secret_id uuid, new_secret text, new_name text, new_description text, new_key_id uuid) → void`.
- **service_role:** schema_usage / secrets_select / decrypted_select = **true**.
- **authenticated / anon:** **no** Vault access.
- v8 uses the **default encryption key** (`new_key_id => NULL`) and never manages `key_id`.

### Security model (frozen)

- **RPC-only writes** for guests/reservations/CRM integrations; **safe-view-only reads** for PII/secrets.
- **CRM secrets** never traverse a browser-readable/writable path: REVOKE base-table write + Vault storage + safe-view exclusion + resolver-gated reads + type-level allow-lists.
- **Server-authoritative loyalty**; **column-protection triggers** (`auth_user_id` immutable; org plan/status/slug service-role only; last-owner lockout guard).
- Red-team resolutions RT-A1/A2/A3/B1/B2 (V3) and audit findings A-1..A-4/B-2 (V7) preserved; V8 closes the credential-foundation gaps (H-1 base-table write, H-2 plaintext at rest).

---

## V8 CRM Secure Credential Foundation — DEPLOYED & VERIFIED

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

## Frontend Status

Unchanged from V4 — V8 was a backend/security migration with **no frontend changes**.

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
| `/integrations` | IntegrationsPage | `crm_integrations_safe`, `pms_integrations_safe` | **read-only (Phase 2 upgrades this)** |
| `/settings` | SettingsPage | `organizations`, integration counts, account | read |

- `IntegrationsPage` still reads `crm_integrations_safe` via `src/api/integrations.ts` and is read-only. The new v8 non-secret fields are now available in the view but **not yet typed or surfaced** — that is Phase 2 work.
- The `Database` generic (`src/lib/types.ts`) does **not** yet declare `upsert_crm_integration` or the new `crm_integrations_safe` columns. Phase 2 must add them (keeping the type allow-list secret-free).
- Centralized JWT claims via `AuthProvider` (`role`/`orgId`/`propertyId`/`isOrgWide`).

---

## Next Approved Priority — Phase 2: CRM Integrations UI & Workflow Layer

**Goal:** give owners a safe, real connect/manage experience on the Integrations page, built entirely on the V8 architecture.

- **Integrations page migration to V8 architecture** — surface `auth_type`, connection status, `last_error`/health, and **`credential_ref` metadata only** (masked `last4`, `token_type`, `expires_at`); never any secret.
- **Replace plaintext credential handling** — no direct base-table writes; the page writes exclusively through `upsert_crm_integration()`.
- **Owner-only credential management UI** — connect / rotate / disconnect for owners; managers read-only (matches the frozen matrix and the RPC's owner gate).
- **Connection testing workflow** — validate a credential after save (server-side / N8N-mediated; never resolve secrets in the browser).
- **Future N8N consumption through the resolver pattern** — outbound consumer drains `webhook_events` → `resolve_crm_secret()` → GoHighLevel contact upsert → `crm_contact_ids` writeback → `status='error'` + `last_error/_at` on failure.

**Frontend pre-work:** extend the `Database` generic with `upsert_crm_integration` (Args/Returns) and the new safe-view fields; `tsc -b` must stay green and secret-free.

---

## Deferred Items (intentional)

- **Positive resolver test** — deferred until a committed CRM integration exists (Phase 2 connect flow creates one). Security path already verified; not a blocker.
- **Restricted `crm_automation` role** — retire blanket `service_role` for N8N (least-privilege follow-up to V8).
- **Deprecated-column cleanup (future migration)** — drop `crm_integrations.credentials`, `organizations.ghl_location_id`/`make_webhook_secret`, `guest_org_profiles.ghl_contact_id` after N8N cutover verified.
- `claim_invitation()` RPC — functional invite acceptance still blocked; Team invites display-only.
- Team management **writes** — invite creation, role editing, revocation (RLS-ready; no UI/RPC).
- **Org switching** + `OrgProvider` — claims read inline; `active_org_id` switching + `refreshSession()` deferred.
- **PMS ingestion** — inbound PMS→Campground OS sync via N8N (PMS stays source of truth).
- **Inbound CRM→OS** engagement sync (loop-guarded); AI pricing/forecasting layer.
- **Full rpc typing fix** — migrate Database Row interfaces to type aliases to remove `args as never`.

---

## Resume State — what to do next

1. **Begin Phase 2 (CRM Integrations UI & Workflow Layer)** — start with the frontend type extension (Database generic + `CrmIntegrationSafe` v8 fields + `upsert_crm_integration` typing), then the owner connect/rotate/disconnect UI on the Integrations page (managers read-only), then connection testing, then the N8N outbound consumer via `resolve_crm_secret()`.
2. **Backend is frozen** — modify only via additive forward migrations. Reads via safe views; writes via RPC; never expose `auth_user_id`/`active_org_id`/`token`/`credentials`/Vault.
3. **When the first CRM integration is committed**, run the **deferred positive resolver test** (V8_DEPLOYMENT_VERIFICATION.md Step 5a) to close the one remaining deferred validation.
4. **Pre-flight before any DB work** — confirm deployed schema matches v7 + v8 and the v6 `handle_new_reservation()` body; confirm the JWT hook is still registered.
5. **Working agreement** — tightly-scoped increments, each ending with a full `tsc -b`, a file-by-file diff summary, and a stop for review.

---

## Pointers

- **Migration:** `supabase/migrate_v8_crm_secure.sql`
- **Verification guide:** `supabase/V8_DEPLOYMENT_VERIFICATION.md`
- **Prior authoritative checkpoint (history):** `PROJECT_CHECKPOINT_V4.md` (now superseded)

*End of PROJECT_CHECKPOINT_V5.md*
