// ============================================================
// crm-test-connection — environment validation
//
// Fail-closed at cold start. NOTE the auth model difference vs crm-sync-dispatch:
// this function is called by the BROWSER with the owner's Supabase session JWT,
// so there is NO shared dispatch token / no EDGE_*_TOKEN. The inbound caller is
// authenticated by their user JWT (gateway verify_jwt=true) plus an owner +
// ownership gate (later increment). The only secret here is CRM_RESOLVER_KEY,
// used (later) to resolve the CRM secret server-side AFTER ownership is proven.
//
// GHL host/version are pinned constants (B5) with optional env overrides — the
// host is never request-derived.
// ============================================================

export interface Env {
  // Postgres (PostgREST) access. crm_resolver is used (later) for the secret
  // resolve/context reads; a user-scoped client (built per-request from the
  // caller's JWT) handles the ownership check in the gate increment.
  supabaseUrl: string
  anonKey: string
  resolverKey: string // SECRET — crm_resolver role JWT (bounded exp)
  // GoHighLevel host pin (B5). Defaults; env may pin, request body never can.
  ghlApiBase: string
  ghlApiVersion: string
}

const GHL_API_BASE_DEFAULT = 'https://services.leadconnectorhq.com'
const GHL_API_VERSION_DEFAULT = '2021-07-28'

function required(name: string): string {
  const v = Deno.env.get(name)
  if (v === undefined || v.trim() === '') {
    // Name only — never the value.
    throw new Error(`crm-test-connection misconfigured: missing required env ${name}`)
  }
  return v
}

function optional(name: string, fallback: string): string {
  const v = Deno.env.get(name)
  return v === undefined || v.trim() === '' ? fallback : v
}

let cached: Env | null = null

export function getEnv(): Env {
  if (cached) return cached
  cached = Object.freeze({
    supabaseUrl: required('SUPABASE_URL'),
    anonKey: required('SUPABASE_ANON_KEY'),
    resolverKey: required('CRM_RESOLVER_KEY'),
    ghlApiBase: optional('GHL_API_BASE', GHL_API_BASE_DEFAULT),
    ghlApiVersion: optional('GHL_API_VERSION', GHL_API_VERSION_DEFAULT),
  })
  return cached
}
