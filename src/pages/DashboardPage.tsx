import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { GuestSummary, ReservationDetail, KpiSummary } from '../lib/types'
import { KPICard } from '../components/dashboard/KPICard'
import { GuestsTable } from '../components/dashboard/GuestsTable'
import { ReservationsTable } from '../components/dashboard/ReservationsTable'
import { Card } from '../components/ui/Card'
import { Spinner } from '../components/ui/Spinner'

export function DashboardPage() {
  const [kpi, setKpi] = useState<KpiSummary | null>(null)
  const [guests, setGuests] = useState<GuestSummary[]>([])
  const [reservations, setReservations] = useState<ReservationDetail[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    async function load() {
      setLoading(true)
      setError(null)

      const [kpiRes, guestsRes, reservationsRes] = await Promise.all([
        supabase.from('kpi_summary').select('*').returns<KpiSummary[]>().single(),
        supabase.from('guest_summary').select('*').returns<GuestSummary[]>().order('total_visits', { ascending: false }),
        supabase.from('reservation_detail').select('*').returns<ReservationDetail[]>().order('created_at', { ascending: false }).limit(50),
      ])

      const err = kpiRes.error ?? guestsRes.error ?? reservationsRes.error
      if (err) {
        setError(err.message)
      } else {
        setKpi(kpiRes.data)
        setGuests(guestsRes.data ?? [])
        setReservations(reservationsRes.data ?? [])
      }

      setLoading(false)
    }

    void load()
  }, [])

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24">
        <Spinner size="lg" label="Loading dashboard..." />
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-200 bg-red-50 p-6 text-red-700 text-sm">
        <strong>Connection error:</strong> {error}
        <p className="mt-1 text-red-500 text-xs">
          Make sure VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are set in .env.local
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-8">

      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Dashboard</h1>
        <p className="text-gray-500 text-sm mt-1">
          Real-time guest data from Supabase &mdash; fed by Make.com automation
        </p>
      </div>

      {/* KPI Cards */}
      {kpi && (
        <div className="grid grid-cols-2 lg:grid-cols-5 gap-4">
          <KPICard
            label="Total Guests"
            value={kpi.total_guests}
            icon="&#128100;"
            accent="green"
          />
          <KPICard
            label="Total Reservations"
            value={kpi.total_reservations}
            icon="&#127987;"
            accent="blue"
          />
          <KPICard
            label="Returning Guests"
            value={kpi.returning_guests}
            sub={`${kpi.total_guests > 0 ? Math.round((kpi.returning_guests / kpi.total_guests) * 100) : 0}% of guests`}
            icon="&#128257;"
            accent="purple"
          />
          <KPICard
            label="Estimated Revenue"
            value={`$${Number(kpi.estimated_revenue).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`}
            icon="&#128176;"
            accent="amber"
          />
          <KPICard
            label="CRM Synced"
            value={kpi.synced_contacts}
            sub={`${kpi.total_guests > 0 ? Math.round((kpi.synced_contacts / kpi.total_guests) * 100) : 0}% in GoHighLevel`}
            icon="&#128279;"
            accent="green"
          />
        </div>
      )}

      {/* Loyalty tier breakdown */}
      {kpi && (
        <div className="grid grid-cols-3 gap-4">
          <div className="bg-orange-50 border border-orange-100 rounded-xl p-4 text-center">
            <div className="text-2xl font-bold text-orange-700 tabular-nums">{kpi.bronze_guests}</div>
            <div className="text-xs text-orange-500 font-medium mt-1">Bronze Guests</div>
            <div className="text-xs text-orange-400 mt-0.5">1–2 visits</div>
          </div>
          <div className="bg-gray-50 border border-gray-200 rounded-xl p-4 text-center">
            <div className="text-2xl font-bold text-gray-600 tabular-nums">{kpi.silver_guests}</div>
            <div className="text-xs text-gray-500 font-medium mt-1">Silver Guests</div>
            <div className="text-xs text-gray-400 mt-0.5">3–5 visits</div>
          </div>
          <div className="bg-yellow-50 border border-yellow-100 rounded-xl p-4 text-center">
            <div className="text-2xl font-bold text-yellow-700 tabular-nums">{kpi.gold_guests}</div>
            <div className="text-xs text-yellow-600 font-medium mt-1">Gold Guests</div>
            <div className="text-xs text-yellow-500 mt-0.5">6+ visits</div>
          </div>
        </div>
      )}

      {/* Guests table */}
      <Card padding="sm">
        <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
          <div>
            <h2 className="font-semibold text-gray-900">Guests</h2>
            <p className="text-xs text-gray-400 mt-0.5">from <code className="font-mono text-xs bg-gray-100 px-1 rounded">guest_summary</code> view</p>
          </div>
          <span className="text-xs text-gray-400 tabular-nums">{guests.length} total</span>
        </div>
        <GuestsTable guests={guests} />
      </Card>

      {/* Reservations table */}
      <Card padding="sm">
        <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
          <div>
            <h2 className="font-semibold text-gray-900">Reservations</h2>
            <p className="text-xs text-gray-400 mt-0.5">from <code className="font-mono text-xs bg-gray-100 px-1 rounded">reservation_detail</code> view</p>
          </div>
          <span className="text-xs text-gray-400 tabular-nums">{reservations.length} shown</span>
        </div>
        <ReservationsTable reservations={reservations} />
      </Card>

    </div>
  )
}
