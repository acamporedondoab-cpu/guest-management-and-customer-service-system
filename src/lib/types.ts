// ============================================================
// TypeScript types — aligned to the v7 backend (CHECKPOINT_V3 §4, §8).
//
// Reads target SAFE VIEWS (security_invoker, org-scoped).
// Guest/reservation WRITES go through RPCs (upsert_guest /
// create_reservation) — direct INSERT on guests/reservations is revoked.
//
// The global `guests` row exposes only (id, email) to the app; all
// guest PII (name, phone, CRM ids) is sourced from guest_org_profiles
// and surfaced through guest_summary / reservation_detail.
// ============================================================

// ------------------------------------------------------------
// Safe-view read models (what the views return)
// ------------------------------------------------------------

export interface KpiSummary {
  total_guests: number
  total_reservations: number
  returning_guests: number
  bronze_guests: number
  silver_guests: number
  gold_guests: number
  estimated_revenue: number
  synced_contacts: number
  active_crm_integrations: number
  pending_webhooks: number
  failed_webhooks: number
}

export interface GuestSummary {
  id: string
  first_name: string
  last_name: string
  full_name: string
  email: string
  phone: string | null
  ghl_contact_id: string | null
  crm_contact_ids: Record<string, string> | null
  organization_id: string
  total_visits: number
  confirmed_visits: number
  total_spend: number
  loyalty_tier: 'Bronze' | 'Silver' | 'Gold'
  last_visit: string | null
  crm_synced_at: string | null
  created_at: string
}

export interface ReservationDetail {
  id: string
  external_reservation_id: string | null
  organization_id: string
  property_id: string | null
  property_name: string | null
  guest_id: string
  guest_name: string
  email: string
  site_number: string
  check_in: string
  check_out: string
  num_nights: number
  num_guests: number
  nightly_rate: number | null
  total_amount: number | null
  status: 'confirmed' | 'checked_in' | 'checked_out' | 'cancelled'
  notes: string | null
  created_at: string
}

// Frontend-facing masked credential metadata. This is the safe projection of
// crm_integrations.credential_ref. The backend column ALSO stores a non-secret
// `vault_secret_id` pointer, but it is DELIBERATELY OMITTED here so the type
// system forbids surfacing it in the UI — the dashboard only ever shows the
// masked last4 / token_type / expiry. The real secret lives in Supabase Vault
// and is readable only server-side via resolve_crm_secret() (service_role).
export interface CrmCredentialRef {
  token_type?: string
  last4?: string
  expires_at?: string | null
}

export interface CrmIntegrationSafe {
  id: string
  organization_id: string
  provider: 'gohighlevel' | 'hubspot' | 'salesforce' | 'none'
  name: string
  external_account_id: string | null
  // v8 auth model — drives connect/rotate branching and N8N consumption.
  auth_type: 'api_key' | 'private_token' | 'oauth2' | 'none'
  // Non-secret masked metadata only (see CrmCredentialRef). Never plaintext.
  credential_ref: CrmCredentialRef
  config: Record<string, unknown>
  status: 'active' | 'inactive' | 'error'
  // v8 audit + sync-health (all non-secret, surfaced by crm_integrations_safe).
  connected_at: string | null
  connected_by: string | null
  last_error: string | null
  last_error_at: string | null
  last_sync_at: string | null
  sync_cursor: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface PmsIntegrationSafe {
  id: string
  organization_id: string
  provider: 'campspot' | 'rezworks' | 'hostfully' | 'rvshare' | 'hipcamp' | 'direct' | 'none'
  name: string
  external_property_id: string | null
  config: Record<string, unknown>
  sync_direction: 'inbound' | 'bidirectional' | 'outbound'
  status: 'active' | 'inactive' | 'error'
  last_sync_at: string | null
  created_at: string
  updated_at: string
}

export interface UserAccessibleOrg {
  organization_id: string
  organization_name: string
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  property_id: string | null
  is_org_wide: boolean
}

// ------------------------------------------------------------
// Base-table row shapes used by the dashboard (explicit-column reads
// / permitted writes only — see Database generic below)
// ------------------------------------------------------------

export interface Property {
  id: string
  organization_id: string
  name: string
  location: string | null
  status: 'active' | 'inactive'
  created_at: string
  updated_at: string
}

export interface OrganizationSettings {
  id: string
  name: string
  slug: string
  plan: string
  status: string
  created_at: string
  updated_at: string
}

export interface LoyaltyConfig {
  id: string
  organization_id: string
  silver_threshold: number
  gold_threshold: number
  created_at: string
  updated_at: string
}

// ------------------------------------------------------------
// Team read models. These Row types are deliberate column allow-lists:
//   - UsersRow OMITS auth_user_id and active_org_id
//   - InvitationsRow OMITS token
// Because the typed client infers selectable columns from the Row, selecting
// any omitted column is a COMPILE error — the "never expose" rule is enforced
// by the type system, not just by convention.
// ------------------------------------------------------------

export interface UsersRow {
  id: string
  email: string
  full_name: string | null
}

export interface UserRolesRow {
  id: string
  user_id: string
  organization_id: string
  property_id: string | null
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  revoked_at: string | null
  created_at: string
}

export interface InvitationsRow {
  id: string
  organization_id: string
  invited_email: string
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  property_id: string | null
  expires_at: string
  accepted_at: string | null
  accepted_by: string | null
  created_by: string | null
  revoked_at: string | null
  created_at: string
}

// Joined / derived display rows for the Team page.
export interface TeamMember {
  membershipId: string          // user_roles.id — stable React key
  userId: string
  name: string
  email: string
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  scope: string                 // 'Organization-wide' or a property name
  status: 'active' | 'revoked'
}

export interface TeamInvitation {
  id: string
  email: string
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  scope: string
  expiresAt: string
  status: 'pending' | 'expired'
}

// ------------------------------------------------------------
// Onboarding readiness — derived (read-only) from existing production
// sources (organizations, user_roles/users, *_integrations_safe,
// guest_summary, reservation_detail). NOT backed by onboarding_sessions.
// ------------------------------------------------------------

export interface OnboardingStep {
  key: string
  label: string
  description: string
  complete: boolean
  detail: string                // short, human-readable evidence for the state
}

// ------------------------------------------------------------
// RPC argument shapes
// ------------------------------------------------------------

export interface UpsertGuestArgs {
  p_first_name: string
  p_last_name: string
  p_email: string
  p_phone?: string | null
}

export interface CreateReservationArgs {
  p_guest_id: string
  p_property_id: string
  p_site_number: string
  p_check_in: string
  p_check_out: string
  p_num_guests?: number
  p_nightly_rate?: number | null
  p_total_amount?: number | null
  p_notes?: string | null
}

// upsert_crm_integration() — owner-only CRM secret write path (v8). Covers the
// Phase 2 scope: Connect, Rotate (non-null p_secret on an existing org+provider
// row), and Config Edit (p_secret omitted/null preserves the existing secret).
// Disconnect is intentionally NOT modeled here — there is no disable/secret-clear
// path in v8; it is DEFERRED to a future additive migration.
// p_secret is write-only: it travels to the RPC and into Vault, and is never read
// back. Org/role/user are derived from the JWT server-side, never passed as args.
export interface UpsertCrmIntegrationArgs {
  p_provider: 'gohighlevel' | 'hubspot' | 'salesforce' | 'none'
  p_name: string
  p_external_account_id?: string | null
  p_auth_type?: 'api_key' | 'private_token' | 'oauth2' | 'none'
  p_config?: Record<string, unknown>
  p_secret?: string | null
  p_expires_at?: string | null
}

// Safe result returned by upsert_crm_integration() — masked fields only.
// Never contains plaintext or a usable secret (last4 is masked metadata).
export interface UpsertCrmIntegrationResult {
  id: string
  provider: 'gohighlevel' | 'hubspot' | 'salesforce' | 'none'
  name: string
  external_account_id: string | null
  auth_type: 'api_key' | 'private_token' | 'oauth2' | 'none'
  status: 'active' | 'inactive' | 'error'
  last4: string | null
  connected_at: string | null
}

// ------------------------------------------------------------
// Supabase Database generic (createClient<Database>)
//   Views   → read-only (safe views)
//   Tables  → only what the dashboard reads/writes; guests/reservations
//             carry no Insert (direct INSERT is revoked — use RPCs)
//   Functions → the two write RPCs
// ------------------------------------------------------------

export interface Database {
  public: {
    Tables: {
      properties: {
        Row: Property
        Insert: { organization_id: string; name: string; location?: string | null; status?: 'active' | 'inactive' }
        Update: Partial<{ name: string; location: string | null; status: 'active' | 'inactive' }>
        Relationships: []
      }
      // Direct INSERT revoked (RT-B2) — reservations are created via create_reservation().
      // UPDATE is allowed for status transitions by tenant_reservations_update.
      reservations: {
        Row: Record<string, unknown>
        Insert: never
        Update: Partial<{ status: ReservationDetail['status']; notes: string | null }>
        Relationships: []
      }
      // Column-locked: never SELECT * — read explicit columns (see OrganizationSettings).
      organizations: {
        Row: OrganizationSettings
        Insert: never
        Update: Partial<{ name: string }>
        Relationships: []
      }
      loyalty_config: {
        Row: LoyaltyConfig
        Insert: { organization_id: string; silver_threshold?: number; gold_threshold?: number }
        Update: Partial<{ silver_threshold: number; gold_threshold: number }>
        Relationships: []
      }
      // Read-only for the Team page. Row types are column allow-lists
      // (sensitive columns omitted on purpose). No writes wired (Team v1).
      users: {
        Row: UsersRow
        Insert: never
        Update: never
        Relationships: []
      }
      user_roles: {
        Row: UserRolesRow
        Insert: never
        Update: never
        Relationships: []
      }
      invitations: {
        Row: InvitationsRow
        Insert: never
        Update: never
        Relationships: []
      }
    }
    Views: {
      kpi_summary:           { Row: KpiSummary;         Relationships: [] }
      guest_summary:         { Row: GuestSummary;       Relationships: [] }
      reservation_detail:    { Row: ReservationDetail;  Relationships: [] }
      crm_integrations_safe: { Row: CrmIntegrationSafe; Relationships: [] }
      pms_integrations_safe: { Row: PmsIntegrationSafe; Relationships: [] }
      user_accessible_orgs:  { Row: UserAccessibleOrg;  Relationships: [] }
    }
    Functions: {
      upsert_guest:           { Args: UpsertGuestArgs;           Returns: string }
      create_reservation:     { Args: CreateReservationArgs;     Returns: string }
      // Owner-only CRM secret write path (Connect / Rotate / Config Edit).
      // resolve_crm_secret() is DELIBERATELY ABSENT: it is service_role-only
      // and must never be callable from the browser client.
      upsert_crm_integration: { Args: UpsertCrmIntegrationArgs;  Returns: UpsertCrmIntegrationResult }
    }
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
