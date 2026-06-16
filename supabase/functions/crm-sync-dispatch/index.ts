// ============================================================
// crm-sync-dispatch — Edge Function entrypoint
//
// INCREMENT B scope: cold-start env validation, method gate, caller auth gate,
// strict { event_id } body parse, crm_resolver DB client, and the full
// DB-authoritative dispatch pipeline up to (and including) secret resolution:
//
//   get_dispatch_event → found/status/provider/existence gates
//     → get_crm_dispatch_context (freshness re-validation)
//     → auth_type gate → resolve_crm_secret
//
// NOT YET IMPLEMENTED (later increments): the GoHighLevel client and contact
// sync. Once the secret resolves, the function discards it and returns a
// classified `not_implemented` so the entire DB path is testable without a
// provider dependency.
//
// Identity model (see auth.ts / db.ts):
//   • Inbound:  EDGE_DISPATCH_TOKEN  — proves N8N called us (no DB authority).
//   • Outbound: CRM_RESOLVER_KEY     — crm_resolver role JWT; EXECUTE grant is
//                                      the authority boundary. Never service_role.
//
// Logging policy (§11): structured, secret-free, PII-free. We never log the
// dispatch token, the resolver key, the resolved secret, request headers, or
// payload contents — only event_id, integration_id (uuids), outcome, status.
// ============================================================

import { getEnv, type Env } from './lib/env.ts'
import { isAuthorized } from './lib/auth.ts'
import { getDbClient, RpcError } from './lib/db.ts'
import { getCrmDispatchContext, getDispatchEvent } from './lib/dispatch.ts'
import { resolveCrmSecret } from './lib/secret.ts'
import { GhlClient } from './lib/ghl/client.ts'
import { syncContact } from './lib/ghl/contacts.ts'
import type {
  DispatchRequest,
  DispatchResponse,
  ErrorClass,
  Outcome,
} from './lib/types.ts'
import type { SupabaseClient } from '@supabase/supabase-js'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// Masked envelope builder. Classified outcomes ride on HTTP 200; pre-
// classification faults (auth/parse/method/internal) use a non-2xx status so
// N8N can branch on transport vs. outcome cleanly.
function envelope(
  body: Partial<DispatchResponse> & { outcome: Outcome; message: string },
  status: number,
): Response {
  const full: DispatchResponse = {
    event_id: body.event_id ?? null,
    outcome: body.outcome,
    integration_id: body.integration_id ?? null,
    contact_id: body.contact_id ?? null,
    error_class: body.error_class ?? null,
    retry_after_seconds: body.retry_after_seconds ?? null,
    provider_status: body.provider_status ?? null,
    message: body.message,
  }
  return new Response(JSON.stringify(full), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function fault(outcome: Outcome, errorClass: ErrorClass, message: string, status: number): Response {
  return envelope({ outcome, error_class: errorClass, message }, status)
}

// Secret-free structured log line. Only ever called with non-sensitive fields.
function log(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ fn: 'crm-sync-dispatch', ...fields }))
}

// DB-authoritative dispatch pipeline. Returns a classified Response. Throws only
// RpcError (mapped to `internal` by the caller). Holds the resolved secret in a
// single local binding that is dropped before return.
async function runDispatch(env: Env, db: SupabaseClient, request: DispatchRequest): Promise<Response> {
  const eventId = request.event_id

  // ── get_dispatch_event: the sole source of routing/payload (B-1) ──
  const event = await getDispatchEvent(db, eventId)

  // found gate — unknown id. Terminal, no `complete` from N8N.
  if (!event.found) {
    log({ event: 'ignored', reason: 'not_found', event_id: eventId })
    return envelope(
      { event_id: eventId, outcome: 'ignored', error_class: 'not_found', message: 'Event not found.' },
      200,
    )
  }

  // status gate — act ONLY on a genuinely-claimed, in-flight event. Idempotent:
  // a re-fired token against a non-processing event is a clean no-op.
  if (event.status !== 'processing') {
    log({ event: 'ignored', reason: 'not_claimed', event_id: eventId, status: event.status })
    return envelope(
      {
        event_id: eventId,
        outcome: 'ignored',
        error_class: 'not_claimed',
        message: 'Event is not in a processing state.',
      },
      200,
    )
  }

  // integration existence gate — org has no GoHighLevel integration row.
  // integration_id is null on the response so N8N passes p_integration_id=NULL
  // to complete_webhook_event (F6-safe; no cross-tenant write).
  if (!event.integration_id) {
    log({ event: 'no_provider', reason: 'no_integration', event_id: eventId })
    return envelope(
      {
        event_id: eventId,
        outcome: 'no_provider',
        error_class: 'no_provider',
        message: 'No GoHighLevel integration for this organization.',
      },
      200,
    )
  }

  const integrationId = event.integration_id

  // ── get_crm_dispatch_context: freshness re-validation BY integration_id ──
  // Re-confirms the integration still exists and reads its CURRENT provider/
  // status/auth_type at dispatch time (closes the claim→dispatch TOCTOU window).
  const context = await getCrmDispatchContext(db, integrationId)

  // Disappeared between fold and now → treat as no_provider (integration_id null).
  if (!context) {
    log({ event: 'no_provider', reason: 'integration_vanished', event_id: eventId })
    return envelope(
      {
        event_id: eventId,
        outcome: 'no_provider',
        error_class: 'no_provider',
        message: 'GoHighLevel integration no longer exists.',
      },
      200,
    )
  }

  // provider gate — defensive; the DB lookups already filter gohighlevel.
  if (context.provider !== 'gohighlevel') {
    log({ event: 'failed', reason: 'wrong_provider', event_id: eventId })
    return envelope(
      {
        event_id: eventId,
        outcome: 'failed',
        integration_id: integrationId,
        error_class: 'validation',
        message: 'Integration is not a GoHighLevel provider.',
      },
      200,
    )
  }

  // active gate — disabled/non-active integration is a non-retryable validation
  // failure (real integration_id; `validation` never flips integration health).
  if (context.status !== 'active') {
    log({ event: 'failed', reason: 'inactive_integration', event_id: eventId, status: context.status })
    return envelope(
      {
        event_id: eventId,
        outcome: 'failed',
        integration_id: integrationId,
        error_class: 'validation',
        message: 'Integration is not active.',
      },
      200,
    )
  }

  // auth_type gate — this phase supports private_token ONLY. api_key/oauth2/none
  // are deferred and fail closed BEFORE any secret resolve or provider call.
  if (context.auth_type !== 'private_token') {
    log({ event: 'failed', reason: 'unsupported_auth_type', event_id: eventId, auth_type: context.auth_type })
    return envelope(
      {
        event_id: eventId,
        outcome: 'failed',
        integration_id: integrationId,
        error_class: 'validation',
        message: 'Only private_token authentication is supported.',
      },
      200,
    )
  }

  // ── resolve_crm_secret: server-side only; secret held in-memory, never logged ──
  let secret: string | null = await resolveCrmSecret(db, integrationId)

  // No Vault secret configured → no_secret (integration_id null; N8N skips a
  // health write, F6-safe).
  if (secret === null) {
    log({ event: 'no_secret', event_id: eventId })
    return envelope(
      {
        event_id: eventId,
        outcome: 'no_secret',
        error_class: 'no_secret',
        message: 'No credential is configured for this integration.',
      },
      200,
    )
  }

  // ── GoHighLevel contact sync (private_token; hardcoded host) ──
  // The secret lives only inside the client for the duration of this block and
  // is dropped in `finally` regardless of outcome. The result is masked: it
  // carries a contact_id / error_class but never the secret or a provider body.
  try {
    const client = new GhlClient(env.ghlApiBase, env.ghlApiVersion, secret)
    const result = await syncContact(client, context, event.payload ?? null)
    log({
      event: 'synced',
      event_id: eventId,
      integration_id: integrationId,
      outcome: result.outcome,
      error_class: result.errorClass,
      provider_status: result.providerStatus,
      contact_id: result.contactId,
    })
    return envelope(
      {
        event_id: eventId,
        outcome: result.outcome,
        integration_id: integrationId,
        contact_id: result.contactId,
        error_class: result.errorClass,
        retry_after_seconds: result.retryAfterSeconds,
        provider_status: result.providerStatus,
        message: result.message,
      },
      200,
    )
  } finally {
    secret = null
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  // Validate configuration up front. A misconfigured instance must not serve.
  let env
  try {
    env = getEnv()
  } catch (_e) {
    // _e carries only the missing-var NAME (env.ts guarantees no secret value).
    log({ event: 'config_error' })
    return fault('failed', 'internal', 'Function is not correctly configured.', 500)
  }

  // 1. Method gate.
  if (req.method !== 'POST') {
    return fault('failed', 'method_not_allowed', 'Method not allowed.', 405)
  }

  // 2. Caller auth gate (constant-time; presented token never logged/echoed).
  if (!(await isAuthorized(req, env.dispatchToken))) {
    log({ event: 'unauthorized' })
    return fault('failed', 'unauthorized', 'Unauthorized.', 401)
  }

  // 3. Strict body parse — { event_id } ONLY. Any other field is ignored (B-1:
  //    routing is derived DB-side from event_id, never trusted from the body).
  let request: DispatchRequest
  try {
    const raw = (await req.json()) as unknown
    const eventId = (raw as { event_id?: unknown })?.event_id
    if (typeof eventId !== 'string' || !UUID_RE.test(eventId)) {
      return fault('failed', 'bad_request', 'Request body must be { event_id: <uuid> }.', 400)
    }
    request = { event_id: eventId }
  } catch (_e) {
    return fault('failed', 'bad_request', 'Request body must be valid JSON.', 400)
  }

  // 4. crm_resolver DB client + DB-authoritative dispatch pipeline.
  const db = getDbClient(env)
  try {
    return await runDispatch(env, db, request)
  } catch (e) {
    if (e instanceof RpcError) {
      // rpc name + Postgres code only — both non-sensitive.
      log({ event: 'rpc_error', rpc: e.rpc, code: e.code, event_id: request.event_id })
    } else {
      log({ event: 'unhandled', event_id: request.event_id })
    }
    return fault('failed', 'internal', 'Internal error.', 500)
  }
})
