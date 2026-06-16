// ============================================================
// crm-test-connection — verified JWT claims (authorization source of truth)
//
// Uses supabase-js getClaims() to CRYPTOGRAPHICALLY VERIFY the caller's session
// JWT and return its payload, then reads the custom claims the
// custom_access_token_hook writes into app_metadata: org_id / user_role /
// user_id. These — not anything in the request body — drive the owner +
// ownership gate.
//
// Returns null on any failure (invalid/unverifiable token, hook not applied, or
// a missing/blank required claim) so the caller fails closed with 401. The token
// value is never logged.
// ============================================================

import { createClient } from '@supabase/supabase-js'
import type { Env } from './env.ts'
import type { CallerClaims } from './types.ts'
import { asObject, asString } from './json.ts'

export async function readVerifiedClaims(env: Env, jwt: string): Promise<CallerClaims | null> {
  // A bare client is sufficient: getClaims verifies the passed token against the
  // project signing keys independent of any client auth state.
  const client = createClient(env.supabaseUrl, env.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  })

  const { data, error } = await client.auth.getClaims(jwt)
  if (error || !data?.claims) return null

  const claims = asObject(data.claims)
  if (!claims) return null

  const appMeta = asObject(claims.app_metadata)
  if (!appMeta) return null

  const orgId = asString(appMeta.org_id)
  const userRole = asString(appMeta.user_role)
  const userId = asString(appMeta.user_id)
  if (!orgId || !userRole || !userId) return null

  return { orgId, userRole, userId }
}
