# PROJECT_CHECKPOINT_V8.md

**Project:** Campground OS — Multi-Tenant Guest Management & Revenue Intelligence Platform
**Checkpoint date:** 2026-06-16
**Supersedes:** PROJECT_CHECKPOINT_V7.md (Phase 3 started; V9 CRM Automation Foundation deployed)
**Status of this document:** Authoritative continuation point. An engineer with zero prior context should be able to resume from this file alone.

> Naming note: this is **checkpoint V8** (document sequence). It is distinct from **migration v8** (`migrate_v8_crm_secure.sql`). The backend is now at **migration v10**. Checkpoint number ≠ migration number.

---

## Executive Summary

Campground OS is a multi-tenant SaaS platform for campground / RV-park operators. It is **not** a reservation system — the PMS remains the reservation source of truth. Campground OS is the **guest intelligence + retention layer**: it ingests reservations, computes loyalty/visit/spend state server-side, and syncs that intelligence into a CRM (GoHighLevel-first) to drive automated guest communications.

**Stack:** React 18 + Vite + TypeScript + Tailwind + react-router-dom v7 + `@supabase/supabase-js` 2.108 + date-fns. Backend = Supabase (Postgres + Auth + RLS + **Vault**). Automation layer = **N8N (orchestration only)** + **Supabase Edge Functions (secret-bearing work)**. CRM = **GoHighLevel-first** (provider-abstracted).

**What changed since V7:** the Phase 3 **database layer is now COMPLETE**. Migration **v10 (`migrate_v10_get_dispatch_event.sql`)** is deployed and verified, adding `get_dispatch_event(uuid)` — the RPC that closes the approved P2 security blocker **B-1** by making dispatch **DB-authoritative**: the `crm-sync-dispatch` Edge Function will receive only an `event_id` and derive the payload, integration, and routing context from the database, never trusting caller-supplied values. With v10 in place, **all database prerequisites for `crm-sync-dispatch` are complete.**

**Current status:** Backend migrations **v1→v10** on disk and applied. Frontend unchanged since V6. The remaining Phase 3 pieces are out-of-repo infrastructure (not yet built): the `crm-sync-dispatch` Edge Function, the `crm-test-connection` Edge Function, and the N8N outbound drain workflow. **Next approved unit of work: P2 — `crm-sync-dispatch` Edge Function.**

---

## V10 Dispatch Event Foundation — DEPLOYED & VERIFIED (deployed 2026-06-15)

**Migration:** `supabase/migrate_v10_get_dispatch_event.sql` — applied as `postgres`, committed, additive (one function + one grant), single transaction. PostgREST schema reload completed. No rollback executed.

**Summary:** introduced `public.get_dispatch_event(uuid)`, a SECURITY DEFINER RPC that lets the `crm_resolver` role derive **payload, integration_id, event_type, status, and non-secret routing context** directly from the database by `event_id`.

**Purpose:** eliminate trust in caller-supplied `integration_id`, `payload`, and `event_type` — closing the approved P2 security blocker **B-1** and establishing a **DB-authoritative dispatch model**.

### Architecture outcome
- **Before:** N8N supplied `integration_id` and `payload` to the Edge Function (caller-trusted; B-1 vulnerability — a leaked dispatch token could pair a victim `integration_id` with crafted payload to use that tenant's CRM secret).
- **After:** the Edge receives **`event_id` only**; all routing, payload, and integration data are derived from the DB via `get_dispatch_event`, and the Edge proceeds only when `status='processing'`.

### Verified security properties
- N8N cannot derive payload · N8N cannot derive integration · N8N cannot resolve secrets.
- Edge derives all dispatch context from the DB · Edge resolves secrets server-side only.

### Deployment verification results
- **Pre-flight — PASS:** `webhook_events` present · `crm_integrations` present · `crm_resolver` role present · `crm_automation` role present · applying as `postgres` · v10 not previously applied.
- **Migration — PASS** (committed). **PostgREST reload — PASS.**
- **Gate 0 — Grant Boundary — PASS:** `crm_resolver` EXECUTE = true; `crm_automation` = false; `authenticated` = false; `anon` = false.
- **Gate 1 — Function Verification — PASS:** `get_dispatch_event` exists; SECURITY DEFINER = true; return type = `jsonb`; `search_path = public`.
- **Gate 2 — Runtime Verification — PASS:** unknown event → `{"found": false}`; `crm_resolver` can execute; `crm_automation` → permission denied.

### Security hardening included (audit fixes, applied pre-deploy)
- **R1 — removed the `SELECT *` pattern.** The function loads only the required **non-secret** `crm_integrations` fields (`id, provider, external_account_id, auth_type, status, config`). `credentials` never loaded · `credential_ref` never loaded · `vault_secret_id` never loaded — they cannot enter function scope.
- **R3 — verification package includes secret-exclusion assertions** that the output contains no `credentials`, `credential_ref`, or `vault_secret_id` keys (top level and inside `context`).

---

## Phase 3 Design + Build Trail (approved, in order)

1. **3A** Architecture Audit → **3B** Implementation Blueprint → **3C** Readiness Review (locked **B1–B6**, adopted **R1–R9**).
2. **Implementation Package** (WU breakdown, dependency/deploy/verify/rollback order, risk matrix, phasing).
3. **P1 / WU-1 — `migrate_v9_crm_automation.sql`** authored → self-audited (F1–F16) → fixes **F6** (cross-tenant integration write closed) + **F16** (rollback `DROP ROLE` corrected) → **DEPLOYED & VERIFIED** (Gates 0–2, V7 checkpoint).
4. **P2 blueprint** for `crm-sync-dispatch` → adversarial review found **B-1** (Edge trusted caller-supplied `integration_id`/`payload`) → blueprint revised: new `get_dispatch_event(event_id)`, request shrinks to `{event_id}`, staged GHL classification (stale contact-id non-fatal), N8N passes `p_integration_id=NULL` on `no_provider`/`no_secret`, `CRM_RESOLVER_KEY` bounded-expiry rotation.
5. **WU-2 — `migrate_v10_get_dispatch_event.sql`** authored → audited (R1/R3) → hardened → **DEPLOYED & VERIFIED** (this checkpoint).

### Locked Phase 3 decisions (durable)
- N8N orchestrates only (no secret/table grant/BYPASSRLS); Edge does all secret-bearing GHL work under `crm_resolver`; `service_role` fallback **rejected**.
- **`private_token` only** this phase (`api_key`/`oauth2` deferred → Edge `failed/validation`).
- **DB-authoritative dispatch (B-1 fix):** Edge request = `{event_id}`; `get_dispatch_event` derives integration/payload/context/status; Edge gates on `status='processing'`.
- GHL base host hardcoded (never from input); staged upsert (fast-path failures non-terminal); retry/backoff `LEAST(30·2^n,900s)`+jitter, `Retry-After` overrides uncapped; dead-letter at `p_max_attempts=5`.

---

## Backend Status (FROZEN except additive forward migrations)

### Completed migrations (apply in order)

| File | Purpose |
|---|---|
| `supabase/schema.sql` | v1 foundation |
| `supabase/migrate_v2_multi_tenant.sql` | organizations/users/roles; org scoping; webhook_events org/property/retry columns |
| `supabase/seed_simulation.sql` | demo data |
| `supabase/migrate_v3_loyalty_lifecycle.sql` | loyalty lifecycle |
| `supabase/migrate_v4_auth_context.sql` | JWT hook + helpers |
| `supabase/migrate_v5_crm_integrations.sql` | `crm_integrations` + safe view; `crm_contact_ids` |
| `supabase/migrate_v6_onboarding.sql` | loyalty_config; `calculate_tier(org)`; pms_integrations; invitations; onboarding; current trigger bodies |
| `supabase/migrate_v7_tenant_rls.sql` | tenant RLS; column grants; SECURITY DEFINER loyalty triggers; function lockdown |
| `supabase/migrate_v8_crm_secure.sql` | **CRM Secure Credential Foundation: Vault secrets; `upsert_crm_integration()`; `resolve_crm_secret()`. APPLIED & VERIFIED.** |
| `supabase/migrate_v9_crm_automation.sql` | **CRM Automation Foundation: webhook_events claim/retry lifecycle; `crm_automation`/`crm_resolver` roles; `claim_webhook_events`/`complete_webhook_event`(F6)/`requeue_webhook_event`/`get_crm_dispatch_context`. APPLIED & VERIFIED.** |
| `supabase/migrate_v10_get_dispatch_event.sql` | **Dispatch Event Foundation: `get_dispatch_event(uuid)` — DB-authoritative dispatch context for the Edge (closes B-1). crm_resolver EXECUTE only; R1/R3 hardened. Additive. APPLIED & VERIFIED (Gates 0–2 PASS).** |

### CRM automation database layer — COMPLETE
Verified server-side components: `resolve_crm_secret` (v8) · `get_crm_dispatch_context` (v9) · `get_dispatch_event` (v10) · `claim_webhook_events` (v9) · `complete_webhook_event` (v9, F6) · `requeue_webhook_event` (v9). **All DB prerequisites for `crm-sync-dispatch` are now complete.**

### Security model (frozen)
- RPC-only writes; safe-view-only reads; CRM secrets never browser-reachable.
- **Automation trust split:** `crm_automation` (N8N) = EXECUTE claim/complete/requeue only; `crm_resolver` (Edge) = EXECUTE resolve/context/**dispatch-event** only. Neither has table access or BYPASSRLS. Drain + dispatch RPCs derive org from the **event row, not the JWT** — the EXECUTE grant is the boundary (B3/B-1, verified in prod).

---

## Frontend Status (unchanged since V6)

10 routes; read flows + reservation write + CRM credential management/connection-test UI complete. A sync-health surface (`last_sync_at`/`last_error`) is deferred to P4. No frontend change in P1/P2-DB work.

---

# Current System Status

| Capability | Status |
|---|---|
| Reservations / Guests / Properties / Team / Onboarding | ✅ Deployed & verified |
| CRM Credential Management (V8 / migration v8) | ✅ Deployed & verified |
| CRM Automation Foundation (migration v9) | ✅ Deployed & verified |
| CRM Dispatch Event Foundation (migration v10) | ✅ Deployed & verified |
| **CRM automation DATABASE layer** | ✅ **COMPLETE** |
| `crm-sync-dispatch` Edge Function | ⛔ Not started (P2 — next) |
| `crm-test-connection` Edge Function | ⛔ Not started |
| N8N outbound drain workflow | ⛔ Not started |
| Frontend sync-health surface | ⛔ Deferred (P4) |

**Deferred V8 positive resolver validation:** STILL OPEN — closes on the first successful real `crm-sync-dispatch` execution (V8_DEPLOYMENT_VERIFICATION Step 5a).

---

# Next Approved Priority

## P2 — `crm-sync-dispatch` Edge Function

**Objectives:**
- Authenticate to the DB as **`crm_resolver`** (never `service_role`).
- Call **`get_dispatch_event(event_id)`** to derive `status`/`event_type`/`integration_id`/`context`/`payload`; proceed only if `status='processing'` (else `ignored`).
- Call **`resolve_crm_secret(integration_id)`** server-side (secret stays in memory; never logged/returned).
- Perform **GoHighLevel contact sync** (`private_token` only; hardcoded host; staged fast-path/upsert).
- **Classify outcomes** and **return masked results** (`outcome`, `integration_id`, `contact_id`, `error_class`, `retry_after_seconds`, `provider_status`, `message`).
- Integrate with **`complete_webhook_event`** via N8N (N8N forwards the Edge's `integration_id`, which is `null` for `no_provider`/`no_secret` → F6-safe; skips `complete` on `ignored`).
- **Close the deferred V8 positive resolver validation** on first success.

> Flow note (B-1 fix): `get_dispatch_event` **folds** the non-secret routing context, so the Edge derives context from it directly. `get_crm_dispatch_context` (v9) is **retained for `crm-test-connection`** (event-less, owner-JWT-gated, takes `integration_id`), and `crm-test-connection` mirrors the `private_token`-only restriction.

**Build constraints (locked):** request body = `{event_id}` only; constant-time `EDGE_DISPATCH_TOKEN` compare; no secret/header/payload logging; supabase-js with `apikey: ANON_KEY` + `Authorization: Bearer ${CRM_RESOLVER_KEY}`; `CRM_RESOLVER_KEY` bounded-expiry + documented rotation.

---

## Remaining work before the first live CRM sync

1. **P2 — `crm-sync-dispatch` Edge Function** (next; DB prerequisites all complete).
2. **`crm-test-connection` Edge Function** to the frozen V6 contract (`private_token`-only; closes V8 Step 5a; wire `VITE_CRM_TEST_ENDPOINT_URL`).
3. **N8N outbound drain workflow** (schedule → claim → dispatch → complete; concurrency=1; execution-data off; error-trigger alert).
4. **Mint + store role JWTs** (`crm_automation` → N8N; `crm_resolver` → function secret) and `EDGE_DISPATCH_TOKEN`.
5. **Connect a real GoHighLevel integration** (owner UI, `private_token`) and run the connection test → closes the deferred V8 positive resolver validation.
6. **P4 — frontend sync-health surface** (`last_sync_at`/`last_error`).

---

## Deferred Items (intentional)
- `crm-test-connection` Edge Function (with/after P2). Disconnect/disable CRM integration (future additive migration). Deprecated-column cleanup post-cutover. CRM config editor (empty `config{}` today → standard fields + tags only). HubSpot/Salesforce UI + `api_key`/`oauth2` GHL auth. Orphaned-`processing` recovery for the integration-deleted-mid-flight case (audit F1; manual requeue today). `claim_invitation()`; Org switching; PMS ingestion; inbound CRM→OS sync; AI pricing/forecasting; full rpc typing fix.

---

## Resume State — what to do next
1. **Begin P2 — `crm-sync-dispatch` Edge Function** to the objectives above (the revised P2 blueprint + Phase 3 spec are authoritative for contracts).
2. **Backend is frozen** — additive forward migrations only. Reads via safe views; writes via RPC; never expose `auth_user_id`/`active_org_id`/`token`/`credentials`/Vault.
3. **On first successful resolve+sync**, close the deferred V8 positive resolver test (Step 5a).
4. **Pre-flight before any DB work** — confirm deployed schema matches v7+v8+v9+v10 and the v6 trigger bodies; confirm the JWT hook is registered.
5. **Working agreement** — tightly-scoped increments, each ending with a file-by-file diff summary and a stop for review.

---

## Pointers
- **Dispatch RPC:** `supabase/migrate_v10_get_dispatch_event.sql` (gates in its commented verification block).
- **Automation RPCs:** `supabase/migrate_v9_crm_automation.sql`. **Secure credentials:** `supabase/migrate_v8_crm_secure.sql` + `supabase/V8_DEPLOYMENT_VERIFICATION.md`.
- **Phase 2 frontend:** `src/lib/types.ts`, `src/api/integrations.ts`, `src/pages/IntegrationsPage.tsx`, `src/components/integrations/CrmIntegrationModal.tsx`.
- **Prior checkpoint (history):** `PROJECT_CHECKPOINT_V7.md` (superseded).

*End of PROJECT_CHECKPOINT_V8.md — authoritative resume point. Supersedes V7.*
