// ============================================================
// crm-test-connection — GoHighLevel location-test outcome rules (frozen V6)
//
// Maps a GET /locations/{id} response into a masked { ok, message } outcome:
//
//   success + id matches      → ok:true   "Connection successful."
//   success + id mismatch     → ok:false  (location mismatch)
//   404                       → ok:false  (location not found)
//   401 / 403                 → ok:false  (credential / scope error)
//   timeout / network / 429   → ok:false  (temporary — "try again")
//   5xx                       → ok:false  (temporary — "try again")
//   other                     → ok:false  (unexpected)
//
// No provider body or token ever appears in the message — short fixed strings.
// ============================================================

import { asObject, asString } from './json.ts'
import type { GhlResponse } from './ghl.ts'

export interface TestOutcome {
  ok: boolean
  message: string
}

// GET /locations/{id} → { location: { id, ... } } (or { id }). Defensive read.
function locationIdFrom(body: unknown): string | null {
  const b = asObject(body)
  if (!b) return null
  const loc = asObject(b.location)
  if (loc) {
    const id = asString(loc.id)
    if (id) return id
  }
  return asString(b.id)
}

export function evaluateLocation(res: GhlResponse, expectedLocationId: string): TestOutcome {
  // Temporary / transport failures → retryable message.
  if (res.transport === 'timeout' || res.transport === 'network') {
    return { ok: false, message: 'Could not reach GoHighLevel. Please try again shortly.' }
  }

  if (res.ok) {
    const id = locationIdFrom(res.body)
    if (id && id === expectedLocationId) {
      return { ok: true, message: 'Connection successful.' }
    }
    // Location mismatch — the token authenticates a different location.
    return { ok: false, message: 'This credential is for a different GoHighLevel location.' }
  }

  const s = res.status
  if (s === 401) return { ok: false, message: 'GoHighLevel rejected the credential.' }
  if (s === 403) return { ok: false, message: 'GoHighLevel denied access. Check the token scopes.' }
  if (s === 404) return { ok: false, message: 'The GoHighLevel location was not found.' }
  if (s === 429) {
    return { ok: false, message: 'GoHighLevel is rate-limiting requests. Please try again shortly.' }
  }
  if (s >= 500) {
    return { ok: false, message: 'GoHighLevel is temporarily unavailable. Please try again shortly.' }
  }
  return { ok: false, message: `Unexpected response from GoHighLevel (status ${s}).` }
}
