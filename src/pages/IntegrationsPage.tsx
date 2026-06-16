import { Fragment, useCallback, useEffect, useState } from 'react'
import { format } from 'date-fns'
import { listCrmIntegrations, listPmsIntegrations, testCrmConnection, friendlyCrmError } from '../api/integrations'
import type { CrmIntegrationSafe, PmsIntegrationSafe, UpsertCrmIntegrationResult } from '../lib/types'
import { useAuth } from '../context/AuthProvider'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'
import { StatusPill } from '../components/common/StatusPill'
import { CrmIntegrationModal } from '../components/integrations/CrmIntegrationModal'

// Modal state — which mode is open and (for manage) the row being managed.
type CrmModalState = { mode: 'connect' } | { mode: 'manage'; integration: CrmIntegrationSafe }

// Page-level notice with a tone so success and failure render distinctly.
type Notice = { tone: 'success' | 'error'; text: string }

// Connection testing requires the server endpoint to be configured (the Edge
// Function / N8N webhook is provisioned out-of-band). When unset, the Test
// button is shown disabled rather than erroring on click.
const TEST_ENDPOINT_CONFIGURED = !!import.meta.env.VITE_CRM_TEST_ENDPOINT_URL

// Common display shape for the PMS table (CRM has its own richer table below).
interface IntegrationRow {
  id: string
  provider: string
  name: string
  externalId: string | null
  status: string
  lastSync: string | null
}

// Human-readable label for the v8 auth_type. 'none' renders as a dash.
const AUTH_TYPE_LABELS: Record<CrmIntegrationSafe['auth_type'], string> = {
  api_key: 'API Key',
  private_token: 'Private Token',
  oauth2: 'OAuth 2.0',
  none: '—',
}

// Masked credential display — last4 only, never any secret / vault reference.
// Handles a missing or empty credential_ref gracefully.
function maskedCredential(ref: CrmIntegrationSafe['credential_ref'] | null | undefined): string {
  const last4 = ref?.last4
  return last4 ? `•••• ${last4}` : '—'
}

function fmtDate(value: string | null): string {
  return value ? format(new Date(value), 'MMM d, yyyy') : '—'
}

function IntegrationSection({
  title,
  caption,
  idLabel,
  rows,
}: {
  title: string
  caption: string
  idLabel: string
  rows: IntegrationRow[]
}) {
  return (
    <Card padding="sm">
      <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
        <div>
          <h2 className="font-semibold text-gray-900">{title}</h2>
          <p className="text-xs text-gray-400 mt-0.5">{caption}</p>
        </div>
        <span className="text-xs text-gray-400 tabular-nums">{rows.length} configured</span>
      </div>
      {rows.length === 0 ? (
        <div className="text-center py-10 text-gray-400 text-sm">No integrations configured.</div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-100">
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Provider</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Name</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">{idLabel}</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden lg:table-cell">Last Sync</th>
                <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {rows.map((r) => (
                <tr key={r.id} className="hover:bg-gray-50 transition-colors">
                  <td className="py-3 px-4 font-medium text-gray-900 capitalize">{r.provider}</td>
                  <td className="py-3 px-4 text-gray-700">{r.name}</td>
                  <td className="py-3 px-4 font-mono text-xs text-gray-500 hidden md:table-cell">{r.externalId ?? '—'}</td>
                  <td className="py-3 px-4 text-gray-500 hidden lg:table-cell">
                    {r.lastSync ? format(new Date(r.lastSync), 'MMM d, yyyy') : '—'}
                  </td>
                  <td className="py-3 px-4 text-center"><StatusPill status={r.status} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

// CRM section — surfaces the v8 non-secret metadata (auth_type, masked last4,
// connected_at, last_sync_at, status, last_error). Read-only for everyone except
// owners, who additionally get Connect (when GHL isn't connected yet) and Manage
// (rotate credential / edit basic metadata) actions. credentials, vault_secret_id
// and the resolver are never referenced or shown.
function CrmIntegrationsSection({
  rows,
  canManage,
  canConnect,
  canTest,
  testingId,
  onConnect,
  onManage,
  onTest,
}: {
  rows: CrmIntegrationSafe[]
  canManage: boolean
  canConnect: boolean
  canTest: boolean
  testingId: string | null
  onConnect: () => void
  onManage: (integration: CrmIntegrationSafe) => void
  onTest: (integration: CrmIntegrationSafe) => void
}) {
  // Actions column only exists for owners; the error sub-row spans every column.
  const colCount = canManage ? 8 : 7
  return (
    <Card padding="sm">
      <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
        <div>
          <h2 className="font-semibold text-gray-900">CRM</h2>
          <p className="text-xs text-gray-400 mt-0.5">from the crm_integrations_safe view</p>
        </div>
        <div className="flex items-center gap-3">
          <span className="text-xs text-gray-400 tabular-nums">{rows.length} configured</span>
          {canManage && canConnect && (
            <button
              type="button"
              onClick={onConnect}
              className="bg-forest-600 hover:bg-forest-700 text-white font-semibold py-1.5 px-3 rounded-lg text-xs transition-colors"
            >
              Connect CRM
            </button>
          )}
        </div>
      </div>
      {rows.length === 0 ? (
        <div className="text-center py-10 text-gray-400 text-sm">No integrations configured.</div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-100">
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Provider</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Name</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">Auth</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">Credential</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden lg:table-cell">Connected</th>
                <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden lg:table-cell">Last Sync</th>
                <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Status</th>
                {canManage && (
                  <th className="text-right py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Actions</th>
                )}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {rows.map((c) => (
                <Fragment key={c.id}>
                  <tr className="hover:bg-gray-50 transition-colors">
                    <td className="py-3 px-4 font-medium text-gray-900 capitalize">{c.provider}</td>
                    <td className="py-3 px-4 text-gray-700">{c.name}</td>
                    <td className="py-3 px-4 text-gray-500 hidden md:table-cell">{AUTH_TYPE_LABELS[c.auth_type] ?? '—'}</td>
                    <td className="py-3 px-4 font-mono text-xs text-gray-500 hidden md:table-cell">{maskedCredential(c.credential_ref)}</td>
                    <td className="py-3 px-4 text-gray-500 hidden lg:table-cell">{fmtDate(c.connected_at)}</td>
                    <td className="py-3 px-4 text-gray-500 hidden lg:table-cell">{fmtDate(c.last_sync_at)}</td>
                    <td className="py-3 px-4 text-center"><StatusPill status={c.status} /></td>
                    {canManage && (
                      <td className="py-3 px-4 text-right">
                        <div className="flex items-center justify-end gap-3">
                          <button
                            type="button"
                            onClick={() => onTest(c)}
                            disabled={!canTest || testingId === c.id}
                            title={canTest ? undefined : 'Connection testing is not configured for this environment.'}
                            className="text-xs font-semibold text-gray-600 hover:text-gray-900 disabled:text-gray-300 disabled:cursor-not-allowed"
                          >
                            {testingId === c.id ? 'Testing…' : 'Test'}
                          </button>
                          <button
                            type="button"
                            onClick={() => onManage(c)}
                            className="text-xs font-semibold text-forest-700 hover:text-forest-800"
                          >
                            Manage
                          </button>
                        </div>
                      </td>
                    )}
                  </tr>
                  {c.status === 'error' && c.last_error && (
                    <tr className="bg-red-50/50">
                      <td colSpan={colCount} className="py-2 px-4 text-xs text-red-700">
                        <span className="font-medium">Last error:</span> {c.last_error}
                        {c.last_error_at && (
                          <span className="text-red-400"> · {format(new Date(c.last_error_at), 'MMM d, yyyy p')}</span>
                        )}
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

export function IntegrationsPage() {
  const { role } = useAuth()
  const canManage = role === 'owner'

  const [crm, setCrm] = useState<CrmIntegrationSafe[]>([])
  const [pms, setPms] = useState<PmsIntegrationSafe[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<CrmModalState | null>(null)
  const [notice, setNotice] = useState<Notice | null>(null)
  const [testingId, setTestingId] = useState<string | null>(null)

  // Re-readable loader so writes can refresh the masked view rather than trust
  // any local post-write state. Returns a cleanup-aware promise on mount; the
  // write success path calls it again with no cleanup binding.
  const loadIntegrations = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [crmRows, pmsRows] = await Promise.all([listCrmIntegrations(), listPmsIntegrations()])
      setCrm(crmRows)
      setPms(pmsRows)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Failed to load integrations')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void loadIntegrations()
  }, [loadIntegrations])

  // GHL is the only provider this increment; offer Connect only when absent.
  const hasGhl = crm.some((c) => c.provider === 'gohighlevel')

  function handleSuccess(result: UpsertCrmIntegrationResult, mode: 'connect' | 'manage') {
    setModal(null)
    const last4 = result.last4 ? ` · ending •••• ${result.last4}` : ''
    setNotice({
      tone: 'success',
      text: mode === 'connect' ? `GoHighLevel connected${last4}.` : `GoHighLevel updated${last4}.`,
    })
    void loadIntegrations()
  }

  // Server-side connection test. The browser sends only the integration id (the
  // endpoint resolves the secret server-side); we surface the masked pass/fail
  // result and refetch so the row reflects any status / last_error write-back.
  async function handleTest(integration: CrmIntegrationSafe) {
    setTestingId(integration.id)
    setNotice(null)
    try {
      const result = await testCrmConnection(integration.id)
      setNotice(
        result.ok
          ? { tone: 'success', text: result.message || 'Connection verified.' }
          : { tone: 'error', text: result.message || 'Connection test failed.' },
      )
    } catch (err) {
      setNotice({ tone: 'error', text: friendlyCrmError(err) })
    } finally {
      setTestingId(null)
      void loadIntegrations()
    }
  }

  const pmsRows: IntegrationRow[] = pms.map((p) => ({
    id: p.id, provider: p.provider, name: p.name,
    externalId: p.external_property_id, status: p.status, lastSync: p.last_sync_at,
  }))

  return (
    <div className="space-y-6">
      <PageHeader
        title="Integrations"
        subtitle="Credentials are never exposed to the dashboard"
      />

      {notice && (
        <div
          className={`flex items-center justify-between rounded-lg border px-3 py-2 text-sm ${
            notice.tone === 'success'
              ? 'border-green-200 bg-green-50 text-green-800'
              : 'border-red-200 bg-red-50 text-red-700'
          }`}
        >
          <span>{notice.text}</span>
          <button
            type="button"
            onClick={() => setNotice(null)}
            className={`font-medium ${notice.tone === 'success' ? 'text-green-600 hover:text-green-800' : 'text-red-600 hover:text-red-800'}`}
          >
            Dismiss
          </button>
        </div>
      )}

      <DataState loading={loading} error={error}>
        <div className="space-y-6">
          <CrmIntegrationsSection
            rows={crm}
            canManage={canManage}
            canConnect={!hasGhl}
            canTest={TEST_ENDPOINT_CONFIGURED}
            testingId={testingId}
            onConnect={() => setModal({ mode: 'connect' })}
            onManage={(integration) => setModal({ mode: 'manage', integration })}
            onTest={handleTest}
          />
          <IntegrationSection
            title="PMS"
            caption="from the pms_integrations_safe view"
            idLabel="Property ID"
            rows={pmsRows}
          />
        </div>
      </DataState>

      {canManage && modal && (
        <CrmIntegrationModal
          mode={modal.mode}
          integration={modal.mode === 'manage' ? modal.integration : undefined}
          onClose={() => setModal(null)}
          onSuccess={handleSuccess}
        />
      )}
    </div>
  )
}
