import { supabase } from '../lib/supabase'
import type { GuestSummary } from '../lib/types'

// READ: safe view (guest_summary). PII is sourced from guest_org_profiles and
// rows are scoped to the caller's active org by RLS. No direct guests access.
export async function listGuests(): Promise<GuestSummary[]> {
  const { data, error } = await supabase
    .from('guest_summary')
    .select('*')
    .order('total_visits', { ascending: false })
  if (error) throw error
  return (data ?? []) as GuestSummary[]
}
