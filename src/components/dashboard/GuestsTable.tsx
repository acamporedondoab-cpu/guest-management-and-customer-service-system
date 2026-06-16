import { Badge } from '../ui/Badge'
import type { GuestSummary } from '../../lib/types'

interface GuestsTableProps {
  guests: GuestSummary[]
}

function tierVariant(tier: string): 'gold' | 'silver' | 'bronze' {
  if (tier === 'Gold') return 'gold'
  if (tier === 'Silver') return 'silver'
  return 'bronze'
}

export function GuestsTable({ guests }: GuestsTableProps) {
  if (guests.length === 0) {
    return (
      <div className="text-center py-12 text-gray-400 text-sm">
        No guests yet. Submit a reservation to get started.
      </div>
    )
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-gray-100">
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Name</th>
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Email</th>
            <th className="text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden md:table-cell">Phone</th>
            <th className="text-right py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Visits</th>
            <th className="text-right py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden sm:table-cell">Spend</th>
            <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Tier</th>
            <th className="text-center py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider hidden lg:table-cell">CRM Synced</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-50">
          {guests.map((g) => (
            <tr key={g.id} className="hover:bg-gray-50 transition-colors">
              <td className="py-3 px-4 font-medium text-gray-900">{g.full_name}</td>
              <td className="py-3 px-4 text-gray-500 truncate max-w-[180px]">{g.email}</td>
              <td className="py-3 px-4 text-gray-500 hidden md:table-cell">{g.phone ?? '—'}</td>
              <td className="py-3 px-4 text-right tabular-nums text-gray-700">{g.total_visits}</td>
              <td className="py-3 px-4 text-right tabular-nums text-gray-700 hidden sm:table-cell">
                ${Number(g.total_spend).toFixed(2)}
              </td>
              <td className="py-3 px-4 text-center">
                <Badge label={g.loyalty_tier} variant={tierVariant(g.loyalty_tier)} />
              </td>
              <td className="py-3 px-4 text-center hidden lg:table-cell">
                {g.ghl_contact_id
                  ? <span className="text-xs text-green-600 font-medium">&#10003; Synced</span>
                  : <span className="text-xs text-gray-400">Pending</span>
                }
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
