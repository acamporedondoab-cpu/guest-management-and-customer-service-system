import { useEffect, useState } from 'react'
import { listProperties } from '../api/properties'
import type { Property } from '../lib/types'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'
import { StatusPill } from '../components/common/StatusPill'

export function PropertiesPage() {
  const [properties, setProperties] = useState<Property[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    listProperties()
      .then((data) => { if (active) setProperties(data) })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load properties') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [])

  return (
    <div className="space-y-6">
      <PageHeader
        title="Properties"
        subtitle="Read-only — campground locations in your organization"
        right={<span className="text-xs text-gray-400 tabular-nums">{properties.length} total</span>}
      />
      <DataState loading={loading} error={error}>
        <Card padding="sm">
          {properties.length === 0 ? (
            <div className="text-center py-12 text-gray-400 text-sm">No properties yet.</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-gray-100">
                    <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Name</th>
                    <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Location</th>
                    <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Status</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-50">
                  {properties.map((p) => (
                    <tr key={p.id} className="hover:bg-gray-50 transition-colors">
                      <td className="py-3 px-4 font-medium text-gray-900">{p.name}</td>
                      <td className="py-3 px-4 text-gray-500">{p.location ?? '—'}</td>
                      <td className="py-3 px-4 text-center"><StatusPill status={p.status} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      </DataState>
    </div>
  )
}
