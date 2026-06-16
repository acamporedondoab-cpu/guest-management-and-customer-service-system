// ============================================================
// crm-sync-dispatch — inbound caller authentication
//
// Verifies that the request carries the EDGE_DISPATCH_TOKEN (the N8N → Edge
// proof). This is NOT DB authority — it only establishes "N8N called us". The
// DB authority is the crm_resolver JWT (see db.ts) bounded by EXECUTE grants.
//
// The compare is constant-time and length-independent: both the presented value
// and the expected value are SHA-256'd to a fixed 32 bytes, then XOR-compared.
// This leaks neither the secret's length nor an early-exit timing signal.
// The presented token is NEVER logged or echoed (§11 logging policy).
// ============================================================

const HEADER = 'x-dispatch-token'

async function sha256(input: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input))
  return new Uint8Array(digest)
}

// Constant-time byte compare over two equal-length (32) digests.
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}

// Returns true iff the request presents the exact dispatch token. Absence of
// the header is a clean false (no exception, no log of the attempt's content).
export async function isAuthorized(req: Request, expected: string): Promise<boolean> {
  const presented = req.headers.get(HEADER)
  if (presented === null) return false
  const [p, e] = await Promise.all([sha256(presented), sha256(expected)])
  return timingSafeEqual(p, e)
}
