// ============================================================
// crm-sync-dispatch — defensive JSON accessors
//
// The event payload and provider responses are untrusted `unknown`. These
// narrow safely without throwing, so callers never index into a non-object.
// ============================================================

export function asObject(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null
}

// A non-empty string, or null. (Empty/whitespace is treated as absent.)
export function asString(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v : null
}
