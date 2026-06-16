// ============================================================
// crm-test-connection — shared types
//
// Owner-invoked, event-less connection test. The browser (CRM credential UI)
// calls this with the owner's Supabase session JWT and an integration_id; the
// function (in later increments) verifies ownership, resolves the secret as
// crm_resolver, and pings GoHighLevel. Increment A wires structure/auth/clients
// only — no ownership gate, no secret resolve, no provider call yet.
// ============================================================

// ── Inbound request ──
export interface TestConnectionRequest {
  integration_id: string
}

// ── Verified caller identity (from JWT app_metadata, via getClaims) ──
// The hook enriches app_metadata with org_id / user_role / user_id. These are
// the SOURCE OF TRUTH for authorization — never request-supplied.
export interface CallerClaims {
  orgId: string
  userRole: string
  userId: string
}

// ── get_crm_dispatch_context(integration_id) → JSONB (V9). NON-SECRET. ──
// Mirrors the sync function's context. Returns null when the id does not exist.
export interface DispatchContext {
  provider: string
  external_account_id: string | null
  auth_type: string
  status: string
  tag_prefix: string
  field_mappings: Record<string, unknown>
}

// ── Response contract (frozen V6 ConnectionTestResult). Masked, secret-free. ──
//   { ok, message, checkedAt } — the browser shows `message` and never receives
//   a secret or provider body.
export interface TestConnectionResponse {
  ok: boolean
  message: string
  checkedAt: string // ISO-8601
}
