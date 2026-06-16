# `crm-sync-dispatch` Edge Function — Runbook

DB-authoritative CRM dispatch for Campground OS. N8N claims a `webhook_events`
row and calls this function with **only** the event id; the function derives all
routing/payload from the database as the `crm_resolver` role, resolves the
tenant's GoHighLevel secret server-side, upserts the contact, and returns a
masked, classified outcome. N8N then writes the terminal state via
`complete_webhook_event`.

> Backend prerequisites (all deployed): migrations **v8** (`resolve_crm_secret`),
> **v9** (`get_crm_dispatch_context`, claim/complete/requeue, `crm_resolver`/
> `crm_automation` roles), **v10** (`get_dispatch_event`). This function is the
> runtime that consumes them. No N8N workflow or frontend is part of this unit.

---

## 1. Position in the flow

```
N8N (crm_automation)                         Edge (crm_resolver)            GoHighLevel
  claim_webhook_events ───► event_id ─POST─► get_dispatch_event
                                             ├ status/provider/auth gates
                                             ├ get_crm_dispatch_context (revalidate)
                                             ├ resolve_crm_secret ──────────┐
                                             ├ PUT /contacts/{id} (fast path)│ secret
                                             └ POST /contacts/upsert ◄───────┘
  complete_webhook_event ◄── masked outcome ─┘
```

N8N orchestrates only — it never holds a CRM secret, table grant, or BYPASSRLS.
The Edge alone resolves secrets and talks to the provider.

---

## 2. Request / response contract

**Request** (POST, JSON): `{ "event_id": "<uuid>" }` — any other field is ignored.
**Header**: `x-dispatch-token: <EDGE_DISPATCH_TOKEN>`.

**Response** (`application/json`):

```json
{
  "event_id": "uuid|null",
  "outcome": "sent|retry|failed|skipped|ignored|no_provider|no_secret",
  "integration_id": "uuid|null",
  "contact_id": "ghl-id|null",
  "error_class": "string|null",
  "retry_after_seconds": 0,
  "provider_status": 0,
  "message": "secret-free, human-readable"
}
```

Classified outcomes return HTTP `200`. Pre-classification faults use non-2xx:
`400` bad body, `401` bad/missing token, `405` wrong method, `500` config/internal.
N8N skips `complete_webhook_event` on `ignored`; passes `p_integration_id = null`
for `no_provider`/`no_secret` (F6-safe).

---

## 3. GoHighLevel endpoints used (v2 / LeadConnector)

| Step | Method + path | Notes |
|---|---|---|
| Fast path | `PUT /contacts/{contactId}` | by stored id; **no** `locationId` in body; `404` ⇒ stale ⇒ fall through |
| Upsert | `POST /contacts/upsert` | body includes `locationId`; GHL match-or-creates by email/phone per the location's "Allow Duplicate Contact" setting; returns the contact |

- **Host**: `https://services.leadconnectorhq.com` (hardcoded constant; never from request).
- **Headers**: `Authorization: Bearer <private_token>`, `Version: 2021-07-28`, `Accept: application/json`.
- Deduplication is delegated to GoHighLevel — the function does **no** email search and handles **no** duplicate-create response.

---

## 4. GoHighLevel connection setup (per organization)

Done by the org owner through the existing CRM credential UI (`upsert_crm_integration`), **before** the first sync:

1. Create a **Private Integration** token in the GHL sub-account (Location).
2. Grant it **`contacts.readonly` + `contacts.write`** scopes. Missing scopes ⇒ GHL returns `401`/`403` ⇒ the function classifies `auth`/`forbidden` and `complete_webhook_event` flags integration health.
3. Connect in Campground OS with `provider = gohighlevel`, `auth_type = private_token`, `external_account_id = <GHL Location ID>`, and paste the Private Integration token as the secret. Only `private_token` is supported this phase.
4. The token is stored in Vault via `upsert_crm_integration()`; `external_account_id` is the `locationId` used on upsert.

`api_key` / `oauth2` are deferred — those integrations fail closed with `failed/validation` before any provider call.

---

## 5. Environment / function secrets

Supabase auto-injects `SUPABASE_URL` and `SUPABASE_ANON_KEY` into every Edge
Function — do **not** set these. Set the rest as **function secrets** (never in
the repo, never in N8N for the resolver key):

| Variable | Required | Purpose |
|---|---|---|
| `SUPABASE_URL` | auto | PostgREST endpoint (platform-injected) |
| `SUPABASE_ANON_KEY` | auto | `apikey` gateway header (platform-injected) |
| `CRM_RESOLVER_KEY` | **yes** | `crm_resolver` role JWT (HS256, bounded `exp`). Outbound DB identity. **Secret.** |
| `EDGE_DISPATCH_TOKEN` | **yes** | Inbound caller proof (constant-time compared). **Secret.** |
| `GHL_API_BASE` | no | Override the hardcoded host (default `https://services.leadconnectorhq.com`). Never request-derived. |
| `GHL_API_VERSION` | no | `Version` header (default `2021-07-28`). |

```bash
supabase secrets set \
  CRM_RESOLVER_KEY="$RESOLVER_JWT" \
  EDGE_DISPATCH_TOKEN="$(openssl rand -hex 32)" \
  --project-ref "$PROJECT_REF"
```

`SERVICE_ROLE_KEY` is intentionally never referenced.

### Gateway JWT verification

Inbound authentication is the function's own `EDGE_DISPATCH_TOKEN` check, not a
Supabase user JWT (N8N is not a Supabase user). Deploy with the platform JWT
gate **off** for this function so N8N need not present a Supabase JWT:

```toml
# supabase/config.toml
[functions.crm-sync-dispatch]
verify_jwt = false
```

(or `supabase functions deploy crm-sync-dispatch --no-verify-jwt`). The
`CRM_RESOLVER_KEY` is used only on the **outbound** PostgREST call (supabase-js
`Authorization` header) and is unrelated to the inbound gate.

---

## 6. Identity & auth model

- **Inbound (N8N → Edge):** `EDGE_DISPATCH_TOKEN` via `x-dispatch-token`, SHA-256 + constant-time compared. Proves N8N called us; carries no DB authority. A leak only lets an attacker re-fire genuinely-claimed in-flight events with their real data (idempotent) — never inject routing/payload (B-1).
- **Outbound (Edge → Postgres):** supabase-js client with `apikey: SUPABASE_ANON_KEY` + `Authorization: Bearer CRM_RESOLVER_KEY`. PostgREST runs every RPC as `crm_resolver`; the EXECUTE grant (only `get_dispatch_event`, `get_crm_dispatch_context`, `resolve_crm_secret`) is the entire authority boundary. No table access, no BYPASSRLS, never `service_role`.

---

## 7. Minting the `crm_resolver` JWT (`CRM_RESOLVER_KEY`)

The role JWT is HS256-signed with the project's **JWT secret** (Supabase
Dashboard → Project Settings → API → JWT Secret / legacy signing key). It needs a
`role` claim and a bounded `exp`.

```ts
// mint-resolver-jwt.ts  — run: deno run --allow-env mint-resolver-jwt.ts
import { create, getNumericDate } from 'https://deno.land/x/djwt@v3.0.2/mod.ts'

const secret = Deno.env.get('SUPABASE_JWT_SECRET') // project JWT secret (HS256)
if (!secret) throw new Error('set SUPABASE_JWT_SECRET')

const key = await crypto.subtle.importKey(
  'raw',
  new TextEncoder().encode(secret),
  { name: 'HMAC', hash: 'SHA-256' },
  false,
  ['sign', 'verify'],
)

const jwt = await create(
  { alg: 'HS256', typ: 'JWT' },
  {
    role: 'crm_resolver',
    iss: 'crm-sync-dispatch',
    iat: getNumericDate(0),
    exp: getNumericDate(60 * 60 * 24 * 30), // 30 days — rotate before expiry
  },
  key,
)
console.log(jwt)
```

Verify the minted token resolves to the right role (must print `crm_resolver`):

```sql
-- as the project owner, decode is client-side; instead prove the grant boundary:
SELECT
  has_function_privilege('crm_resolver','public.get_dispatch_event(uuid)','EXECUTE')        AS dispatch,  -- t
  has_function_privilege('crm_resolver','public.get_crm_dispatch_context(uuid)','EXECUTE')  AS context,   -- t
  has_function_privilege('crm_resolver','public.resolve_crm_secret(uuid)','EXECUTE')        AS resolve,   -- t
  has_function_privilege('crm_resolver','public.claim_webhook_events(integer)','EXECUTE')   AS claim;     -- f
```

> **Asymmetric-keys caveat:** if the project has migrated Auth to asymmetric JWT
> signing keys, self-signed HS256 role tokens still validate **only** while the
> legacy/shared HS256 secret remains enabled for the project. Keep it enabled, or
> mint with a current symmetric signing key. Confirm with a smoke call (§10).

---

## 8. Rotation procedures

**`CRM_RESOLVER_KEY` (bounded `exp`; also the leaked-key response):**
1. Mint a new token (§7) with a fresh `exp`.
2. `supabase secrets set CRM_RESOLVER_KEY="$NEW" --project-ref "$PROJECT_REF"`.
3. Redeploy (`supabase functions deploy crm-sync-dispatch`) so the new secret loads.
4. Smoke-test (§10). The old token simply expires; no DB change is needed. On suspected compromise, additionally rotate the **project JWT secret** (invalidates all self-signed role tokens) and re-mint.

**`EDGE_DISPATCH_TOKEN`:** rotate in lockstep with N8N's stored credential —
set the new secret, redeploy, then update the N8N HTTP node's `x-dispatch-token`.
Brief overlap is fine (constant-time compare is single-valued; coordinate the cutover).

Never log or commit either value. Rotation cadence: resolver key every ≤30 days
(matches `exp`); dispatch token on staff offboarding or suspected leak.

---

## 9. Deployment sequence

1. **Pre-flight** — confirm migrations v8+v9+v10 applied and the grant boundary (the §7 SQL: resolver has dispatch/context/resolve = `t`, claim = `f`); confirm the JWT auth hook is registered.
2. **Mint** `CRM_RESOLVER_KEY` (§7) and generate `EDGE_DISPATCH_TOKEN` (`openssl rand -hex 32`).
3. **Set secrets** (§5).
4. **Configure the gateway gate** (`verify_jwt = false` for this function, §5).
5. **Deploy:** `supabase functions deploy crm-sync-dispatch --project-ref "$PROJECT_REF"`.
6. **Smoke (no provider):** run the negative + gate tests in §10.
7. **Connect a real GHL integration** (§4) and run one genuinely-claimed event → expect `200 {sent, contact_id}`. This **closes the deferred V8 positive resolver validation**.
8. Hand off to the N8N drain unit (out of scope here).

---

## 10. Verification scripts

```bash
FN="https://$PROJECT_REF.functions.supabase.co/crm-sync-dispatch"
TOK="$EDGE_DISPATCH_TOKEN"

# Auth: missing token → 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$FN" \
  -H 'content-type: application/json' -d '{"event_id":"00000000-0000-0000-0000-000000000000"}'

# Method: GET → 405
curl -sS -o /dev/null -w '%{http_code}\n' "$FN" -H "x-dispatch-token: $TOK"

# Body: non-uuid → 400
curl -sS -X POST "$FN" -H "x-dispatch-token: $TOK" \
  -H 'content-type: application/json' -d '{"event_id":"nope"}'

# Unknown event → 200 {ignored, not_found}
curl -sS -X POST "$FN" -H "x-dispatch-token: $TOK" \
  -H 'content-type: application/json' -d '{"event_id":"00000000-0000-0000-0000-000000000000"}'

# B-1 regression: extra fields ignored (outcome identical to the bare call)
curl -sS -X POST "$FN" -H "x-dispatch-token: $TOK" -H 'content-type: application/json' \
  -d '{"event_id":"00000000-0000-0000-0000-000000000000","integration_id":"x","payload":{"evil":true}}'
```

Secret-hygiene check — no token/secret/PII in logs or responses:

```bash
supabase functions logs crm-sync-dispatch --project-ref "$PROJECT_REF" \
  | grep -Ei 'bearer|authorization|private|pit-|@|password' && echo 'LEAK' || echo 'clean'
```

Static check before deploy: `deno check supabase/functions/crm-sync-dispatch/index.ts`.

---

## 11. Rollback procedure

The function is stateless; all durable writes go through DB RPCs, so rollback is operational.

1. **Stop the trigger first:** pause the N8N drain (no new dispatch calls).
2. **Revert the function:** redeploy the prior version, or `supabase functions delete crm-sync-dispatch`. With no caller and no function, the system returns to "DB layer complete, no runtime" (known-good).
3. **In-flight rows:** any left `processing` are auto-reclaimed by the `claim_webhook_events` 5-minute stale-processing reaper when the drain resumes. (The integration-deleted-mid-flight orphan remains manual SQL — unchanged.)
4. **No DB rollback** is part of this unit (v10 is additive and independently verified). Keep tokens valid; rotate only on suspected compromise.

---

## 12. Logging & observability

Structured, secret-free, PII-free JSON lines keyed by `event_id`: `config_error`,
`unauthorized`, `ignored` (+reason/status), `no_provider`, `no_secret`, `synced`
(+outcome/error_class/provider_status/contact_id), `rpc_error` (+rpc/code),
`unhandled`. Never logged: the dispatch token, resolver key, resolved secret,
provider bodies, request headers, or payload fields (email/phone/name).

---

## 13. Known limits (this unit)

- `private_token` only; `api_key`/`oauth2` deferred (fail closed).
- Standard contact fields + tier/returning tags; `field_mappings` reserved for a later phase.
- N8N drain workflow, `crm-test-connection`, and the frontend sync-health surface are separate units.
- GHL upsert/update response nesting (`contact.id`) is handled defensively; confirm once against a live location during step 7.
