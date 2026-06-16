import { useEffect, useState } from 'react'
import { format } from 'date-fns'
import { useAuth } from '../context/AuthProvider'
import { listTeamMembers, listPendingInvitations } from '../api/team'
import type { TeamMember, TeamInvitation } from '../lib/types'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'
import { StatusPill } from '../components/common/StatusPill'

const thClass =
  'text-left py-3 px-4 text-xs font-semibold text-gray-500 uppercase tracking-wider'

export function TeamPage() {
  const { orgId, role } = useAuth()
  const canSeeInvitations = role === 'owner' || role === 'manager'

  const [members, setMembers] = useState<TeamMember[]>([])
  const [invitations, setInvitations] = useState<TeamInvitation[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)

    const work: Promise<[TeamMember[], TeamInvitation[]]> = orgId
      ? Promise.all([
          listTeamMembers(orgId),
          canSeeInvitations ? listPendingInvitations(orgId) : Promise.resolve([] as TeamInvitation[]),
        ])
      : Promise.resolve([[], []])

    work
      .then(([m, inv]) => {
        if (!active) return
        setMembers(m)
        setInvitations(inv)
      })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load team') })
      .finally(() => { if (active) setLoading(false) })

    return () => { active = false }
  }, [orgId, canSeeInvitations])

  return (
    <div className="space-y-6">
      <PageHeader title="Team" subtitle="Read-only — members and pending invitations" />
      <DataState loading={loading} error={error}>
        <div className="space-y-6">

          {/* Members — visible to all roles */}
          <Card padding="sm">
            <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
              <h2 className="font-semibold text-gray-900">Members</h2>
              <span className="text-xs text-gray-400 tabular-nums">{members.length} total</span>
            </div>
            {members.length === 0 ? (
              <div className="text-center py-12 text-gray-400 text-sm">No members yet.</div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-gray-100">
                      <th className={thClass}>Name</th>
                      <th className={thClass}>Email</th>
                      <th className={thClass}>Role</th>
                      <th className={`${thClass} hidden md:table-cell`}>Scope</th>
                      <th className={`${thClass} text-center`}>Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-50">
                    {members.map((m) => (
                      <tr key={m.membershipId} className="hover:bg-gray-50 transition-colors">
                        <td className="py-3 px-4 font-medium text-gray-900">{m.name}</td>
                        <td className="py-3 px-4 text-gray-500 truncate max-w-[200px]">{m.email}</td>
                        <td className="py-3 px-4 text-gray-700 capitalize">{m.role}</td>
                        <td className="py-3 px-4 text-gray-500 hidden md:table-cell">{m.scope}</td>
                        <td className="py-3 px-4 text-center"><StatusPill status={m.status} /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          {/* Pending Invitations — owner/manager only */}
          {canSeeInvitations && (
            <Card padding="sm">
              <div className="px-4 pt-4 pb-3 flex items-center justify-between border-b border-gray-100">
                <div>
                  <h2 className="font-semibold text-gray-900">Pending Invitations</h2>
                  <p className="text-xs text-gray-400 mt-0.5">from the invitations table (token never requested)</p>
                </div>
                <span className="text-xs text-gray-400 tabular-nums">{invitations.length} pending</span>
              </div>
              {invitations.length === 0 ? (
                <div className="text-center py-10 text-gray-400 text-sm">No pending invitations.</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-gray-100">
                        <th className={thClass}>Email</th>
                        <th className={thClass}>Role</th>
                        <th className={`${thClass} hidden md:table-cell`}>Scope</th>
                        <th className={`${thClass} hidden lg:table-cell`}>Expires</th>
                        <th className={`${thClass} text-center`}>Status</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-50">
                      {invitations.map((inv) => (
                        <tr key={inv.id} className="hover:bg-gray-50 transition-colors">
                          <td className="py-3 px-4 font-medium text-gray-900 truncate max-w-[200px]">{inv.email}</td>
                          <td className="py-3 px-4 text-gray-700 capitalize">{inv.role}</td>
                          <td className="py-3 px-4 text-gray-500 hidden md:table-cell">{inv.scope}</td>
                          <td className="py-3 px-4 text-gray-500 hidden lg:table-cell">
                            {format(new Date(inv.expiresAt), 'MMM d, yyyy')}
                          </td>
                          <td className="py-3 px-4 text-center"><StatusPill status={inv.status} /></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>
          )}

        </div>
      </DataState>
    </div>
  )
}
