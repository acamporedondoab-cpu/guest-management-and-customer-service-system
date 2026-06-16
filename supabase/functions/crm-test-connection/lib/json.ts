// ============================================================
// crm-test-connection — defensive JSON accessors
//
// Claims and DB rows are read defensively without throwing.
// ============================================================

export function asObject(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null
}

// A non-empty string, or null.
export function asString(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v : null
}
