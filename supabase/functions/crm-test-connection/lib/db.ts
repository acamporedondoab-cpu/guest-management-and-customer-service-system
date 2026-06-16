// ============================================================
// crm-test-connection — Postgres (PostgREST) client factory
//
// crm_resolver client: authenticates to Postgres as the crm_resolver role for
// the (later) secret resolve/context reads. The EXECUTE grant is the entire
// authority boundary (resolve_crm_secret + get_crm_dispatch_context only); no
// table access, no BYPASSRLS, never service_role.
//
// IMPORTANT ordering (gate increment): crm_resolver does NOT enforce ownership.
// The owner + integration-belongs-to-org check must run FIRST, via a per-request
// USER-scoped client built from the caller's JWT (RLS-gated read of
// crm_integrations_safe). That user-scoped client is added in the gate
// increment; Increment A provides only the crm_resolver factory.
// ============================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Env } from './env.ts'

let cached: SupabaseClient | null = null

export function getResolverClient(env: Env): SupabaseClient {
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

// Per-request USER-scoped client: authenticates to PostgREST as the caller using
// their session JWT, so RLS runs in the caller's context (owner/manager
// visibility on crm_integrations_safe). NOT cached — the identity is per-request.
// This is the ownership-gate client; it never resolves secrets.
export function getUserClient(env: Env, jwt: string): SupabaseClient {
  return createClient(env.supabaseUrl, env.anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      headers: {
        Authorization: `Bearer ${jwt}`,
      },
    },
  })
}

// Thrown when an RPC returns a PostgREST error. Carries only the function name
// and the Postgres error code — never the secret, args, or a raw error body.
export class RpcError extends Error {
  constructor(readonly rpc: string, readonly code?: string) {
    super(`rpc ${rpc} failed`)
    this.name = 'RpcError'
  }
}

// Single funnel for crm_resolver RPCs. The resolver client is untyped, so args
// need no `as never`.
export async function callRpc<T>(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw new RpcError(fn, error.code)
  return data as T
}
