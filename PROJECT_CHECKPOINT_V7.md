# PROJECT_CHECKPOINT_V7.md

**Project:** Campground OS — Multi-Tenant Guest Management & Revenue Intelligence Platform
**Checkpoint date:** 2026-06-15
**Supersedes:** PROJECT_CHECKPOINT_V6.md (Phase 2 — CRM Integrations UI & Workflow Layer complete; Phase 3 planned)
**Status of this document:** Authoritative continuation point. An engineer with zero prior context should be able to resume from this file alone.

---

## Executive Summary

Campground OS is a multi-tenant SaaS platform for campground / RV-park operators. It is **not** a reservation system — the PMS (Campspot, RezWorks, Hostfully, etc.) remains the reservation source of truth. Campground OS is the **guest intelligence + retention layer**: it ingests reservations, computes loyalty/visit/spend state server-side, and syncs that intelligence into a CRM (GoHighLevel-first) to drive automated guest communications.

**Stack:** React 18 + Vite + TypeScript + Tailwind + react-router-dom v7 + `@supabase/supabase-js` 2.108 + date-fns. Backend = Supabase (Postgres + Auth + RLS + **Vault**). Automation layer = **N8N-first (orchestration only)** + **Supabase Edge Functions (secret-bearing work)**. CRM = **GoHighLevel-first** (provider-abstracted).

**What changed since V6:** **Phase 3 — CRM Automation Engine has begun, and its database layer (P1 / WU-1) is COMPLETE, DEPLOYED & VERIFIED.** Migration `migrate_v9_crm_automation.sql` is applied: `webhook_events` now has a claim/retry lifecycle, two least-privilege automation roles (`crm_automation`, `crm_resolver`) split the trust boundary, and four SECURITY DEFINER RPCs (`claim_webhook_events`, `complete_webhook_event`, `requeue_webhook_event`, `get_crm_dispatch_context`) form the server side of the outbound drain. The full Phase 3 architecture, blueprint, adversarial review, implementation spec, and a self-audit (with fixes F6/F16) were completed and approved before deployment. Backend schema + security model remain otherwise **frozen** (modify only via additive forward migrations).

**Current status:** Backend migrations **v1→v9** on disk and applied. Frontend is functionally complete for read flows, the reservation write flow, and CRM credential management + connection-test UI. The remaining Phase 3 pieces are **out-of-repo infrastructure** (not yet built): the `crm-sync-dispatch` Edge Function, the `crm-test-connection` Edge Function, and the N8N outbound drain workflow. **Next approved unit of work: P2 — `crm-sync-dispatch` Edge Function.**

---

## V9 CRM Automation Foundation — DEPLOYED & VERIFIED (2026-06-15)

**Migration:** `supabase/migrate_v9_crm_automation.sql` — applied as `postgres`, committed, additive only, single transaction. PostgREST schema reload completed. No rollback executed.

### Pre-flight — PASS
- `public.resolve_crm_secret(uuid)` present (v8) · `vault.decrypted_secrets` present · `public.crm_integrations` present · role creation available (`CREATEROLE`) · applied as `postgres`.

### Migration — PASS
- Migration committed successfully · PostgREST schema reload (`NOTIFY pgrst, 'reload schema'`) completed.

### Gate 0 — Security Boundary (B3) — PASS
The EXECUTE grant is the **entire** security boundary for the drain RPCs (they derive org from the event row, not the JWT). Verified in the production database:
- `anon` cannot execute `claim_webhook_events`, `complete_webhook_event`, `requeue_webhook_event`, `get_crm_dispatch_context`, or `resolve_crm_secret`.
- `authenticated` cannot execute any automation RPC, nor `resolve_crm_secret`.
- **Role separation verified:**
  - `crm_automation`: `claim_webhook_events`=true, `complete_webhook_event`=true, `requeue_webhook_event`=true, `get_crm_dispatch_context`=**false**, `resolve_crm_secret`=**false**.
  - `crm_resolver`: `claim_webhook_events`=false, `complete_webhook_event`=false, `requeue_webhook_event`=false, `get_crm_dispatch_context`=true, `resolve_crm_secret`=true.
- **Security outcome:** B3 security boundary verified in production. N8N (`crm_automation`) can never resolve a secret; the Edge Function identity (`crm_resolver`) can never drain/complete events.

### Gate 1 — Schema Verification — PASS
- `webhook_events` new columns present: `next_attempt_at`, `locked_at`, `provider_contact_id`, `error_class`.
- `webhook_events_status_check` widened to: `pending | processing | sent | failed | skipped`.
- `idx_webhook_events_claimable` exists (partial index on the claim hot path).
- Roles verified: `crm_automation` (NOLOGIN, no BYPASSRLS) · `crm_resolver` (NOLOGIN, no BYPASSRLS).

### Gate 2 — Operational Verification — PASS
- `authenticator` can assume `crm_automation` and `crm_resolver` (membership confirmed).
- `SET LOCAL ROLE crm_automation` works · `claim_webhook_events` executable under `crm_automation`.

---

## Phase 3 Design Trail (approved, in order)

The database layer was built only after a full, individually-approved design sequence — the architecture is the deliverable:

1. **Phase 3A — Architecture Audit:** current outbox state, recommended N8N topology, idempotency/retry/failure strategy, security & observability, file-by-file roadmap.
2. **Phase 3B — Implementation Blueprint:** exact v9 scope, RPC contracts, Edge Function contract, N8N contract, GHL upsert flow, writeback flow, event-type matrix, retry/backoff, runbook, verification gates.
3. **Phase 3C — Implementation Readiness Review (adversarial):** locked blockers **B1–B6**; adopted recommendations **R1–R9**; conditional GO.
4. **Implementation Package:** WU breakdown, dependency/deploy/verify/rollback order, risk matrix, phasing.
5. **P1 / WU-1 — `migrate_v9` authored**, then **self-audited** (findings F1–F16). Two fixes applied before deploy:
   - **F6 (cross-tenant):** `complete_webhook_event` now validates that `p_integration_id` belongs to the locked event's organization **before any integration-health write**; mismatch raises `42501` and touches no `crm_integrations` row.
   - **F16 (rollback):** rollback block corrected so `DROP ROLE` succeeds — explicit `REVOKE EXECUTE ON resolve_crm_secret FROM crm_resolver` + `REVOKE USAGE ON SCHEMA public` before dropping the roles.

### Locked Phase 3 decisions (durable)
- **N8N orchestrates only**; it never holds a secret, a table grant, or BYPASSRLS.
- **Edge Function performs all secret-bearing GHL work** under the `crm_resolver` identity.
- **`resolve_crm_secret` stays server-only**; `crm_resolver` (not `service_role`) is the Edge identity — **`service_role` fallback rejected**.
- **`private_token` only** this phase; `api_key` and `oauth2` deferred (Edge returns `failed/validation`).
- **Retry/backoff:** exponential `LEAST(30·2^retry_count, 900s)` + 0–5s jitter; provider `Retry-After` overrides and is **not** capped (R8); dead-letter at `p_max_attempts=5`; 5-min stale-`processing` reaper.
- **B6:** an event is auto-skipped only when the org has **no** gohighlevel integration row at all (existence, not status) — an integration in `error` keeps its events claimable so they resume after a credential fix.

---

## Backend Status (FROZEN except additive forward migrations)

### Completed migrations (apply in order)

| File | Purpose |
|---|---|
| `supabase/schema.sql` | v1 foundation: guests, reservations, loyalty, webhook_events; trigger; base views; grants |
| `supabase/migrate_v2_multi_tenant.sql` | organizations, users, user_roles, guest_org_profiles, loyalty_by_property; `organization_id`; webhook_events gains org/property/retry_count/last_error/processed_at |
| `supabase/seed_simulation.sql` | Demo orgs + data |
| `supabase/migrate_v3_loyalty_lifecycle.sql` | Loyalty lifecycle: total_visits at booking; confirmed/spend/last_visit at checkout |
| `supabase/migrate_v4_auth_context.sql` | JWT helper functions; `custom_access_token_hook`; `user_accessible_orgs` |
| `supabase/migrate_v5_crm_integrations.sql` | `crm_integrations` + `crm_integrations_safe`; `crm_contact_ids` on guest_org_profiles |
| `supabase/migrate_v6_onboarding.sql` | loyalty_config; `calculate_tier(org_id)`; pms_integrations + safe view; invitations; onboarding_sessions; current `handle_new_reservation()` / `handle_reservation_status_change()` |
| `supabase/migrate_v7_tenant_rls.sql` | Real tenant RLS; column-level grants; SECURITY DEFINER loyalty triggers; function EXECUTE lockdown |
| `supabase/migrate_v8_crm_secure.sql` | **CRM Secure Credential Foundation: Vault-backed secrets; `credential_ref`/`auth_type`/audit/sync-health columns; `upsert_crm_integration()` owner-only RPC; `resolve_crm_secret()` resolver; base-table CRM writes revoked. APPLIED & VERIFIED.** |
| `supabase/migrate_v9_crm_automation.sql` | **CRM Automation Foundation: webhook_events claim/retry lifecycle (processing/skipped + next_attempt_at/locked_at/provider_contact_id/error_class + claim index); `crm_automation` + `crm_resolver` roles; `claim_webhook_events` / `complete_webhook_event` (folds crm_contact_ids writeback + integration health, F6 tenant-validated) / `requeue_webhook_event` / `get_crm_dispatch_context`; `resolve_crm_secret` EXECUTE extended to `crm_resolver`. Additive. APPLIED & VERIFIED (Gates 0–2 PASS).** |

Supporting docs: `supabase/V8_DEPLOYMENT_VERIFICATION.md`.

### Security model (frozen)
- **RPC-only writes** for guests/reservations/CRM integrations + automation drain; **safe-view-only reads** for PII/secrets.
- **CRM secrets** never traverse a browser-readable/writable path (REVOKE base-table write + Vault storage + safe-view exclusion + resolver-gated reads + type-level allow-lists).
- **Automation trust split (V9):** `crm_automation` (N8N) = EXECUTE claim/complete/requeue only; `crm_resolver` (Edge) = EXECUTE resolve/context only. Neither has table access or BYPASSRLS. The drain RPCs derive org from the event row, not the JWT — so the EXECUTE grant is their security boundary (B3, verified in prod).
- **Server-authoritative loyalty**; column-protection triggers; red-team RT/audit posture preserved; V8 closes H-1/H-2.

---

## Frontend Status (unchanged since V6)

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

- A minor sync-health surface on IntegrationsPage/dashboard (`last_sync_at`/`last_error`, already exposed by the safe view) is deferred to **P4** — no frontend change shipped in P1.

---

# Current System Status

| Capability | Status |
|---|---|
| **Reservations** | ✅ Deployed & verified |
| **Guest Management** | ✅ Deployed & verified |
| **Properties** | ✅ Deployed & verified |
| **Team Management** | ✅ Deployed & verified |
| **Onboarding** | ✅ Deployed & verified |
| **CRM Credential Management** | ✅ Deployed & verified (V8) |
| **CRM Queue / Automation Foundation (DB layer)** | ✅ Deployed & verified (V9) |
| **crm-sync-dispatch Edge Function** | ⛔ Not started (P2) |
| **crm-test-connection Edge Function** | ⛔ Not started |
| **N8N outbound drain workflow** | ⛔ Not started |

**Architecture milestones:**
- ✅ V8 CRM Secure Credential Foundation — COMPLETE / DEPLOYED / VERIFIED.
- ✅ V9 CRM Automation Foundation — COMPLETE / DEPLOYED / VERIFIED.

---

# Next Approved Priority

## P2 — `crm-sync-dispatch` Edge Function

Build the secret-bearing GHL worker that the (later) N8N drain invokes per claimed event.

**Objectives:**
- Authenticate to the DB as the **`crm_resolver`** identity (never `service_role`).
- Call **`get_crm_dispatch_context`** to derive provider/account/auth_type/tags from the DB (never trust body-supplied routing — B5).
- Call **`resolve_crm_secret`** server-side; secret stays in function memory, never logged, never returned.
- Perform **GoHighLevel contact sync** (`private_token` only; upsert-by-email / fast-path by stored contact id) against a hardcoded GHL base host.
- Return a masked outcome so N8N can call **`complete_webhook_event`** (which folds `crm_contact_ids` writeback + integration health, tenant-validated per F6).
- **Close the deferred V8 positive resolver validation** (V8_DEPLOYMENT_VERIFICATION Step 5a) on the first successful real resolve/sync.

**Build constraints (locked):** `private_token` only; constant-time token compare; no secret/header/payload logging; supabase-js with `apikey: ANON_KEY` + `Authorization: Bearer ${CRM_RESOLVER_KEY}`. Mirror the `private_token`-only restriction in `crm-test-connection`.

---

## Phase 3 Status

- **Planning:** COMPLETE (3A audit → 3B blueprint → 3C readiness review → implementation package).
- **Database Layer (P1 / WU-1):** COMPLETE / DEPLOYED / VERIFIED.
- **P2 (`crm-sync-dispatch`):** next, not started.
- **P3 (N8N drain workflow), P4 (frontend sync-health), P5 (checkpoint/memory close):** pending.

---

## Deferred Items (intentional)

- **`crm-test-connection` Edge Function** — implement to the frozen V6 contract alongside/after P2; mirror `private_token`-only; closes V8 Step 5a.
- **Disconnect / disable CRM integration** — no v8/v9 disable or secret-clear path; needs a future additive `disconnect_crm_integration()` migration.
- **Deprecated-column cleanup (future migration)** — drop `crm_integrations.credentials`, `organizations.ghl_location_id`/`make_webhook_secret`, `guest_org_profiles.ghl_contact_id` after N8N cutover verified.
- **Config editor for CRM integrations** — Phase 2 writes empty `config {}`; with empty `field_mappings`/`tag_prefix`, dispatch syncs standard fields + tags only until a non-secret config editor ships.
- **Multi-provider CRM UI** (HubSpot / Salesforce) and **`api_key`/`oauth2` GHL auth** — deferred.
- **Optional hardening:** orphaned-`processing` recovery for the narrow integration-deleted-mid-flight case (audit F1; manual SQL today); `claim_invitation()`; Org switching + `OrgProvider`; PMS ingestion; inbound CRM→OS engagement sync; AI pricing/forecasting; full rpc typing fix (`args as never` removal).

---

## Resume State — what to do next

1. **Begin P2 — `crm-sync-dispatch` Edge Function** to the objectives above (frozen Phase 3 spec is authoritative for contracts).
2. **Backend is frozen** — modify only via additive forward migrations. Reads via safe views; writes via RPC; never expose `auth_user_id`/`active_org_id`/`token`/`credentials`/Vault.
3. **On first successful resolve/sync**, run the **deferred V8 positive resolver test** (V8_DEPLOYMENT_VERIFICATION Step 5a).
4. **Pre-flight before any DB work** — confirm deployed schema matches v7 + v8 + v9 and the v6 trigger bodies; confirm the JWT hook is still registered.
5. **Working agreement** — tightly-scoped increments, each ending with a file-by-file diff summary and a stop for review.

---

## Pointers

- **Automation migration:** `supabase/migrate_v9_crm_automation.sql` (Gates 0–2 are in its commented verification block; rollback block is F16-corrected).
- **CRM secure migration:** `supabase/migrate_v8_crm_secure.sql` · **Verification:** `supabase/V8_DEPLOYMENT_VERIFICATION.md`.
- **Phase 2 frontend:** `src/lib/types.ts`, `src/api/integrations.ts`, `src/pages/IntegrationsPage.tsx`, `src/components/integrations/CrmIntegrationModal.tsx`.
- **Prior authoritative checkpoint (history):** `PROJECT_CHECKPOINT_V6.md` (now superseded).

*End of PROJECT_CHECKPOINT_V7.md — authoritative resume point. Supersedes V6.*
