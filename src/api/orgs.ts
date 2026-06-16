import { supabase } from '../lib/supabase'
import type { OrganizationSettings } from '../lib/types'

// READ: explicit columns only — organizations SELECT is column-locked, so never
// `select('*')`. Scoped to the active org id (from the JWT) and guarded by RLS.
export async function getOrganization(orgId: string): Promise<OrganizationSettings | null> {
  const { data, error } = await supabase
    .from('organizations')
    .select('id,name,slug,plan,status,created_at,updated_at')
    .eq('id', orgId)
    .maybeSingle()
  if (error) throw error
  return (data ?? null) as OrganizationSettings | null
}
