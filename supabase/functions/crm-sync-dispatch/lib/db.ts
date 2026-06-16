// ============================================================
// crm-sync-dispatch — Postgres (PostgREST) client factory
//
// Builds a supabase-js client that authenticates to Postgres as the
// crm_resolver role. PostgREST runs every RPC under that role, so the EXECUTE
// grant is the ENTIRE authority boundary: crm_resolver may execute only
// get_dispatch_event / resolve_crm_secret / get_crm_dispatch_context, and has
// no table access and no BYPASSRLS.
//
// service_role is intentionally NEVER used here (the locked Phase 3 decision).
//
// Headers:
//   apikey:        SUPABASE_ANON_KEY  (PostgREST gateway key)
//   Authorization: Bearer CRM_RESOLVER_KEY  (the crm_resolver role JWT)
//
// Session persistence / auto-refresh are disabled — this is a stateless,
// per-request server identity, not a user session.
// ============================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Env } from './env.ts'

// One client per cold start is safe: the identity is fixed (crm_resolver) and
// carries no per-request user context. Memoized to avoid rebuilding per call.
let cached: SupabaseClient | null = null

export function getDbClient(env: Env): SupabaseClient {
  if (cached) return cached
  cached = createClient(env.supabaseUrl, env.anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      headers: {
        Authorization: `Bearer ${env.resolverKey}`,
      },
    },
  })
  return cached
}

// Thrown when an RPC returns a PostgREST error. Carries only the function name
// and the Postgres error code (both non-sensitive) — never the secret, the
// args, or a raw error body. The caller maps this to a generic `internal`.
export class RpcError extends Error {
  constructor(readonly rpc: string, readonly code?: string) {
    super(`rpc ${rpc} failed`)
    this.name = 'RpcError'
  }
}

// Single funnel for every RPC the Edge makes as crm_resolver. Keeps error
// handling uniform and ensures no RPC arg/body is ever surfaced or logged.
// The client is untyped (no Database generic), so args need no `as never`.
export async function callRpc<T>(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw new RpcError(fn, error.code)
  return data as T
}
