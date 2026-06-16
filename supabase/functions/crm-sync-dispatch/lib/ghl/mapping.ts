// ============================================================
// crm-sync-dispatch — payload → GoHighLevel contact mapping
//
// Derives the contact identity + body from the DB-authored event payload
// (handle_new_reservation / handle_reservation_status_change shape):
//
//   payload.guest.email
//   payload.guest_profile.{first_name,last_name,phone,crm_contact_ids.gohighlevel}
//   payload.loyalty.{tier,is_returning}
//
// This phase maps STANDARD contact fields + tags only (field_mappings in the
// context is reserved for a later phase). Tags are prefixed with the
// integration's tag_prefix. No PII is logged; this module only builds the body.
// ============================================================

import { asObject, asString } from '../json.ts'
import type { DispatchContext } from '../types.ts'

// Base contact body (no locationId — added only for create).
export interface ContactBody {
  email: string
  firstName?: string
  lastName?: string
  phone?: string
  tags?: string[]
}

export interface MappedContact {
  email: string | null // null → cannot sync (validation failure upstream)
  existingContactId: string | null // fast-path GHL id, if previously synced
  base: ContactBody | null // null when email is missing
}

export function mapContact(payload: unknown, ctx: DispatchContext): MappedContact {
  const root = asObject(payload) ?? {}
  const guest = asObject(root.guest)
  const profile = asObject(root.guest_profile)
  const loyalty = asObject(root.loyalty)

  const email = guest ? asString(guest.email) : null
  const firstName = profile ? asString(profile.first_name) : null
  const lastName = profile ? asString(profile.last_name) : null
  const phone = profile ? asString(profile.phone) : null

  const crmIds = profile ? asObject(profile.crm_contact_ids) : null
  const existingContactId = crmIds ? asString(crmIds.gohighlevel) : null

  if (email === null) {
    return { email: null, existingContactId, base: null }
  }

  // Tags: tier + returning, each prefixed with the integration tag_prefix.
  const prefix = ctx.tag_prefix ?? ''
  const tier = loyalty ? asString(loyalty.tier) : null
  const isReturning = loyalty ? loyalty.is_returning === true : false
  const tags: string[] = []
  if (tier) tags.push(`${prefix}${tier.toLowerCase()}`)
  if (isReturning) tags.push(`${prefix}returning`)

  const base: ContactBody = { email }
  if (firstName) base.firstName = firstName
  if (lastName) base.lastName = lastName
  if (phone) base.phone = phone
  if (tags.length > 0) base.tags = tags

  return { email, existingContactId, base }
}
