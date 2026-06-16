import { format } from 'date-fns'
import { Badge } from '../ui/Badge'
import type { ReservationDetail } from '../../lib/types'

interface ReservationsTableProps {
  reservations: ReservationDetail[]
}

type StatusVariant = 'confirmed' | 'checked_in' | 'checked_out' | 'cancelled'

export function ReservationsTable({ reservations }: ReservationsTableProps) {
  if (reservations.length === 0) {
    return (
      <div className="text-center py-12 text-gray-400 text-sm">
        No reservations yet.
      </div>
    )
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-gray-100">
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Guest</th>
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden sm:table-cell">Site</th>
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">Check In</th>
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">Check Out</th>
            <th className="text-right py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden lg:table-cell">Nights</th>
            <th className="text-right py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Total</th>
            <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Status</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-50">
          {reservations.map((r) => (
            <tr key={r.id} className="hover:bg-gray-50 transition-colors">
              <td className="py-3 px-4">
                <div className="font-medium text-gray-900">{r.guest_name}</div>
                <div className="text-xs text-gray-400 truncate max-w-[160px]">{r.email}</div>
              </td>
              <td className="py-3 px-4 font-mono text-gray-700 hidden sm:table-cell">{r.site_number}</td>
              <td className="py-3 px-4 text-gray-600 hidden md:table-cell">
                {format(new Date(r.check_in), 'MMM d, yyyy')}
              </td>
              <td className="py-3 px-4 text-gray-600 hidden md:table-cell">
                {format(new Date(r.check_out), 'MMM d, yyyy')}
              </td>
              <td className="py-3 px-4 text-right tabular-nums text-gray-600 hidden lg:table-cell">
                {r.num_nights}
              </td>
              <td className="py-3 px-4 text-right tabular-nums font-medium text-gray-900">
                {r.total_amount != null ? `$${Number(r.total_amount).toFixed(2)}` : '—'}
              </td>
              <td className="py-3 px-4 text-center">
                <Badge label={r.status.replace('_', ' ')} variant={r.status as StatusVariant} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
