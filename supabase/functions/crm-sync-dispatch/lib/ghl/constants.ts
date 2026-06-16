// ============================================================
// crm-sync-dispatch — GoHighLevel client constants
// ============================================================

// Per-request transport budget. Kept well under the platform / N8N timeout so a
// slow provider classifies as a retry rather than hanging the function.
export const GHL_REQUEST_TIMEOUT_MS = 10_000
