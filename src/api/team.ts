import { supabase } from '../lib/supabase'
import { listProperties } from './properties'
import type {
  TeamMember,
  TeamInvitation,
  UsersRow,
  UserRolesRow,
  InvitationsRow,
} from '../lib/types'

function scopeLabel(propertyId: string | null, propertyNames: Map<string, string>): string {
  if (!propertyId) return 'Organization-wide'
  return propertyNames.get(propertyId) ?? 'Property'
}

// READ: members = user_roles (org-scoped) joined client-side to users.
// Explicit columns only. auth_user_id / active_org_id are not selectable
// (omitted from UsersRow), so they can never reach the client.
export async function listTeamMembers(orgId: string): Promise<TeamMember[]> {
  const [rolesRes, usersRes, properties] = await Promise.all([
    supabase
      .from('user_roles')
      .select('id,user_id,organization_id,property_id,role,revoked_at,created_at')
      .eq('organization_id', orgId)
      .order('created_at', { ascending: true }),
    supabase.from('users').select('id,email,full_name'),
    listProperties(),
  ])
  if (rolesRes.error) throw rolesRes.error
  if (usersRes.error) throw usersRes.error

  const roles = (rolesRes.data ?? []) as UserRolesRow[]
  const users = (usersRes.data ?? []) as UsersRow[]
  const userById = new Map(users.map((u) => [u.id, u]))
  const propertyNames = new Map(properties.map((p) => [p.id, p.name]))

  // One row per membership (handles multi-property users naturally).
  return roles.map((r): TeamMember => {
    const u = userById.get(r.user_id)
    return {
      membershipId: r.id,
      userId: r.user_id,
      name: u?.full_name ?? '—',
      email: u?.email ?? '—',
      role: r.role,
      scope: scopeLabel(r.property_id, propertyNames),
      status: r.revoked_at ? 'revoked' : 'active',
    }
  })
}

// READ: pending invitations (not accepted, not revoked). Explicit columns —
// token is never requested (omitted from InvitationsRow). RLS already limits
// visibility to owner/manager; the page additionally gates the section.
export async function listPendingInvitations(orgId: string): Promise<TeamInvitation[]> {
  const { data, error } = await supabase
    .from('invitations')
    .select('id,organization_id,invited_email,role,property_id,expires_at,accepted_at,accepted_by,created_by,revoked_at,created_at')
    .eq('organization_id', orgId)
    .is('accepted_at', null)
    .is('revoked_at', null)
    .order('created_at', { ascending: false })
  if (error) throw error

  const now = Date.now()
  return ((data ?? []) as InvitationsRow[]).map((i): TeamInvitation => ({
    id: i.id,
    email: i.invited_email,
    role: i.role,
    scope: i.property_id ? 'Property' : 'Organization-wide',
    expiresAt: i.expires_at,
    status: new Date(i.expires_at).getTime() < now ? 'expired' : 'pending',
  }))
}
