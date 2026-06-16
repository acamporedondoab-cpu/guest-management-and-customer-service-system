import { supabase } from '../lib/supabase'
import type {
  CrmIntegrationSafe,
  PmsIntegrationSafe,
  UpsertCrmIntegrationArgs,
  UpsertCrmIntegrationResult,
} from '../lib/types'

// READ-ONLY via the *_safe views, which exclude the credentials column.
// Never read the base crm_integrations / pms_integrations tables from the UI.
// Rows are visible to owner/manager only (RLS); other roles get an empty list.

export async function listCrmIntegrations(): Promise<CrmIntegrationSafe[]> {
  const { data, error } = await supabase
    .from('crm_integrations_safe')
    .select('*')
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CrmIntegrationSafe[]
}

export async function listPmsIntegrations(): Promise<PmsIntegrationSafe[]> {
  const { data, error } = await supabase
    .from('pms_integrations_safe')
    .select('*')
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as PmsIntegrationSafe[]
}

// WRITE (RPC-only). upsert_crm_integration() is the SOLE authenticated path that
// writes CRM credentials, and the only Supabase function the browser ever calls
// for CRM management. Covers the Phase 2 scope:
//   • Connect      — first call for an org+provider (p_secret provided)
//   • Rotate       — subsequent call with a new p_secret (Vault value updated)
//   • Config Edit  — p_secret omitted/null preserves the existing secret
// Disconnect is intentionally NOT exposed (no v8 disable/secret-clear path; it is
// deferred to a future additive migration). The secret is write-only: it goes to
// the RPC and into Vault and is never read back — the function returns SAFE,
// masked fields only (UpsertCrmIntegrationResult: last4, status, …). Org/role/user
// are derived from the JWT server-side; the RPC rejects non-owners with 42501.
export async function upsertCrmIntegration(
  args: UpsertCrmIntegrationArgs,
): Promise<UpsertCrmIntegrationResult> {
  // `args as never`: same typed-client rpc() arg-inference limitation documented
  // in api/reservations.ts (the Database generic's Row interfaces don't satisfy
  // supabase-js's GenericSchema constraint, collapsing the arg type to `never`).
  // The UpsertCrmIntegrationArgs parameter type is the real, enforced contract.
  const { data, error } = await supabase.rpc('upsert_crm_integration', args as never)
  if (error) throw error
  return data as UpsertCrmIntegrationResult
}

// Result of a server-side connection test — masked / non-secret only.
export interface ConnectionTestResult {
  ok: boolean
  message: string
  checkedAt: string
}

// Connection test. The browser NEVER resolves a secret: it sends only the
// integration id (plus the caller's JWT for server-side org-ownership checks) to
// a server endpoint (N8N webhook / Edge Function). That endpoint resolves the
// secret server-side via resolve_crm_secret() (service_role) and pings the
// provider; this client never references resolve_crm_secret and never receives a
// secret back — only a masked pass/fail result.
export async function testCrmConnection(integrationId: string): Promise<ConnectionTestResult> {
  const endpoint = import.meta.env.VITE_CRM_TEST_ENDPOINT_URL as string | undefined
  if (!endpoint) {
    throw new Error('Connection testing is not configured (VITE_CRM_TEST_ENDPOINT_URL is unset).')
  }

  // Attach the current session JWT so the server can verify the caller owns the
  // integration's org before resolving any secret.
  const { data: sessionData } = await supabase.auth.getSession()
  const token = sessionData.session?.access_token

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ integration_id: integrationId }),
  })

  if (!res.ok) {
    throw new Error(`Connection test failed (${res.status}).`)
  }

  const body = (await res.json()) as Partial<ConnectionTestResult>
  return {
    ok: body.ok === true,
    message: typeof body.message === 'string' ? body.message : '',
    checkedAt: typeof body.checkedAt === 'string' ? body.checkedAt : new Date().toISOString(),
  }
}

// Map known CRM RPC / endpoint failures to friendly copy — never surface raw DB
// errors (and never any secret). Mirrors NewReservationPage.friendlyError.
export function friendlyCrmError(e: unknown): string {
  const msg = e instanceof Error ? e.message : ''
  const code = (e as { code?: string } | null)?.code
  if (code === '42501' || /owner only|may not manage|no organization context|permission/i.test(msg))
    return 'Only owners can manage CRM credentials.'
  if (/must not contain secret keys/i.test(msg))
    return 'Don’t put secrets in configuration fields — enter the key in the credential field only.'
  if (/invalid provider/i.test(msg))
    return 'That CRM provider isn’t supported.'
  if (/invalid auth_type/i.test(msg))
    return 'That authentication type isn’t supported for this provider.'
  if (/not configured/i.test(msg))
    return 'Connection testing isn’t configured for this environment yet.'
  return 'Something went wrong saving the CRM integration. Please try again.'
}
