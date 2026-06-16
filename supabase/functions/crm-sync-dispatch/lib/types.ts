// ============================================================
// crm-sync-dispatch — shared types
//
// Contracts only. These mirror the DB-authoritative shapes the Edge derives
// (get_dispatch_event, V10) and the masked envelope it returns to N8N. No GHL
// client types yet — those land with the GHL increment.
// ============================================================

// ── Inbound request (B-1: event_id ONLY; any other field is ignored) ──
export interface DispatchRequest {
  event_id: string
}

// ── get_dispatch_event(p_event_id) → JSONB (V10 contract) ──
// Non-secret routing context. Mirrors get_crm_dispatch_context. NEVER a secret.
export interface DispatchContext {
  provider: string
  external_account_id: string | null
  auth_type: string
  status: string
  tag_prefix: string
  field_mappings: Record<string, unknown>
}

// found=false → unknown event id. Otherwise the full event-bound dispatch row.
export interface DispatchEvent {
  found: boolean
  status?: string
  event_type?: string
  organization_id?: string
  property_id?: string | null
  integration_id?: string | null
  context?: DispatchContext | null
  payload?: Record<string, unknown> | null
}

// ── Outcome taxonomy ──
// Edge outcome (richer than the DB's complete_webhook_event p_outcome set).
// N8N maps these → {sent|retry|failed|skipped} or skips `complete` (ignored).
export type Outcome =
  | 'sent'
  | 'retry'
  | 'failed'
  | 'skipped'
  | 'ignored'
  | 'no_provider'
  | 'no_secret'

// Sanitized failure classification. Never carries provider bodies or PII.
export type ErrorClass =
  | 'not_found'
  | 'not_claimed'
  | 'no_provider'
  | 'no_secret'
  | 'validation'
  | 'auth'
  | 'forbidden'
  | 'rate_limited'
  | 'provider_unavailable'
  | 'provider_validation'
  | 'bad_request'
  | 'unauthorized'
  | 'method_not_allowed'
  | 'not_implemented'
  | 'internal'

// Provider-level sync outcomes (subset of Outcome the GHL layer can produce).
export type SyncOutcome = 'sent' | 'retry' | 'failed'

// Result of the GoHighLevel contact sync. Masked: never carries the secret,
// raw provider body, or PII. contact_id is a GHL id (non-sensitive).
export interface GhlSyncResult {
  outcome: SyncOutcome
  contactId: string | null
  errorClass: ErrorClass | null
  providerStatus: number | null
  retryAfterSeconds: number | null
  message: string
}

// ── Response envelope (Edge → caller). Masked, secret-free. ──
export interface DispatchResponse {
  event_id: string | null
  outcome: Outcome
  integration_id: string | null
  contact_id: string | null
  error_class: ErrorClass | null
  retry_after_seconds: number | null
  provider_status: number | null
  message: string
}
