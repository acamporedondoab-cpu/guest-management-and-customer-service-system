// ============================================================
// crm-test-connection — non-secret dispatch context
//
// get_crm_dispatch_context(integration_id) → routing context keyed by
// integration id (provider/external_account_id/auth_type/status/tag_prefix/
// field_mappings), or null when the id does not exist. crm_resolver EXECUTE.
// Returns NO secret.
//
// Called ONLY after the Increment B ownership gate has proven the caller owns
// this integration — crm_resolver does not enforce ownership itself.
// ============================================================

import type { SupabaseClient } from '@supabase/supabase-js'
import { callRpc } from './db.ts'
import type { DispatchContext } from './types.ts'

export function getCrmDispatchContext(
  db: SupabaseClient,
  integrationId: string,
): Promise<DispatchContext | null> {
  return callRpc<DispatchContext | null>(db, 'get_crm_dispatch_context', {
    p_integration_id: integrationId,
  })
}
