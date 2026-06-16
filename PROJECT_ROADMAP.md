# PROJECT_ROADMAP.md
# Campground OS — Implementation Execution Roadmap

**Document Status:** Execution Plan (sequencing only)
**Date:** 2026-06-13
**Authoritative Source of Truth:** [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md)

> This roadmap defines **execution order** after architecture and security design completion. It does not redesign architecture or revisit completed decisions. For any "what" or "why" question about the system, defer to PROJECT_CHECKPOINT_V3.md. This document answers only **"what to build next, and in what order."**

**Assumptions (all confirmed in CHECKPOINT_V3):**
- Architecture Phase = Complete
- Security Phase = Complete
- Migration Design Phase = Complete
- Project Status = **Implementation Ready**

---

## SECTION 1 — Current State

### Completed
| Area | Reference in CHECKPOINT_V3 |
|---|---|
| Architecture Design | §2, §3 |
| Multi-Tenant Model | §3 (Organization/Property/Tenant scope) |
| Loyalty Lifecycle | §9 |
| Authentication Model | §6 |
| CRM Abstraction | §10 |
| PMS Abstraction | §11 |
| Onboarding Model | §4 (`onboarding_sessions`), §12 |
| Security Reviews | §8, §15 |
| Red-Team Reviews (2 passes) | §8 (RT-A1/A2/A3/B1/B2) |
| Production Readiness Review | §17 |
| Migration Chain v1–v7 | §5 (incl. B1/B2 fixes) |

### Current Status
**Implementation Ready.** The database, security model, authentication, and authorization are deployable today. No frontend, N8N workflows, or monitoring exist yet. The remaining work is execution, not design.

---

## SECTION 2 — Strategic Priorities

Ranked highest → lowest, derived from Joe's interview (CHECKPOINT_V3 §1, §19). The ordering reflects the product thesis: *"The reservation is the input. Guest retention is the outcome."*

| # | Priority | Why |
|---|---|---|
| 1 | **Guest Retention** | The primary goal and the reason the platform exists. Everything else is instrumental to bringing guests back. It is the metric Joe's customers buy. |
| 2 | **Guest Communication** | The mechanism of retention. Welcome, pre-arrival, post-stay messaging through GHL is how relationships are maintained between stays. |
| 3 | **Check-In Automation** | Reduces operator labor and creates the first touchpoint of a stay; high operator-perceived value and low build complexity. |
| 4 | **Review Requests** | Directly compounds retention and acquisition (reputation). Cheap to automate once communication flows exist. |
| 5 | **CRM Enrichment** | Keeps GHL contacts current (tiers, tags, custom fields) so all downstream automation targets accurately. Foundation under 2–4. |
| 6 | **AI Concierge** | High differentiation but depends on dashboard + communication + a knowledge base being operational first. Deferred by design. |
| 7 | **Maintenance Routing** | Operational nicety that converts guest issues into staff workflows; valuable but not core to the retention thesis. |
| 8 | **Revenue Intelligence** | Future analytics/forecasting layer; reads existing data, blocks nothing, and is explicitly deferred (not MVP). |

**Implication for sequencing:** Build the data-management surface (dashboard) and the automation spine (N8N) before communication; build communication before AI; treat maintenance and revenue intelligence as post-MVP.

---

## SECTION 3 — Implementation Phases

Phases are strictly sequential through Phase 5; Phases 6–8 are post-MVP. Each phase's exit criteria gate the next.

---

### PHASE 1 — Environment Validation
**Goal:** Prove the approved migration chain deploys and enforces correctly on a clean project. (Deploy procedure: CHECKPOINT_V3 §18.)

**Tasks:**
- Create a fresh Supabase **Dev** project; confirm `pgcrypto` available.
- Run `schema.sql`.
- Run `migrate_v2` → `migrate_v7` in order. **Do not run `seed_simulation.sql`** for the production-path validation (optional demo data only); run a second pass *with* it to validate demo data separately.
- Create Auth users; backfill `users.auth_user_id`; register `custom_access_token_hook`.
- Validate JWT claims (`org_id`, `user_role`, `is_org_wide` in `app_metadata`).
- Validate active-org switching (`active_org_id` update → `refreshSession()` → new scope).
- Validate RLS via the v7 impersonation suite (V0–V13, incl. RT-A1/A2/A3/B1/B2 cases).
- Validate loyalty lifecycle (INSERT → `total_visits++`; checkout → `confirmed_visits`/`total_spend`/tier).
- Validate CRM integrations (`crm_integrations_safe` readable; `credentials` denied).
- Validate onboarding (config + session rows).

**Critical gate:** the JWT hook must be **verified live before** `migrate_v7`, or all users lock out (CHECKPOINT_V3 §5, §18).

**Exit Criteria:** Fresh chain deploys clean without the seed; all V0–V13 checks pass; loyalty + CRM + onboarding verified. **Environment fully validated.**

---

### PHASE 2 — MVP Dashboard Foundation
**Goal:** First operational dashboard — operators can manage their own data under real RLS.

**Pages:** Login · Dashboard (KPIs) · Properties · Guests · Reservations · Organization Settings.

**Binding implementation constraints (CHECKPOINT_V3 §12):**
- Authenticate before any query (the anonymous demo dashboard is gone post-v7).
- Provide `OrgContext` (reads `user_accessible_orgs`) + Navbar org-switcher.
- Read guest data via `guest_summary` / `reservation_detail` only; never name columns from `guests`.
- Create guests via `rpc('upsert_guest', …)`; create reservations via `rpc('create_reservation', …)`.
- KPIs from `kpi_summary`. Never `SELECT *` on secret-bearing tables.

**Exit Criteria:** An authenticated operator can view KPIs and manage properties, guests, and reservations within their org. **Operators can manage data.**

---

### PHASE 3 — Staff & Administration
**Goal:** Operators can onboard staff and configure integrations.

**Pages:** User Management · Invitations · Roles · CRM Settings · PMS Settings.

**Notes:**
- Roles UI must enforce the matrix (CHECKPOINT_V3 §7): managers may grant/invite only staff/viewer; integration management is owner-only.
- Invitations require the deferred `claim_invitation()` SECURITY DEFINER RPC (CHECKPOINT_V3 §16) — build it as part of this phase's backend.
- CRM/PMS settings read via `*_safe` views; credential entry is **write-only** (never displayed).

**Exit Criteria:** Owners/managers can invite staff, assign roles, and configure CRM + PMS integrations. **Operators can onboard staff.**

---

### PHASE 4 — N8N Integration Layer
**Goal:** Connect business workflows; make the PMS→Supabase→GHL spine operational. (Architecture: CHECKPOINT_V3 §14.)

**Deliverables:**
- **Reservation Sync** — PMS → N8N → Supabase (service-role insert, idempotent on `external_reservation_id`).
- **CRM Sync** — Supabase/N8N → GHL (contacts, tags, custom fields, workflow triggers).
- **Webhook Processing** — HMAC verification (per-org secret from `pms_integrations.credentials`) as the first node.
- **Retry Strategy** — per-node retry + `webhook_events.status='failed'` on terminal failure; daily reconciliation replay + **daily PMS reconciliation poll**.
- **Error Monitoring** — error-workflow alerting; failed-event + zero-traffic heartbeat alerts.

**Exit Criteria:** Reservations flow from PMS into Supabase and sync to GHL; failures are retried/reconciled and surfaced. **Automations operational.**

---

### PHASE 5 — Guest Communication
**Goal:** Automate guest engagement through GHL (the retention payoff).

**Deliverables:** Check-In Messages · Check-Out Messages · Review Requests · Follow-Up Campaigns.

**Notes:** Communication executes in GHL workflows, triggered by reservation/status/tier events flowing through N8N (Phase 4). The dashboard does not duplicate email/SMS UI (GHL-first, CHECKPOINT_V3 §10, §19).

**Exit Criteria:** Welcome, pre-arrival, post-stay, review, and follow-up flows fire automatically off reservation lifecycle events. **Guest communication operational.** — *This completes the MVP retention loop.*

---

### PHASE 6 — AI Concierge Foundation *(Post-MVP)*
**Goal:** Knowledge-driven guest assistant. (Vision: CHECKPOINT_V3 §13.)

**Deliverables:** Knowledge Base tables (`kb_documents`, `kb_chunks` with denormalized `organization_id` + `embedding`) · Supabase **pgvector** · Semantic Search (org-scoped retrieval RPC) · OpenAI Integration.

**Hard rules (CHECKPOINT_V3 §13):** pgvector first (no Pinecone); retrieval filters `organization_id` server-side from the N8N-verified source (never model/prompt-supplied); model gets no write tools and no cross-guest reads; RLS on all four AI tables from day one.

**Exit Criteria:** The assistant answers campground/FAQ questions scoped to a single org. **AI can answer campground questions.**

**Do not start before Phase 2 and Phase 5 are operational.**

---

### PHASE 7 — Maintenance Routing *(Post-MVP)*
**Goal:** Convert guest issues into staff workflows.

**Deliverables:** Maintenance Requests (table + intake) · Staff Assignment · Escalation Flow.

**Exit Criteria:** Guest-reported issues become tracked, assignable staff tasks with escalation. **Maintenance workflow operational.**

---

### PHASE 8 — Revenue Intelligence *(Deferred — Not MVP)*
**Goal:** Future analytics layer.

**Deliverables:** Occupancy Facts · Revenue Reporting · Forecasting · Pricing Insights.

**Status: Deferred. Not MVP.** Reads existing Supabase data; blocks nothing.

---

## SECTION 4 — Technical Debt Queue

Categorized backlog (sources: CHECKPOINT_V3 §16 deferred features, §15 security baseline, §17 status).

### Security
- `claim_invitation()` SECURITY DEFINER RPC (hash-compare token, single-use, expiry) — *needed for Phase 3.*
- Credentials → Supabase Vault / pgsodium (currently column-locked plaintext).
- Restricted `automation` role to scope N8N below full `service_role`.
- `auth_log` / audit logging for role grants, credential changes, exports, deletions.

### Operations
- `webhook_events` retention/TTL + PII minimization (payload → IDs).
- Customer offboarding automation (cancel → disable integrations → export → grace → purge).
- Data export automation (per-org guests/reservations/loyalty).
- Soft-delete enforcement on `organizations` (avoid CASCADE annihilation).

### Monitoring
- N8N error-workflow alerting; failed-event counters on dashboard.
- Zero-traffic heartbeat per org (silent PMS disconnection).
- Uptime/error-budget instrumentation; status page.

### Analytics
- Revenue Intelligence (Phase 8): occupancy facts, ADR, time-series KPIs, forecasting.
- Property-level filtering throughout the dashboard.

### AI
- Knowledge Base data model + ingestion pipeline.
- Per-org retrieval RPC + conversation logging (`concierge_threads`/`messages`).
- OpenAI zero-retention/no-training tier + DPA + privacy-policy line.

### Schema / Misc
- Add `no_show` to `reservations.status` CHECK (currently dead code).
- Feature entitlements keyed on `organizations.plan`.
- Remove deprecated columns (`organizations.ghl_location_id`/`make_webhook_secret`, `guest_org_profiles.ghl_contact_id`) once N8N + UI confirmed off them.

---

## SECTION 5 — Security Roadmap

| Milestone | Classification |
|---|---|
| Webhook Signatures (HMAC verification in N8N) | **MVP** (Phase 4) |
| `claim_invitation()` secure token claim | **MVP** (Phase 3) |
| Audit Logs (`audit_log` for sensitive actions) | **Post-MVP** |
| Secret Encryption (credentials → Vault/pgsodium) | **Post-MVP** |
| Rate Limiting (per-tenant automation throughput) | **Post-MVP** |
| Backup Strategy (Supabase Pro + PITR, tested restore) | **Post-MVP** (before first paying customer) |
| Disaster Recovery (RTO/RPO targets, DR drills) | **Scale** |
| Restricted `automation` role | **Post-MVP** |
| SOC 2 trajectory | **Scale** |

**Foundational guarantees already in place (MVP, complete):** JWT-based tenant context, production RLS, two-layer least privilege, column-locked secrets, SQL-injection-free access, cross-tenant leakage prevention (CHECKPOINT_V3 §8, §15).

---

## SECTION 6 — Deployment Roadmap

| Environment | Purpose |
|---|---|
| **Development** | Throwaway Supabase project for Phase 1 validation and active feature work. Migration chain re-run freely; demo seed allowed. Frontend points here during Phases 2–3. |
| **Staging** | Production-shaped project mirroring final config (hook registered, no demo seed, real N8N instance in test mode). Pre-release verification of the V0–V13 suite + end-to-end PMS→GHL flow. |
| **Production** | Live tenant project(s). Hook verified before v7; `service_role` key held only by N8N infra; backups/PITR enabled before first paying customer. |

**Recommended deployment sequence (per environment):** apply migrations `schema → v2 → v3 → v4 → v5 → v6`, register + verify the JWT hook, then apply `v7`, then run the post-deploy checklist (CHECKPOINT_V3 §18). Promote Dev → Staging → Production only after each environment passes the full validation suite.

---

## SECTION 7 — AI Concierge Roadmap *(Future Phase)*

**Approved future vision (CHECKPOINT_V3 §13):**
```
Guest → GHL Chat Widget → N8N → Supabase Knowledge Base (pgvector) → OpenAI → Response
```

**Scope:**
- **FAQ** — org-authored knowledge base content.
- **Reservation Support** — read-only, the guest's own reservation context pre-fetched server-side.
- **Maintenance Support** — intake routed into the Phase 7 workflow.
- **Human Escalation** — handoff path when the assistant cannot resolve.

**Mark: Future Phase.** Begins at Phase 6, only after dashboard (Phase 2) and guest communication (Phase 5) are operational. pgvector first; no Pinecone; org-scoped retrieval enforced server-side.

---

## SECTION 8 — Success Milestones

| # | Milestone | Reached When |
|---|---|---|
| 1 | **Database Validation Complete** | Phase 1 exit — fresh chain deploys clean, V0–V13 pass. |
| 2 | **Dashboard Operational** | Phase 2 (+3) exit — operators manage data, staff, and integrations. |
| 3 | **N8N Operational** | Phase 4 exit — reservations sync PMS→Supabase→GHL with retries/reconciliation. |
| 4 | **Guest Communication Operational** | Phase 5 exit — retention messaging fires off lifecycle events. **MVP complete.** |
| 5 | **AI Concierge MVP** | Phase 6 exit — org-scoped FAQ/reservation answers. |
| 6 | **First Paying Customer** | After Milestone 4 + billing, legal (ToS/Privacy/DPA), backups/PITR, and onboarding wizard live. |
| 7 | **10 Customers** | Entitlements, usage metering, internal admin tooling, monitoring discipline, status page. |
| 8 | **100 Customers** | webhook_events partitioning, per-tenant rate limiting, DR drills/RTO-RPO commitments, SOC 2 trajectory. |

---

## SECTION 9 — Executive Summary

### What to work on next
**Phase 1 — Fresh Supabase Validation.** Stand up a clean Dev project, run `schema → v7` (without the seed), register and verify the JWT hook, and pass the full V0–V13 RLS suite plus loyalty/CRM/onboarding checks. Nothing else should start until the migration chain is proven to deploy and isolate correctly on a clean project.

### What NOT to work on yet
- **AI Concierge / Knowledge Base (Phase 6)** — do not start until the dashboard (Phase 2) and guest communication (Phase 5) are operational.
- **Maintenance Routing (Phase 7)** and **Revenue Intelligence (Phase 8)** — post-MVP; do not begin during the core build.
- **Any architecture or security redesign** — those phases are frozen (CHECKPOINT_V3). Build to the existing contract.

### Focus Statement
- **Current Focus: Fresh Supabase Validation** (Phase 1).
- **Next Focus: Dashboard Development** (Phases 2–3).
- **Future Focus: AI Concierge** (Phase 6).

> **Hard rule:** Do not start the AI Concierge until the dashboard and guest-communication workflows are operational.

---

*End of PROJECT_ROADMAP.md — execution sequencing only. For architecture and security detail, see [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md).*
