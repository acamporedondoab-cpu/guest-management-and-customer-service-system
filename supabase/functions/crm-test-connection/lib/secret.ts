// ============================================================
// crm-test-connection — server-side secret resolution
//
// resolve_crm_secret(integration_id) → the decrypted GoHighLevel private_token,
// or null when no Vault secret is configured. crm_resolver EXECUTE; the vault
// schema is never REST-exposed.
//
// The returned value is the live secret. It is handled in-memory ONLY: never
// logged, never returned to the caller, never persisted. Called ONLY after the
// ownership gate (Increment B) and context validation have passed.
// ============================================================

import type { SupabaseClient } from '@supabase/supabase-js'
import { callRpc } from './db.ts'

export async function resolveCrmSecret(
  db: SupabaseClient,
  integrationId: string,
): Promise<string | null> {
  const secret = await callRpc<string | null>(db, 'resolve_crm_secret', {
    p_integration_id: integrationId,
  })
  if (typeof secret !== 'string' || secret.trim().length === 0) return null
  return secret
}
