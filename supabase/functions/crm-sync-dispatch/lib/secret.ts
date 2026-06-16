// ============================================================
// crm-sync-dispatch — server-side secret resolution
//
// resolve_crm_secret(integration_id) → the decrypted GoHighLevel private_token,
// or NULL when the integration has no Vault secret. crm_resolver holds the
// EXECUTE grant (V9); the vault schema is never REST-exposed.
//
// The returned value is the live secret. It is handled in-memory ONLY: it is
// never logged, never returned to the caller, and never passed anywhere except
// (in a later increment) the GoHighLevel Authorization header. This module does
// no presence-coercion beyond mapping null/blank → null so the caller can
// classify `no_secret` cleanly without inspecting the value.
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
  // null / empty / whitespace-only → treat as "no secret configured".
  if (typeof secret !== 'string' || secret.trim().length === 0) return null
  return secret
}
