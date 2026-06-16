// ============================================================
// crm-test-connection — integration ownership validation
//
// Loads the target integration through the caller's USER-scoped client, so RLS
// (security_invoker on crm_integrations_safe, owner/manager only) is the first
// gate: a row is returned only if the caller's org owns it. The caller then
// additionally asserts the row's organization_id equals the verified claim
// (defense-in-depth against any RLS/claim drift). Reads NON-SECRET columns only.
// ============================================================

import type { SupabaseClient } from '@supabase/supabase-js'
import { asObject, asString } from './json.ts'

export type OwnershipStatus = 'ok' | 'missing' | 'error'

export interface OwnershipResult {
  status: OwnershipStatus
  organizationId?: string
}

export async function loadIntegrationForCaller(
  userClient: SupabaseClient,
  integrationId: string,
): Promise<OwnershipResult> {
  // maybeSingle: 0 rows → data null (not visible / does not exist); id is PK so
  // never >1. Non-secret columns only.
  const { data, error } = await userClient
    .from('crm_integrations_safe')
    .select('id, organization_id')
    .eq('id', integrationId)
    .maybeSingle()

  if (error) return { status: 'error' }
  if (!data) return { status: 'missing' }

  const row = asObject(data)
  const organizationId = row ? asString(row.organization_id) : null
  if (!organizationId) return { status: 'error' }

  return { status: 'ok', organizationId }
}
