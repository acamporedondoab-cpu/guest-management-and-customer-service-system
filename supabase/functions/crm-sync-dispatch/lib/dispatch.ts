// ============================================================
// crm-sync-dispatch — DB-authoritative dispatch derivation
//
// Thin, typed wrappers over the two crm_resolver RPCs that supply the Edge's
// routing decisions. Both return NON-SECRET data only (verified DB-side).
//
//   • get_dispatch_event(event_id)  — V10. The single read that answers
//       "what event, what status, which integration, what payload" by event_id.
//       The Edge derives EVERYTHING from this, never from the request body (B-1).
//
//   • get_crm_dispatch_context(integration_id) — V9. Re-derives the routing
//       context keyed BY INTEGRATION ID. Used here as a freshness / TOCTOU
//       re-validation immediately before the secret resolve: it confirms the
//       DB-derived integration still exists and re-reads its CURRENT
//       provider/status/auth_type at dispatch time (the integration could have
//       been disabled or deleted in the window between claim and dispatch).
// ============================================================

import type { SupabaseClient } from '@supabase/supabase-js'
import { callRpc } from './db.ts'
import type { DispatchContext, DispatchEvent } from './types.ts'

// get_dispatch_event → { found, status, event_type, organization_id,
//   property_id, integration_id, context, payload }. NEVER a secret.
export function getDispatchEvent(db: SupabaseClient, eventId: string): Promise<DispatchEvent> {
  return callRpc<DispatchEvent>(db, 'get_dispatch_event', { p_event_id: eventId })
}

// get_crm_dispatch_context → the routing context object, or null when the
// integration id no longer exists. NEVER a secret.
export function getCrmDispatchContext(
  db: SupabaseClient,
  integrationId: string,
): Promise<DispatchContext | null> {
  return callRpc<DispatchContext | null>(db, 'get_crm_dispatch_context', {
    p_integration_id: integrationId,
  })
}
