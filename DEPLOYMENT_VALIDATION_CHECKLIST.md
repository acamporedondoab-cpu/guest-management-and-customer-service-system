# DEPLOYMENT_VALIDATION_CHECKLIST.md
# Campground OS — Deployment & Validation Runbook

**Document Status:** Operational checklist (run top to bottom)
**Date:** 2026-06-13
**Authoritative Source of Truth:** [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md) (deploy procedure §18, security model §8, migrations §5)

> Work through this file in order. Do not skip the **hard gate** in Step 3 — applying `migrate_v7` before the JWT hook is verified locks every user out of all data. Tick each box only after the stated expected result is observed. Anything that fails is a **stop** — resolve before continuing.

**Legend:** `[ ]` not done · `[x]` passed · `[!]` failed (stop) · `[n/a]` not applicable to this environment.

---

## STEP 0 — Prerequisites

- [ ] Target environment chosen and named: **Development / Staging / Production** (circle one).
- [ ] Fresh Supabase project created (empty `public` schema).
- [ ] `pgcrypto` extension available (Supabase default — `invitations.token` uses `gen_random_bytes`).
- [ ] All seven migration files present and at the reviewed revision:
  - [ ] `schema.sql`
  - [ ] `migrate_v2_multi_tenant.sql`
  - [ ] `migrate_v3_loyalty_lifecycle.sql`
  - [ ] `migrate_v4_auth_context.sql`
  - [ ] `migrate_v5_crm_integrations.sql`
  - [ ] `migrate_v6_onboarding.sql`
  - [ ] `migrate_v7_tenant_rls.sql`
- [ ] Decision recorded: run `seed_simulation.sql`? **(Optional demo data; NOT required.** For a production tenant, leave it out. For a validation/demo project, run it after Step 2.)
- [ ] Service role key and project URL captured securely (service key never ships to the browser).

---

## STEP 1 — Apply migrations v1 → v6

Run each file **in order** in the Supabase SQL Editor. Stop at the first error.

- [ ] `schema.sql` applied — no errors.
- [ ] `migrate_v2_multi_tenant.sql` applied — no errors.
- [ ] `migrate_v3_loyalty_lifecycle.sql` applied — no errors.
  - [ ] Confirms B2: the composite constraint now exists.
- [ ] `migrate_v4_auth_context.sql` applied — no errors.
- [ ] `migrate_v5_crm_integrations.sql` applied — no errors.
- [ ] `migrate_v6_onboarding.sql` applied — no errors.

**Verification — constraint (B2) and column additions exist:**
```sql
-- Expect one row: loyalty_guest_org_unique UNIQUE (guest_id, organization_id)
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.loyalty'::regclass AND contype = 'u';

-- Expect organization_id + confirmed_visits present on loyalty
SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='loyalty'
  AND column_name IN ('organization_id','confirmed_visits');
```
- [ ] `loyalty_guest_org_unique` present; `loyalty_guest_id_key` gone.
- [ ] `loyalty.organization_id` and `loyalty.confirmed_visits` present.

**Verification — trigger functions are SECURITY DEFINER (B1):**
```sql
-- Expect prosecdef = true for all three
SELECT proname, prosecdef
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('handle_new_reservation',
                  'handle_reservation_status_change',
                  'handle_loyalty_tier_change');
```
- [ ] All three return `prosecdef = true`.

- [ ] *(Optional)* `seed_simulation.sql` applied if this is a demo project — no errors.

---

## STEP 2 — JWT Hook Configuration  ⛔ HARD GATE (before v7)

> **Do not run `migrate_v7` until every box in this step passes.** Without a verified hook, JWTs carry no `org_id` and v7's tenant RLS denies everyone.

- [ ] Create Auth users for each owner/admin who will log in (Authentication → Users → Invite/Create).
  - For a demo project seeded with `seed_simulation.sql`: create `aries@test.com` and `blue@test.com`.
- [ ] Backfill `users.auth_user_id` for each:
```sql
UPDATE public.users
SET auth_user_id = (SELECT id FROM auth.users WHERE email = '<email>')
WHERE email = '<email>';
-- Demo: aries@test.com and blue@test.com (seeded users 0020 / 0021, both 'owner')
```
- [ ] Register the hook: Authentication → Hooks → **Custom Access Token Hook** → Schema `public`, Function `custom_access_token_hook`.
- [ ] Confirm the hook grant exists (`supabase_auth_admin` only):
```sql
SELECT has_function_privilege('supabase_auth_admin',
  'public.custom_access_token_hook(jsonb)', 'EXECUTE');  -- expect true
```
- [ ] **Verify enrichment:** log in as a backfilled user, then in the browser console:
```js
const { data } = await supabase.auth.getSession();
console.log(data.session.user.app_metadata);
// Expect: org_id, property_id, user_role, user_id, is_org_wide populated
```
  - [ ] `app_metadata.org_id` is set.
  - [ ] `app_metadata.user_role` is correct (demo: `owner` for both `aries@` and `blue@`).
  - [ ] `app_metadata.is_org_wide` is present.

**Gate:** ☐ **JWT hook verified live — cleared to apply v7.**

---

## STEP 3 — Apply migrate_v7 (the security flip)

- [ ] `migrate_v7_tenant_rls.sql` applied as a single execution — no errors.
- [ ] No partial application (run the whole file in one transaction so demo policies are never dropped without tenant policies in place).

---

## STEP 4 — RLS & Policy Validation (V0–V10)

Run the commented impersonation blocks from `migrate_v7` §9. Each uses `BEGIN; SET LOCAL ROLE …; set_config('request.jwt.claims', …); … ROLLBACK;`. Replace `<aries_auth_uuid>` / `<blue_auth_uuid>` with real `auth.users` IDs.

- [ ] **V0 — Policy inventory:** zero `demo_allow_all_*`; 30+ `tenant_*` policies.
```sql
SELECT count(*) FILTER (WHERE policyname LIKE 'demo_allow_all%') AS demo_left,
       count(*) FILTER (WHERE policyname LIKE 'tenant_%')        AS tenant_count
FROM pg_policies WHERE schemaname = 'public';
-- Expect demo_left = 0, tenant_count >= 30
```
- [ ] **V1 — anon lockout:** `anon` SELECT on `guests` and `guest_summary` → permission denied.
- [ ] **V2 — Tenant isolation both directions:** Aries owner sees only Aries rows; `reservations` filtered to Aries; `kpi_summary` is Aries-scoped. Repeat with Blue Ridge → mirror result.
- [ ] **V3 — Cross-org self-grant rejected:** inserting an `owner` `user_roles` row for the victim org violates RLS.
- [ ] **V4 — Manager ceiling:** manager inserting an `owner` role is rejected; inserting `staff` succeeds.
- [ ] **V5 — auth_user_id immutable:** updating own `users.auth_user_id` raises the immutability exception.
- [ ] **V6 — active_org_id membership:** setting `active_org_id` to a non-member org violates the UPDATE WITH CHECK.
- [ ] **V7 — credentials hidden:** `SELECT credentials FROM crm_integrations` → permission denied; `SELECT * FROM crm_integrations_safe` → succeeds, no credentials column.
- [ ] **V8 — Staff booking + loyalty:** staff `create_reservation` succeeds and `loyalty.total_visits` increments (DEFINER trigger ran).
- [ ] **V9 — Viewer read-only:** viewer SELECT succeeds; viewer UPDATE affects 0 rows.
- [ ] **V10 — Last-owner guard:** revoking the last active owner raises the lockout exception.

---

## STEP 5 — Red-Team Regression (V11–V13)

These confirm the two-pass red-team fixes (CHECKPOINT_V3 §8). Run as Aries, targeting a Blue Ridge email/guest.

- [ ] **V11 (RT-A1) — no cross-tenant guest PII:** after `upsert_guest('mal','lory','victim@blueridge.example',NULL)`,
  - `SELECT first_name,last_name,phone,ghl_contact_id,created_at FROM guests WHERE email=…` → **permission denied** (only `id,email` granted).
  - `SELECT id,email FROM guests WHERE email=…` → returns only opaque id + the caller-supplied email.
- [ ] **V12 (RT-A2 + RT-A3) — guest_summary shows only caller-org profile:**
  - `full_name` = the Aries placeholder; `ghl_contact_id` = **NULL** (no fallback to Blue Ridge's global value); `created_at` sourced from the org profile.
  - exactly 1 row returned (the Aries profile only).
- [ ] **V13a (RT-B1) — anon cannot execute RPCs:** as `anon`, `upsert_guest(...)` and `create_reservation(...)` → **permission denied for function**.
- [ ] **V13b (RT-B2) — guest binding:** `create_reservation(<blue-ridge-only-guest_id>, <aries-property>, …)` → exception `guest not found in your organization`.
- [ ] **V13c (RT-B2) — direct insert revoked:** direct `INSERT INTO reservations …` as `authenticated` → **permission denied for table reservations**.

**Function-grant spot check (RT-B1):**
```sql
-- Expect FALSE for anon on the RPCs; TRUE for authenticated
SELECT has_function_privilege('anon','public.upsert_guest(text,text,text,text)','EXECUTE')          AS anon_upsert,
       has_function_privilege('anon','public.create_reservation(uuid,uuid,text,date,date,integer,numeric,numeric,text)','EXECUTE') AS anon_create,
       has_function_privilege('authenticated','public.upsert_guest(text,text,text,text)','EXECUTE')  AS auth_upsert;
```
- [ ] `anon_upsert = false`, `anon_create = false`, `auth_upsert = true`.

---

## STEP 6 — Loyalty Lifecycle Validation

Run as an authenticated owner/staff in a test org (or via service role). Confirm checkout-only crediting (CHECKPOINT_V3 §9).

- [ ] Create a guest via `rpc('upsert_guest', …)` → returns a `guest_id`.
- [ ] Create a reservation via `rpc('create_reservation', …)`.
  - [ ] `loyalty.total_visits` incremented by 1.
  - [ ] `loyalty.confirmed_visits` and `total_spend` **unchanged** (still 0 at booking).
- [ ] Transition status to `checked_out`:
```sql
UPDATE public.reservations SET status='checked_out' WHERE id = '<reservation_id>';
```
  - [ ] `loyalty.confirmed_visits` incremented; `total_spend` increased by `total_amount`; `last_visit` set.
  - [ ] `loyalty.tier` recalculated against `loyalty_config` thresholds (defaults Silver=3, Gold=6).
- [ ] `webhook_events` contains both `reservation.created` and `reservation.checked_out` with `organization_id` set.
- [ ] Cancel a different reservation → confirm **no** loyalty reversal.

---

## STEP 7 — CRM / PMS Integration Validation

- [ ] `crm_integrations_safe` readable by an owner/manager; excludes `credentials`.
- [ ] `pms_integrations_safe` readable by an owner/manager; excludes `credentials`.
- [ ] Column-lock holds (service role only for secrets):
```sql
-- Expect FALSE for authenticated on the credentials column
SELECT has_column_privilege('authenticated','public.crm_integrations','credentials','SELECT') AS crm_cred,
       has_column_privilege('authenticated','public.pms_integrations','credentials','SELECT') AS pms_cred;
```
- [ ] `crm_cred = false`, `pms_cred = false`.
- [ ] A `staff`/`viewer` user sees **no** integration rows (SELECT policy is owner/manager only) — no error, empty result.

---

## STEP 8 — Onboarding Validation

- [ ] `loyalty_config` row exists per org (defaults 3/6) or is creatable by owner/manager.
- [ ] `onboarding_sessions` row readable by org members; INSERT/UPDATE owner-only.
- [ ] Owner can advance `current_step` / append `completed_steps`; staff cannot write.

---

## STEP 9 — Security Posture Spot Checks

- [ ] RLS enabled on all 15 tenant tables:
```sql
-- Expect 15 rows, all rowsecurity = true
SELECT relname, relrowsecurity
FROM pg_class
WHERE relnamespace='public'::regnamespace AND relkind='r'
  AND relname IN ('organizations','properties','users','user_roles','guests',
                  'guest_org_profiles','reservations','loyalty','loyalty_by_property',
                  'crm_integrations','pms_integrations','invitations',
                  'onboarding_sessions','webhook_events','loyalty_config')
ORDER BY relname;
```
- [ ] `anon` holds no table privileges:
```sql
SELECT count(*) AS anon_table_grants
FROM information_schema.role_table_grants
WHERE grantee='anon' AND table_schema='public';
-- Expect 0
```
- [ ] All six `security_invoker` views present and so flagged:
```sql
SELECT c.relname, (c.reloptions::text LIKE '%security_invoker=true%') AS invoker
FROM pg_class c
WHERE c.relnamespace='public'::regnamespace AND c.relkind='v'
  AND c.relname IN ('guest_summary','reservation_detail','kpi_summary',
                    'crm_integrations_safe','pms_integrations_safe','user_accessible_orgs');
```
- [ ] All six return `invoker = true`.

---

## STEP 10 — Environment-Specific Gates

### Development
- [ ] Steps 0–9 pass. Demo seed acceptable. No further gates.

### Staging
- [ ] Steps 0–9 pass **without** the demo seed.
- [ ] Real N8N instance connected in test mode; one end-to-end PMS → Supabase → GHL flow verified.
- [ ] Webhook HMAC verification rejects an unsigned/forged payload.

### Production
- [ ] Steps 0–9 pass **without** the demo seed.
- [ ] Supabase Pro plan + PITR enabled; a backup restore tested once.
- [ ] `service_role` key held only by N8N infrastructure; not in any frontend bundle.
- [ ] At least one real owner's JWT enrichment verified live (else lockout).
- [ ] Legal + billing prerequisites tracked (ToS / Privacy / DPA, billing) — see CHECKPOINT_V3 §16 / ROADMAP Milestone 6. *(Not gated by this DB checklist but required before first paying customer.)*

---

## SIGN-OFF

| Field | Value |
|---|---|
| Environment | Development / Staging / Production |
| Migration revision | schema → v2 → v3 → v4 → v5 → v6 → v7 |
| Demo seed applied? | Yes / No |
| JWT hook verified | ☐ |
| Steps 4–5 (RLS + red-team) all pass | ☐ |
| Steps 6–8 (loyalty / CRM / onboarding) all pass | ☐ |
| Step 9 (posture) all pass | ☐ |
| Deployed by | __________________ |
| Date / time | __________________ |
| Result | ☐ PASS — cleared for use   ☐ FAIL — rolled back |

> Any `[!]` failure is a stop. Re-run the affected step after remediation; do not sign off with open failures.

---

*End of DEPLOYMENT_VALIDATION_CHECKLIST.md. For the "why" behind any check, see [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md); for sequencing, see [PROJECT_ROADMAP.md](PROJECT_ROADMAP.md).*
