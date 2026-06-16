import { useEffect, useState } from 'react'
import { useAuth } from '../context/AuthProvider'
import { getOrganization } from '../api/orgs'
import { listCrmIntegrations, listPmsIntegrations } from '../api/integrations'
import type { OrganizationSettings } from '../lib/types'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'
import { StatusPill } from '../components/common/StatusPill'

// Read-only label/value row.
function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between py-2 border-b border-gray-50 last:border-0">
      <span className="text-sm text-gray-500">{label}</span>
      <span className="text-sm font-medium text-gray-900">{value}</span>
    </div>
  )
}

export function SettingsPage() {
  const { session, orgId } = useAuth()
  const email = session?.user?.email ?? '—'

  const [org, setOrg] = useState<OrganizationSettings | null>(null)
  const [crmCount, setCrmCount] = useState(0)
  const [pmsCount, setPmsCount] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    Promise.all([
      orgId ? getOrganization(orgId) : Promise.resolve(null),
      listCrmIntegrations(),
      listPmsIntegrations(),
    ])
      .then(([orgData, crm, pms]) => {
        if (!active) return
        setOrg(orgData)
        setCrmCount(crm.length)
        setPmsCount(pms.length)
      })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load settings') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [orgId])

  return (
    <div className="space-y-6">
      <PageHeader title="Settings" subtitle="Read-only — organization, integrations, and account" />
      <DataState loading={loading} error={error}>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">

          {/* Organization */}
          <Card>
            <h2 className="font-semibold text-gray-900 mb-3">Organization</h2>
            {org ? (
              <div>
                <Field label="Name" value={org.name} />
                <Field label="Slug" value={<span className="font-mono text-xs">{org.slug}</span>} />
                <Field label="Plan" value={<span className="capitalize">{org.plan}</span>} />
                <Field label="Status" value={<StatusPill status={org.status} />} />
              </div>
            ) : (
              <p className="text-sm text-gray-400">No organization in the current session.</p>
            )}
          </Card>

          {/* Connected Integrations */}
          <Card>
            <h2 className="font-semibold text-gray-900 mb-3">Connected Integrations</h2>
            <div>
              <Field label="CRM integrations" value={<span className="tabular-nums">{crmCount}</span>} />
              <Field label="PMS integrations" value={<span className="tabular-nums">{pmsCount}</span>} />
            </div>
          </Card>

          {/* Account */}
          <Card>
            <h2 className="font-semibold text-gray-900 mb-3">Account</h2>
            <div>
              <Field label="Email" value={email} />
            </div>
          </Card>

        </div>
      </DataState>
    </div>
  )
}
