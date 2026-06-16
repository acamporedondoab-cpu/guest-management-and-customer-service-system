// ============================================================
// crm-sync-dispatch — environment validation
//
// Fail-closed at cold start. The function must NEVER run partially configured:
// a missing secret means it cannot authenticate to Postgres or verify its
// caller, so we surface a clear, secret-free error and let the platform 500.
//
// SECRETS handled here (read, never logged): CRM_RESOLVER_KEY (the crm_resolver
// role JWT) and EDGE_DISPATCH_TOKEN (the N8N → Edge proof). GHL host/version are
// pinned constants with optional env overrides — the host is NEVER caller-
// supplied (B5).
// ============================================================

export interface Env {
  // Postgres (PostgREST) access as the crm_resolver role.
  supabaseUrl: string
  anonKey: string
  resolverKey: string // SECRET — crm_resolver role JWT (bounded exp)
  // Inbound caller authentication.
  dispatchToken: string // SECRET — constant-time compared, never echoed
  // GoHighLevel host pin (B5). Defaulted constants; env may pin, body never can.
  ghlApiBase: string
  ghlApiVersion: string
}

// GHL defaults — server constants. Used unless explicitly overridden by env.
// The host is intentionally hardcoded so it can never originate from a request.
const GHL_API_BASE_DEFAULT = 'https://services.leadconnectorhq.com'
const GHL_API_VERSION_DEFAULT = '2021-07-28'

function required(name: string): string {
  const v = Deno.env.get(name)
  if (v === undefined || v.trim() === '') {
    // Name only — never the value, and never which secret store it came from.
    throw new Error(`crm-sync-dispatch misconfigured: missing required env ${name}`)
  }
  return v
}

function optional(name: string, fallback: string): string {
  const v = Deno.env.get(name)
  return v === undefined || v.trim() === '' ? fallback : v
}

// Validate + freeze once at module load. Throwing here aborts the cold start,
// so no request is ever served by a half-configured instance.
let cached: Env | null = null

export function getEnv(): Env {
  if (cached) return cached
  cached = Object.freeze({
    supabaseUrl: required('SUPABASE_URL'),
    anonKey: required('SUPABASE_ANON_KEY'),
    resolverKey: required('CRM_RESOLVER_KEY'),
    dispatchToken: required('EDGE_DISPATCH_TOKEN'),
    ghlApiBase: optional('GHL_API_BASE', GHL_API_BASE_DEFAULT),
    ghlApiVersion: optional('GHL_API_VERSION', GHL_API_VERSION_DEFAULT),
  })
  return cached
}
