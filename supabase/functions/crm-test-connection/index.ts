// ============================================================
// crm-test-connection — Edge Function entrypoint
//
// INCREMENT A scope: cold-start env validation, method gate, structural Bearer
// JWT validation, strict { integration_id } body parse, and crm_resolver DB
// client construction. Returns the frozen V6 { ok, message, checkedAt } contract.
//
// NOT YET IMPLEMENTED (later increments): the owner + integration-belongs-to-org
// gate (via a user-scoped client over crm_integrations_safe), the crm_resolver
// secret resolve / get_crm_dispatch_context reads, and the GoHighLevel ping.
// Until then the test path returns a classified `not_implemented`.
//
// AUTH MODEL: owner's Supabase session JWT (gateway verify_jwt=true). No shared
// constant-time token — see lib/auth.ts.
//
// Logging policy: structured, secret-free, PII-free. We never log the JWT, the
// resolver key, the (future) resolved secret, request headers, or provider data.
// ============================================================

import { getEnv } from './lib/env.ts'
import { extractBearerJwt } from './lib/auth.ts'
import { getResolverClient, getUserClient, RpcError } from './lib/db.ts'
import { readVerifiedClaims } from './lib/claims.ts'
import { loadIntegrationForCaller } from './lib/ownership.ts'
import { getCrmDispatchContext } from './lib/context.ts'
import { resolveCrmSecret } from './lib/secret.ts'
import { GhlClient } from './lib/ghl.ts'
import { evaluateLocation } from './lib/validate.ts'
import type { TestConnectionRequest, TestConnectionResponse } from './lib/types.ts'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// CORS: this function is called from the browser (owner CRM UI), so it must
// answer the preflight and echo CORS headers on every response. Authorization
// is a Bearer header (not a cookie), so the request is not credentialed and a
// wildcard origin is valid — CORS does not weaken auth, which is enforced by the
// gateway + owner/ownership gate regardless of origin.
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Max-Age': '86400',
}

// { ok, message, checkedAt } envelope. Success-shaped results use 200; faults
// use a non-2xx status (the frozen frontend throws on non-ok and shows a
// friendly error). The body is always secret-free. CORS headers are applied to
// every response so the browser can read it.
function result(ok: boolean, message: string, status: number): Response {
  const body: TestConnectionResponse = { ok, message, checkedAt: new Date().toISOString() }
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...CORS_HEADERS },
  })
}

// Secret-free structured log line.
function log(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ fn: 'crm-test-connection', ...fields }))
}

Deno.serve(async (req: Request): Promise<Response> => {
  // 0. CORS preflight — answer OPTIONS before any gate (preflight carries no
  //    Authorization and must succeed regardless of config). Empty body, CORS
  //    headers only.
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: CORS_HEADERS })
  }

  // Validate configuration up front. A misconfigured instance must not serve.
  let env
  try {
    env = getEnv()
  } catch (_e) {
    // _e carries only the missing-var NAME (env.ts guarantees no secret value).
    log({ event: 'config_error' })
    return result(false, 'Connection testing is not correctly configured.', 500)
  }

  // 1. Method gate.
  if (req.method !== 'POST') {
    return result(false, 'Method not allowed.', 405)
  }

  // 2. Caller auth gate — structural Bearer JWT (owner session token). The
  //    gateway verifies the signature; the owner + ownership gate is a later
  //    increment. The token is never logged.
  const jwt = extractBearerJwt(req)
  if (jwt === null) {
    log({ event: 'unauthorized' })
    return result(false, 'Unauthorized.', 401)
  }

  // 3. Strict body parse — { integration_id: <uuid> }.
  let request: TestConnectionRequest
  try {
    const raw = (await req.json()) as unknown
    const integrationId = (raw as { integration_id?: unknown })?.integration_id
    if (typeof integrationId !== 'string' || !UUID_RE.test(integrationId)) {
      return result(false, 'Request body must be { integration_id: <uuid> }.', 400)
    }
    request = { integration_id: integrationId }
  } catch (_e) {
    return result(false, 'Request body must be valid JSON.', 400)
  }

  // 4. Verified-claims authorization (SOURCE OF TRUTH). getClaims verifies the
  //    token and yields the hook-enriched app_metadata (org_id/user_role/user_id).
  const claims = await readVerifiedClaims(env, jwt)
  if (claims === null) {
    log({ event: 'unauthorized', reason: 'claims' })
    return result(false, 'Unauthorized.', 401)
  }

  // 5. Owner-only. Managers (visible to RLS) are rejected here, before any read.
  if (claims.userRole !== 'owner') {
    log({ event: 'forbidden', reason: 'not_owner', org_id: claims.orgId })
    return result(false, 'Only owners can test CRM connections.', 403)
  }

  // 6. Ownership: load the integration via the caller's RLS-scoped client and
  //    confirm it belongs to the caller's org. RLS is the first gate; the
  //    explicit org match is defense-in-depth. Missing OR cross-org → 404 with
  //    an IDENTICAL response (never reveal that an id exists in another org).
  const userClient = getUserClient(env, jwt)
  const owned = await loadIntegrationForCaller(userClient, request.integration_id)
  if (owned.status === 'error') {
    log({ event: 'ownership_error', integration_id: request.integration_id })
    return result(false, 'Unable to verify the integration.', 500)
  }
  if (owned.status === 'missing' || owned.organizationId !== claims.orgId) {
    log({ event: 'not_found', integration_id: request.integration_id, org_id: claims.orgId })
    return result(false, 'Integration not found.', 404)
  }

  // 7. Resolver path (crm_resolver). Ownership is proven, so we may now read the
  //    non-secret routing context, validate it, and resolve the secret. The
  //    secret is held in-memory only and dropped in `finally` — never logged,
  //    returned, or persisted. Validation failures return a masked ok:false
  //    result (a legitimate "can't test this" outcome), not a fault.
  const resolver = getResolverClient(env)
  let secret: string | null = null
  try {
    const context = await getCrmDispatchContext(resolver, request.integration_id)
    if (!context) {
      return result(false, 'GoHighLevel integration is not available.', 200)
    }
    if (context.provider !== 'gohighlevel') {
      return result(false, 'Only GoHighLevel connections can be tested.', 200)
    }
    if (context.status !== 'active') {
      return result(false, 'Integration is not active.', 200)
    }
    if (context.auth_type !== 'private_token') {
      return result(false, 'Only private token authentication can be tested.', 200)
    }
    // A location id is required to validate the token against GoHighLevel. Gate
    // before resolving the secret — never resolve for an un-testable integration.
    if (!context.external_account_id) {
      return result(false, 'No GoHighLevel location is configured for this integration.', 200)
    }
    const locationId = context.external_account_id

    secret = await resolveCrmSecret(resolver, request.integration_id)
    if (secret === null) {
      return result(false, 'No credential is configured for this integration.', 200)
    }

    // 8. GoHighLevel connection validation. Host is the pinned server constant;
    //    the token is used ONLY here and dropped in `finally`. GET /locations/{id}
    //    validates the credential against the configured location. Every test
    //    outcome is a masked 200 { ok, message } (frozen V6 rules).
    const ghl = new GhlClient(env.ghlApiBase, env.ghlApiVersion, secret)
    const res = await ghl.getLocation(locationId)
    const outcome = evaluateLocation(res, locationId)
    log({
      event: 'tested',
      integration_id: request.integration_id,
      org_id: claims.orgId,
      ok: outcome.ok,
      provider_status: res.status,
      transport: res.transport,
    })
    return result(outcome.ok, outcome.message, 200)
  } catch (e) {
    if (e instanceof RpcError) {
      log({ event: 'rpc_error', rpc: e.rpc, code: e.code, integration_id: request.integration_id })
    } else {
      log({ event: 'unhandled', integration_id: request.integration_id })
    }
    return result(false, 'Unable to verify the integration.', 500)
  } finally {
    secret = null
  }
})
