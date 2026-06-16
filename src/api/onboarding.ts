import { getOrganization } from './orgs'
import { listTeamMembers } from './team'
import { listCrmIntegrations, listPmsIntegrations } from './integrations'
import { listGuests } from './guests'
import { listReservations } from './reservations'
import type { OnboardingStep } from '../lib/types'

// READ-ONLY. Onboarding readiness is *derived* from real production data —
// it never reads or writes onboarding_sessions (that table is empty and is not
// the source of truth here). Each of the seven steps maps to one of the six
// enumerated data sources; "Ready For Go Live" is a pure roll-up of the rest.
//
// Note: CRM/PMS integration rows are visible to owner/manager only (RLS), so
// those two steps may read as incomplete for staff/viewer even when connected.
export async function getOnboardingReadiness(orgId: string | null): Promise<OnboardingStep[]> {
  const [org, members, crm, pms, guests, reservations] = await Promise.all([
    orgId ? getOrganization(orgId) : Promise.resolve(null),
    orgId ? listTeamMembers(orgId) : Promise.resolve([]),
    listCrmIntegrations(),
    listPmsIntegrations(),
    listGuests(),
    listReservations(),
  ])

  // A configured team means more than just the founding owner — at least one
  // additional active membership.
  const activeMembers = members.filter((m) => m.status === 'active')

  const core: OnboardingStep[] = [
    {
      key: 'organization',
      label: 'Organization Created',
      description: 'Your organization record exists and is active.',
      complete: !!org,
      detail: org ? `${org.name} · ${org.status}` : 'No organization in session',
    },
    {
      key: 'team',
      label: 'Team Configured',
      description: 'At least one teammate has been added beyond the owner.',
      complete: activeMembers.length >= 2,
      detail: `${activeMembers.length} active member${activeMembers.length === 1 ? '' : 's'}`,
    },
    {
      key: 'crm',
      label: 'CRM Connected',
      description: 'A CRM integration (e.g. GoHighLevel) is connected.',
      complete: crm.length > 0,
      detail: `${crm.length} CRM integration${crm.length === 1 ? '' : 's'}`,
    },
    {
      key: 'pms',
      label: 'PMS Connected',
      description: 'A property-management / reservation source is connected.',
      complete: pms.length > 0,
      detail: `${pms.length} PMS integration${pms.length === 1 ? '' : 's'}`,
    },
    {
      key: 'first_guest',
      label: 'First Guest Imported',
      description: 'At least one guest profile exists.',
      complete: guests.length > 0,
      detail: `${guests.length} guest${guests.length === 1 ? '' : 's'}`,
    },
    {
      key: 'first_reservation',
      label: 'First Reservation Imported',
      description: 'At least one reservation has been captured.',
      complete: reservations.length > 0,
      detail: `${reservations.length} reservation${reservations.length === 1 ? '' : 's'}`,
    },
  ]

  const completed = core.filter((s) => s.complete).length

  const goLive: OnboardingStep = {
    key: 'go_live',
    label: 'Ready For Go Live',
    description: 'All setup steps above are complete.',
    complete: completed === core.length,
    detail: `${completed} of ${core.length} steps complete`,
  }

  return [...core, goLive]
}
