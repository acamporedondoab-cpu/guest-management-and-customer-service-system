// ============================================================
// crm-sync-dispatch — GoHighLevel contact upsert (native-upsert strategy)
//
// Two-step flow (fast-path failures are NON-TERMINAL):
//
//   1. Fast path — if the payload carries a known gohighlevel contact id,
//      PUT update it by id. 404 (stale id) → fall through (non-fatal, never
//      flips integration health). Other failures → classify.
//
//   2. Native upsert — POST /contacts/upsert with locationId. GHL match-or-
//      creates by email/phone per the location's "Allow Duplicate Contact"
//      setting and returns the contact id. This delegates deduplication to
//      GoHighLevel: the Edge performs no email search and handles no
//      duplicate-create response (no dependency on undocumented shapes).
//
// Identity = email within external_account_id (the GHL locationId). Email is
// required; locationId is required for the upsert step (an existing-id update
// can succeed without it). Returns a masked GhlSyncResult; the secret never
// appears.
// ============================================================

import { asObject, asString } from '../json.ts'
import type { DispatchContext, GhlSyncResult } from '../types.ts'
import type { GhlClient } from './client.ts'
import { mapContact } from './mapping.ts'
import { classifyProviderFailure, failed, sent } from './classify.ts'

// Pull a contact id out of an update/upsert response: { contact: { id } } or { id }.
function contactIdFrom(body: unknown): string | null {
  const b = asObject(body)
  if (!b) return null
  const contact = asObject(b.contact)
  if (contact) {
    const id = asString(contact.id)
    if (id) return id
  }
  return asString(b.id)
}

export async function syncContact(
  client: GhlClient,
  ctx: DispatchContext,
  payload: unknown,
): Promise<GhlSyncResult> {
  const mapped = mapContact(payload, ctx)
  if (mapped.email === null || mapped.base === null) {
    return failed('validation', null, 'Event payload has no guest email to sync.')
  }
  const locationId = asString(ctx.external_account_id)

  // ── 1. Fast path: update a previously-synced contact by id ──
  if (mapped.existingContactId) {
    const res = await client.updateContact(mapped.existingContactId, mapped.base)
    if (res.ok) return sent(mapped.existingContactId)
    if (res.status !== 404) return classifyProviderFailure(res) // stale id → upsert
  }

  // ── 2. Native upsert (requires a location) ──
  if (locationId === null) {
    return failed('validation', null, 'Integration has no GoHighLevel location id.')
  }

  const upserted = await client.upsertContact({ ...mapped.base, locationId })
  if (upserted.ok) {
    const id = contactIdFrom(upserted.body)
    if (id) return sent(id)
    // Upsert succeeded but no id parsed — surface as a non-flapping failure.
    return failed('provider_validation', upserted.status, 'GoHighLevel upsert returned no contact id.')
  }

  return classifyProviderFailure(upserted)
}
