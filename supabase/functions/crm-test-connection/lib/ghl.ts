// ============================================================
// crm-test-connection — GoHighLevel (LeadConnector) client
//
// Minimal client for the connection test: a single authenticated read of the
// location. The base host is a HARDCODED server constant (env.ts default; never
// request-derived — B5). The private_token is held only in this instance, on the
// Authorization header, and is NEVER logged or returned. Bounded by a timeout.
// ============================================================

const REQUEST_TIMEOUT_MS = 10_000

export type GhlTransport = 'ok' | 'timeout' | 'network'

export interface GhlResponse {
  ok: boolean
  status: number // 0 when no HTTP response (timeout/network)
  body: unknown // parsed JSON or null
  transport: GhlTransport
}

export class GhlClient {
  readonly #base: string
  readonly #version: string
  readonly #token: string

  constructor(base: string, version: string, token: string) {
    this.#base = base.replace(/\/+$/, '')
    this.#version = version
    this.#token = token
  }

  // GET /locations/{locationId} — validates the token against the configured
  // location. Used by the connection test only.
  async getLocation(locationId: string): Promise<GhlResponse> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
    try {
      const res = await fetch(`${this.#base}/locations/${encodeURIComponent(locationId)}`, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${this.#token}`,
          Version: this.#version,
          Accept: 'application/json',
        },
        signal: controller.signal,
      })
      let parsed: unknown = null
      try {
        parsed = await res.json()
      } catch {
        parsed = null
      }
      return { ok: res.ok, status: res.status, body: parsed, transport: 'ok' }
    } catch (e) {
      const timedOut = e instanceof DOMException && e.name === 'AbortError'
      return { ok: false, status: 0, body: null, transport: timedOut ? 'timeout' : 'network' }
    } finally {
      clearTimeout(timer)
    }
  }
}
