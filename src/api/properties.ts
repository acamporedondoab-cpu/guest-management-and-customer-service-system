import { supabase } from '../lib/supabase'
import type { Property } from '../lib/types'

// READ: properties table (no safe view needed — no secret columns). Explicit
// column list; rows scoped to the caller's org + property scope by RLS.
export async function listProperties(): Promise<Property[]> {
  const { data, error } = await supabase
    .from('properties')
    .select('id,organization_id,name,location,status,created_at,updated_at')
    .order('name', { ascending: true })
  if (error) throw error
  return (data ?? []) as Property[]
}
