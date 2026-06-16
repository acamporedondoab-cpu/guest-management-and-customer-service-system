// ============================================================
// crm-sync-dispatch — GoHighLevel (LeadConnector) HTTP client
//
// Thin transport over the GHL v2 API. The base host is a HARDCODED server
// constant supplied via env (env.ts default; never from the request — B5). The
// private_token is held only in this client instance, attached as a Bearer
// header, and NEVER logged or returned.
//
// Every call is bounded by an AbortController timeout. The client classifies
// only transport state (ok / timeout / network); HTTP status interpretation is
// the classifier's job (classify.ts). The parsed body is returned as `unknown`
// for the caller to read defensively — it is never logged in full (§11).
// ============================================================

import { GHL_REQUEST_TIMEOUT_MS } from './constants.ts'

export type GhlTransport = 'ok' | 'timeout' | 'network'

export interface GhlResponse {
  ok: boolean
  status: number // 0 when no HTTP response was received (timeout/network)
  body: unknown // parsed JSON or null
  retryAfter: number | null // seconds, parsed from the Retry-After header
  transport: GhlTransport
}

function parseRetryAfter(header: string | null): number | null {
  if (header === null) return null
  const secs = parseInt(header, 10)
  if (Number.isFinite(secs) && secs >= 0) return secs
  const when = Date.parse(header)
  if (!Number.isNaN(when)) return Math.max(0, Math.ceil((when - Date.now()) / 1000))
  return null
}

export class GhlClient {
  // The token is private and never enumerated/serialized.
  readonly #token: string
  readonly #base: string
  readonly #version: string

  constructor(base: string, version: string, token: string) {
    this.#base = base.replace(/\/+$/, '')
    this.#version = version
    this.#token = token
  }

  async #request(method: string, path: string, body?: unknown): Promise<GhlResponse> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), GHL_REQUEST_TIMEOUT_MS)
    try {
      const res = await fetch(`${this.#base}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.#token}`,
          Version: this.#version,
          Accept: 'application/json',
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })
      let parsed: unknown = null
      try {
        parsed = await res.json()
      } catch {
        parsed = null // empty / non-JSON body
      }
      return {
        ok: res.ok,
        status: res.status,
        body: parsed,
        retryAfter: parseRetryAfter(res.headers.get('retry-after')),
        transport: 'ok',
      }
    } catch (e) {
      const timedOut = e instanceof DOMException && e.name === 'AbortError'
      return { ok: false, status: 0, body: null, retryAfter: null, transport: timedOut ? 'timeout' : 'network' }
    } finally {
      clearTimeout(timer)
    }
  }

  // Update an existing contact by id (fast path). 404 here signals a stale id
  // (caller falls back to upsert). No locationId on update (PUT rejects it).
  updateContact(contactId: string, body: unknown): Promise<GhlResponse> {
    return this.#request('PUT', `/contacts/${encodeURIComponent(contactId)}`, body)
  }

  // Native upsert. Body must include locationId. GHL applies the location's
  // "Allow Duplicate Contact" setting to match-or-create by email/phone and
  // returns the resulting contact — so the Edge needs no search or duplicate
  // handling of its own. Replaces the former search + create + duplicate path.
  upsertContact(body: unknown): Promise<GhlResponse> {
    return this.#request('POST', `/contacts/upsert`, body)
  }
}
