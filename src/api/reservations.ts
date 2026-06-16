import { supabase } from '../lib/supabase'
import type { ReservationDetail, UpsertGuestArgs, CreateReservationArgs } from '../lib/types'

// READ: safe view (reservation_detail). Org-scoped by RLS; guest name comes
// from guest_org_profiles. No direct reservations access.
export async function listReservations(limit = 100): Promise<ReservationDetail[]> {
  const { data, error } = await supabase
    .from('reservation_detail')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(limit)
  if (error) throw error
  return (data ?? []) as ReservationDetail[]
}

// WRITE (RPC-only). upsert_guest() is the sole authenticated write path into
// guests; it creates/finds the guest by email and ensures a guest_org_profiles
// row for the caller's JWT org. Org id is taken from the JWT, never an argument.
// Returns the guest id. Direct INSERT on guests is revoked (RT-A1/RT-B2).
export async function upsertGuest(args: UpsertGuestArgs): Promise<string> {
  // `args as never`: the typed-client rpc() arg inference collapses to `never`
  // because the Database generic's Row *interfaces* don't satisfy supabase-js's
  // GenericSchema (Record<string, unknown>) constraint. The wrapper's parameter
  // type (UpsertGuestArgs) is the real, enforced contract for callers.
  const { data, error } = await supabase.rpc('upsert_guest', args as never)
  if (error) throw error
  return data as string
}

// WRITE (RPC-only). create_reservation() is the sole authenticated insert path
// into reservations (direct INSERT is revoked, RT-B2). It binds guest_id and
// property_id to the caller's JWT org and enforces the write-role + property
// scope. The guest must already exist in the org (call upsertGuest first).
// Returns the reservation id; the AFTER INSERT loyalty trigger fires server-side.
export async function createReservation(args: CreateReservationArgs): Promise<string> {
  // See upsertGuest for why `args as never` is required; the CreateReservationArgs
  // parameter type is the enforced contract for callers.
  const { data, error } = await supabase.rpc('create_reservation', args as never)
  if (error) throw error
  return data as string
}
