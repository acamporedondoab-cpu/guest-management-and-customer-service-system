import { useEffect, useState } from 'react'
import { listGuests } from '../api/guests'
import type { GuestSummary } from '../lib/types'
import { GuestsTable } from '../components/dashboard/GuestsTable'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'

export function GuestsPage() {
  const [guests, setGuests] = useState<GuestSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    listGuests()
      .then((data) => { if (active) setGuests(data) })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load guests') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [])

  return (
    <div className="space-y-6">
      <PageHeader
        title="Guests"
        subtitle="Read-only — from the guest_summary view"
        right={<span className="text-xs text-gray-400 tabular-nums">{guests.length} total</span>}
      />
      <DataState loading={loading} error={error}>
        <Card padding="sm">
          <GuestsTable guests={guests} />
        </Card>
      </DataState>
    </div>
  )
}
