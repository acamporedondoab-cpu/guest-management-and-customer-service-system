import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { listReservations } from '../api/reservations'
import type { ReservationDetail } from '../lib/types'
import { ReservationsTable } from '../components/dashboard/ReservationsTable'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'

export function ReservationsPage() {
  const [reservations, setReservations] = useState<ReservationDetail[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    listReservations()
      .then((data) => { if (active) setReservations(data) })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load reservations') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [])

  return (
    <div className="space-y-6">
      <PageHeader
        title="Reservations"
        subtitle="Read-only — from the reservation_detail view"
        right={
          <div className="flex items-center gap-4">
            <span className="text-xs text-gray-400 tabular-nums">{reservations.length} shown</span>
            <Link
              to="/reservations/new"
              className="bg-forest-600 hover:bg-forest-700 text-white font-semibold py-2 px-4 rounded-lg text-sm transition-colors"
            >
              New reservation
            </Link>
          </div>
        }
      />
      <DataState loading={loading} error={error}>
        <Card padding="sm">
          <ReservationsTable reservations={reservations} />
        </Card>
      </DataState>
    </div>
  )
}
