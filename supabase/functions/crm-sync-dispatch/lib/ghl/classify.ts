// ============================================================
// crm-sync-dispatch — GoHighLevel outcome classification (matrix §8)
//
// Maps a GHL transport/status into a masked GhlSyncResult. The taxonomy:
//
//   transport timeout/network   → retry  / provider_unavailable
//   2xx                         → sent   (built by the caller, not here)
//   401                         → failed / auth          (N8N marks health)
//   403                         → failed / forbidden      (N8N marks health)
//   429                         → retry  / rate_limited    (+ retry_after)
//   5xx                         → retry  / provider_unavailable (+ retry_after)
//   400 / 422                   → failed / provider_validation
//   other 4xx                   → failed / provider_validation
//
// Note 404 is NOT handled here: on the fast path it means a stale id and the
// caller falls back (non-fatal); it never reaches the classifier.
//
// No provider body or PII is ever placed in `message` — short, fixed strings.
// ============================================================

import type { ErrorClass, GhlSyncResult } from '../types.ts'
import type { GhlResponse } from './client.ts'

export function sent(contactId: string): GhlSyncResult {
  return {
    outcome: 'sent',
    contactId,
    errorClass: null,
    providerStatus: null,
    retryAfterSeconds: null,
    message: 'Contact synced to GoHighLevel.',
  }
}

export function failed(
  errorClass: ErrorClass,
  providerStatus: number | null,
  message: string,
): GhlSyncResult {
  return { outcome: 'failed', contactId: null, errorClass, providerStatus, retryAfterSeconds: null, message }
}

export function retry(
  errorClass: ErrorClass,
  providerStatus: number | null,
  retryAfterSeconds: number | null,
  message: string,
): GhlSyncResult {
  return { outcome: 'retry', contactId: null, errorClass, providerStatus, retryAfterSeconds, message }
}

// Classify a FAILED GHL response (res.ok === false, and not a handled 404).
export function classifyProviderFailure(res: GhlResponse): GhlSyncResult {
  if (res.transport === 'timeout' || res.transport === 'network') {
    return retry('provider_unavailable', null, null, 'GoHighLevel did not respond.')
  }

  const s = res.status
  if (s === 401) return failed('auth', s, 'GoHighLevel rejected the credential.')
  if (s === 403) return failed('forbidden', s, 'GoHighLevel denied access to this resource.')
  if (s === 429) return retry('rate_limited', s, res.retryAfter, 'GoHighLevel rate-limited the request.')
  if (s >= 500) return retry('provider_unavailable', s, res.retryAfter, 'GoHighLevel is temporarily unavailable.')
  if (s === 400 || s === 422) {
    return failed('provider_validation', s, 'GoHighLevel rejected the contact data.')
  }
  return failed('provider_validation', s, `GoHighLevel returned an unexpected status (${s}).`)
}
