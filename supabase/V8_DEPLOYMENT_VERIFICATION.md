# V8 Deployment Verification Procedure
## CRM Secure Credential Foundation — `migrate_v8_crm_secure.sql`

Step-by-step execution guide to run **after** applying `migrate_v8_crm_secure.sql`.
Derived from the migration's Step 8 verification block. **Verification only — no migration, no schema change.**

---

## Prerequisites

- Run in the **Supabase SQL Editor** (executes as `postgres`) unless a step says otherwise.
- All impersonation tests wrap in `BEGIN … ROLLBACK` and set the JWT-claims GUC — **nothing persists**, including any test secret written to Vault (Vault 0.3.1 `create_secret` is transactional and rolls back).
- Replace these placeholders before running:

| Placeholder | Meaning | Seeded value |
|---|---|---|
| `<aries_auth_uuid>` | `auth.users.id` for aries@test.com | (look up in dashboard) |
| `<aries_org_id>` | aries organization id | `00000000-0000-0000-0000-000000000001` |
| `<aries_user_id>` | `public.users.id` for aries | `00000000-0000-0000-0000-000000000020` |
| `<integration_id>` | a `crm_integrations.id` that has a secret | (from Step 2 output) |

**Global gate:** every step below must PASS before the v8 deployment is considered validated. A single FAIL = do not proceed to frontend/N8N work; consult the failure interpretation and, if needed, the rollback notes in the migration (Step 9).

---

## Step 1 — Migration applied successfully

**SQL**
```sql
-- 1a. New columns present
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations'
  AND column_name IN ('auth_type','credential_ref','connected_at','connected_by',
                      'last_error','last_error_at','sync_cursor')
ORDER BY column_name;

-- 1b. Constraint + FK added
SELECT conname
FROM pg_constraint
WHERE conrelid = 'public.crm_integrations'::regclass
  AND conname IN ('crm_integrations_auth_type_check','crm_integrations_connected_by_fkey')
ORDER BY conname;

-- 1c. Both functions exist with expected signatures
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('upsert_crm_integration','resolve_crm_secret')
ORDER BY p.proname;

-- 1d. Safe view exists and is security_invoker
SELECT relname, reloptions
FROM pg_class
WHERE relname = 'crm_integrations_safe' AND relkind = 'v';
```

**Expected result**
- 1a: **7 rows** (all new columns).
- 1b: **2 rows** (check + fkey).
- 1c: **2 rows** — `resolve_crm_secret(uuid)` and `upsert_crm_integration(text, text, text, text, jsonb, text, timestamp with time zone)`.
- 1d: one row; `reloptions` contains `security_invoker=true`.

**Pass criteria:** all four queries return the expected counts/values.

**Failure interpretation:** Any missing column/function/constraint means the single transaction **rolled back** (the whole file is atomic) — re-check the SQL Editor output for the first error. If only 1d fails (view missing or not invoker), the Step 7 DROP+CREATE did not complete — confirm no leftover error and that no object blocked the `DROP`.

---

## Step 2 — Vault backfill verification

Run as `postgres`/`service_role`. **Do not log output in shared channels — query 2b touches plaintext.**

**SQL**
```sql
-- 2a. Every row that held a legacy secret now has a Vault reference
SELECT id, provider,
       (credentials ? 'api_key' OR credentials ? 'make_webhook_secret') AS had_secret,
       (credential_ref ? 'vault_secret_id')                              AS has_vault_ref,
       credential_ref->>'last4'                                          AS last4,
       auth_type
FROM public.crm_integrations
WHERE credentials ? 'api_key' OR credentials ? 'make_webhook_secret'
ORDER BY id;

-- 2b. The Vault secret decrypts and matches the legacy plaintext
SELECT ci.id,
       (ds.decrypted_secret
         = COALESCE(ci.credentials->>'api_key', ci.credentials->>'make_webhook_secret')) AS matches
FROM public.crm_integrations ci
JOIN vault.decrypted_secrets ds
  ON ds.id = (ci.credential_ref->>'vault_secret_id')::uuid
WHERE ci.credentials ? 'api_key' OR ci.credentials ? 'make_webhook_secret';
```

**Expected result**
- 2a: every row shows `has_vault_ref = true`, a 4-char `last4`, `auth_type = 'api_key'`.
- 2b: `matches = true` for every row.

**Pass criteria:** all backfilled rows have a Vault ref **and** decrypt to the original value. (If the project had **zero** legacy secrets, both queries return 0 rows — that is a trivial PASS; note it.)

**Failure interpretation:**
- `has_vault_ref = false` on a row with a secret → the Step 3 loop skipped it (empty/NULL secret value, or the guard saw a pre-existing ref). Inspect `credentials` for that row.
- `matches = false` → wrong key migrated or a Vault decryption mismatch — **stop**; do not clear `credentials`, investigate before any cutover.

---

## Step 3 — CRM safe-view verification

**SQL**
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'crm_integrations_safe'
ORDER BY ordinal_position;
```

**Expected result:** column list **includes** `auth_type, credential_ref, config, status, connected_at, connected_by, last_error, last_error_at, last_sync_at, sync_cursor` and **excludes** `credentials`.

**Pass criteria:** `credentials` is **absent**; all v8 non-secret fields are present.

**Failure interpretation:** `credentials` present → the view SELECT list is wrong (secret exposure — treat as critical, do not expose to frontend). Missing v8 fields → a stale/old view definition is live; re-confirm Step 7 ran.

---

## Step 4 — Browser security verification

Confirms the authenticated (browser) role cannot read secrets, reach Vault, run the resolver, or write the base table.

**SQL**
```sql
-- 4a. Effective privileges (no impersonation needed)
SELECT
  has_table_privilege ('authenticated','public.crm_integrations','INSERT')                 AS ins,
  has_table_privilege ('authenticated','public.crm_integrations','UPDATE')                 AS upd,
  has_table_privilege ('authenticated','public.crm_integrations','DELETE')                 AS del,
  has_column_privilege('authenticated','public.crm_integrations','credentials','SELECT')   AS cred_sel,
  has_table_privilege ('authenticated','vault.decrypted_secrets','SELECT')                 AS vault_sel,
  has_function_privilege('authenticated','public.resolve_crm_secret(uuid)','EXECUTE')      AS can_resolve,
  has_function_privilege('anon',         'public.resolve_crm_secret(uuid)','EXECUTE')      AS anon_resolve;

-- 4b. Hard test: direct credential read is denied
BEGIN;
SET LOCAL ROLE authenticated;
SELECT credentials FROM public.crm_integrations;   -- must error
ROLLBACK;
```

**Expected result**
- 4a: **all seven columns FALSE.**
- 4b: `ERROR: permission denied for table/column crm_integrations`.

**Pass criteria:** no write privilege, no credential SELECT, no Vault SELECT, no resolver EXECUTE for authenticated/anon; 4b denied.

**Failure interpretation:**
- `ins/upd/del = true` → Step 6 revoke didn't run (the H-1 browser write path is still open).
- `cred_sel` or `vault_sel = true` → secret read path open — **critical**, halt.
- `can_resolve/anon_resolve = true` → resolver grant drifted to a browser role (cross-tenant secret oracle) — **critical**, halt.

---

## Step 5 — Resolver-function verification

Confirms `service_role` can resolve a secret server-side and that the function fails closed for unknown ids and browser roles.

**SQL**
```sql
-- 5a. As service_role: resolves a known secret (set role to service_role in this session)
SET ROLE service_role;
SELECT public.resolve_crm_secret('<integration_id>'::uuid) IS NOT NULL AS resolved_known;
SELECT public.resolve_crm_secret(gen_random_uuid())        IS NULL     AS null_for_unknown;
RESET ROLE;

-- 5b. As authenticated: resolver is not executable
BEGIN;
SET LOCAL ROLE authenticated;
SELECT public.resolve_crm_secret('<integration_id>'::uuid);   -- must error
ROLLBACK;
```

**Expected result**
- 5a: `resolved_known = true`, `null_for_unknown = true`.
- 5b: `ERROR: permission denied for function resolve_crm_secret`.

**Pass criteria:** service_role resolves a real secret and gets NULL for a random id; authenticated is denied EXECUTE.

**Failure interpretation:**
- `resolved_known = false` for a row known to have a secret → `credential_ref.vault_secret_id` missing/garbled, or the definer owner lacks Vault read (re-run Step 2). 
- 5b does **not** error → resolver grant is wrong — **critical**, halt.

---

## Step 6 — Owner-only RPC verification

All blocks roll back (no persistence). Confirms owner write returns **safe fields only**, and non-owner / misplaced-secret are rejected.

**SQL**
```sql
-- 6a. Owner can write; return carries NO plaintext
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','owner',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
SELECT public.upsert_crm_integration(
  'gohighlevel','Aries — GHL','loc_test_123','api_key','{}'::jsonb,'secret-test-9999',NULL);
ROLLBACK;

-- 6b. Manager (non-owner) is rejected
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','manager',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
SELECT public.upsert_crm_integration('gohighlevel','x',NULL,'api_key','{}'::jsonb,'k',NULL);
ROLLBACK;

-- 6c. Secret smuggled in config is rejected (owner claims)
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','owner',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
SELECT public.upsert_crm_integration(
  'gohighlevel','x',NULL,'api_key','{"api_key":"leak"}'::jsonb,NULL,NULL);
ROLLBACK;
```

**Expected result**
- 6a: a JSONB object with `status='active'`, `last4='9999'`, and **no** `credentials`/`secret`/plaintext key.
- 6b: `ERROR: … role manager may not manage CRM integrations (owner only)` (SQLSTATE 42501).
- 6c: `ERROR: … config must not contain secret keys …`.

**Pass criteria:** 6a returns safe fields only; 6b and 6c both raise.

**Failure interpretation:**
- 6a return contains any secret/plaintext key → the RPC return shape is wrong — **critical**, halt.
- 6b succeeds → owner gate broken (privilege escalation).
- 6c succeeds → config-secret guard missing (browser-readable secret leak path).

---

## Step 7 — RLS verification

Confirms tenant isolation on the safe view and that the role matrix holds.

**SQL**
```sql
-- 7a. Owner sees only own-org rows through the safe view
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','owner',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
SELECT count(*)                                                       AS visible,
       count(*) FILTER (WHERE organization_id <> '<aries_org_id>')    AS foreign_rows
FROM public.crm_integrations_safe;
ROLLBACK;

-- 7b. Staff/viewer see NO CRM rows (policy admits owner/manager only)
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','staff',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
SELECT count(*) AS staff_visible FROM public.crm_integrations_safe;
ROLLBACK;

-- 7c. Direct base-table INSERT is revoked (RPC is the only write path)
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object(
  'sub','<aries_auth_uuid>','role','authenticated',
  'app_metadata', json_build_object(
    'org_id','<aries_org_id>','user_role','owner',
    'user_id','<aries_user_id>','is_org_wide',true))::text, true);
INSERT INTO public.crm_integrations (organization_id, provider, name)
VALUES ('<aries_org_id>','none','x');   -- must error
ROLLBACK;
```

**Expected result**
- 7a: `foreign_rows = 0`.
- 7b: `staff_visible = 0`.
- 7c: `ERROR: permission denied for table crm_integrations`.

**Pass criteria:** no cross-org rows for owner; zero rows for staff; direct INSERT denied.

**Failure interpretation:**
- `foreign_rows > 0` → tenant isolation broken on the view/base RLS — **critical**, halt.
- `staff_visible > 0` → the owner/manager-only SELECT policy is not in effect.
- 7c succeeds → Step 6 revoke didn't take (H-1 still open).

---

## Step 8 — Rollback readiness verification

Confirms the dual-read fallback is intact (no data loss on rollback), Vault ids are captured for cleanup, and the rollback DROP targets exist.

**SQL**
```sql
-- 8a. Legacy credentials RETAINED (never cleared by v8) — N8N fallback intact
SELECT count(*) AS rows_with_legacy_secret
FROM public.crm_integrations
WHERE credentials ? 'api_key' OR credentials ? 'make_webhook_secret';

-- 8b. Capture Vault ids created by v8 (store this list with the deploy record;
--     rollback deletes these only if a clean revert is mandated)
SELECT id AS integration_id, credential_ref->>'vault_secret_id' AS vault_secret_id
FROM public.crm_integrations
WHERE credential_ref ? 'vault_secret_id'
ORDER BY id;

-- 8c. Rollback DROP targets exist
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('upsert_crm_integration','resolve_crm_secret')
ORDER BY p.proname;

-- 8d. service_role can still read the legacy column (dual-read confirmed)
SET ROLE service_role;
SELECT count(*) AS legacy_readable FROM public.crm_integrations WHERE credentials <> '{}'::jsonb;
RESET ROLE;
```

**Expected result**
- 8a: equals the **pre-migration** count of rows with a legacy secret (unchanged).
- 8b: one row per backfilled/RPC-created secret; **record the output**.
- 8c: **2 rows**.
- 8d: `legacy_readable` > 0 if any legacy secrets exist (service_role can still read them).

**Pass criteria:** legacy `credentials` retained and service_role-readable; Vault id list captured; both functions present as rollback targets.

**Failure interpretation:**
- 8a lower than pre-migration → `credentials` was cleared somewhere (it shouldn't be in v8) → **rollback fallback compromised, do not cut over**.
- 8c < 2 → a function is missing → rollback notes must be adjusted (nothing to drop).

---

## Sign-off

| Step | Result | Notes |
|---|---|---|
| 1 — Migration applied | ☐ Pass / ☐ Fail | |
| 2 — Vault backfill | ☐ Pass / ☐ Fail | |
| 3 — Safe view | ☐ Pass / ☐ Fail | |
| 4 — Browser security | ☐ Pass / ☐ Fail | |
| 5 — Resolver | ☐ Pass / ☐ Fail | |
| 6 — Owner-only RPC | ☐ Pass / ☐ Fail | |
| 7 — RLS | ☐ Pass / ☐ Fail | |
| 8 — Rollback readiness | ☐ Pass / ☐ Fail | |

**Deployment is validated only when all eight steps PASS.** Steps 4, 6, and 7 are the security-critical gates — any FAIL there must block frontend connect-UI and N8N consumer work and trigger the migration's Step 9 rollback review.
