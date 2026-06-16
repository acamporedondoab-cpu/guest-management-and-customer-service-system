// ============================================================
// crm-test-connection — inbound caller authentication (Increment A)
//
// AUTH MODEL: the caller is the browser, presenting the OWNER's Supabase session
// JWT in `Authorization: Bearer <jwt>`. There is intentionally NO shared
// constant-time token here — a static secret shipped to the browser is not
// secret, so a timing-safe compare would be security theater. The real
// authority is the user JWT plus an owner + ownership gate.
//
// Increment A does STRUCTURAL validation only: confirm a Bearer token is present
// and shaped like a JWT (three non-empty base64url segments). The platform
// gateway (verify_jwt=true) cryptographically verifies the token; the in-function
// claims read (owner role) + integration-belongs-to-org check land in the gate
// increment. The token value is never logged.
// ============================================================

const BEARER = /^Bearer\s+(.+)$/i
const JWT_SHAPE = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/

// Returns the raw JWT if the Authorization header carries a structurally-valid
// Bearer JWT, else null. No decoding, no signature check (that is the gateway's
// job + the next increment's verified-claims read).
export function extractBearerJwt(req: Request): string | null {
  const header = req.headers.get('authorization')
  if (header === null) return null
  const m = BEARER.exec(header.trim())
  if (m === null) return null
  const token = m[1].trim()
  return JWT_SHAPE.test(token) ? token : null
}
