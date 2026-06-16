# PHASE2_DASHBOARD_PLAN.md
# Campground OS — Phase 2 Dashboard Foundation (Refactor Plan)

**Document Status:** Implementation plan (Phase 2 of [PROJECT_ROADMAP.md](PROJECT_ROADMAP.md))
**Date:** 2026-06-13
**Authoritative backend reference:** [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md) — **immutable**. No database/schema/security changes are proposed here.

> Scope guardrails (per task): refactor the existing dashboard — do **not** rebuild. Preserve reusable components. Replace architecture-demo pages with production pages matching the approved IA. **No new features, no AI, no automation builders, no roadmap items.** All reads use safe views where one exists; all guest/reservation writes go through RPCs.

---

## SECTION 1 — Codebase Audit

The existing app is the v1 single-tenant demo: 4 routes, anonymous reads, direct table writes, Make.com-era copy. It predates the v7 security flip.

### File-by-file classification

| File | Verdict | Reason |
|---|---|---|
| `src/main.tsx` | **Keep** | Standard Vite entry. |
| `src/index.css` | **Keep** | Tailwind directives + base styles. |
| `tailwind.config.ts` | **Keep** | `forest`/`bark` theme, Inter font — the brand. Reuse as-is. |
| `src/components/ui/Card.tsx` | **Keep** | Generic, prop-driven. |
| `src/components/ui/Spinner.tsx` | **Keep** | Generic. |
| `src/components/ui/Badge.tsx` | **Keep** | Variants cover tiers + reservation statuses already. |
| `src/components/dashboard/KPICard.tsx` | **Keep (move → `ui/`)** | Generic metric card; belongs in `ui/`. |
| `src/components/dashboard/GuestsTable.tsx` | **Refactor (light)** | Reusable on the Guests page; update for new `GuestSummary` fields. |
| `src/components/dashboard/ReservationsTable.tsx` | **Refactor (light)** | Reusable on the Reservations page; add property column. |
| `src/lib/supabase.ts` | **Refactor** | Add `<Database>` generic + session persistence; keep singleton pattern. |
| `src/lib/types.ts` | **Refactor (significant)** | **Stale vs v7** — see §1.1. |
| `src/pages/DashboardPage.tsx` | **Refactor** | Keep KPI + tier + tables; remove webhook log + "fed by Make.com" copy; scope to active org. |
| `src/components/layout/Navbar.tsx` | **Refactor → `AppLayout` + `Sidebar`** | New 9-item IA, org switcher, sign-out. Keep brand block. |
| `src/components/reservation/ReservationForm.tsx` | **Refactor** | Direct `insert` is now revoked — must call `upsert_guest` + `create_reservation` RPCs. |
| `src/pages/ReservationPage.tsx` | **Replace** | Demo (payload preview + "automation steps"). Becomes the production Reservations page. |
| `src/components/reservation/WebhookPayloadPreview.tsx` | **Delete** | Demo-only; not in approved IA. |
| `src/components/dashboard/WebhookEventLog.tsx` | **Delete (out of IA)** | `webhook_events` is not an approved page. Remove from scope. |
| `src/pages/ArchitecturePage.tsx` | **Delete** | Demo. Not in IA. |
| `src/pages/ApiDocsPage.tsx` | **Delete** | Demo. Not in IA. |

### 1.1 — Stale types (must fix before any data work)

`src/lib/types.ts` does not match the v7 views (CHECKPOINT_V3 §4, §8):

- `GuestSummary` is missing `organization_id`, `confirmed_visits`, `crm_contact_ids`, `crm_synced_at`. (Names/`ghl_contact_id` are now sourced from `guest_org_profiles`, not the global guest row.)
- `ReservationDetail` is missing `organization_id`, `property_id`, `property_name`.
- `KpiSummary` is missing `active_crm_integrations`.
- The `Database` generic exposes **direct Insert/Update** on `guests`/`reservations` (now revoked) and references `calculate_tier(visits)` (dropped in v6) instead of the `upsert_guest` / `create_reservation` RPCs.

This file is refactored in §8.2 — it's the contract everything else compiles against.

### 1.2 — Security posture gaps in current code

| Current behavior | Required (v7) |
|---|---|
| Anonymous reads (no auth) | Authenticate first; anon has zero access. |
| `supabase.from('guests').insert(...)` | `supabase.rpc('upsert_guest', …)`. |
| Direct `reservations` insert | `supabase.rpc('create_reservation', …)`. |
| No org context | `OrgContext` from `user_accessible_orgs`; queries rely on RLS scoping. |
| Reads `webhook_events` directly | Out of IA — removed. |

---

## SECTION 2 — Refactor Strategy (not rebuild)

1. **Preserve the design system.** `Card`, `Spinner`, `Badge`, `KPICard`, the Tailwind theme, and `index.css` carry forward unchanged (KPICard relocates to `ui/`).
2. **Preserve the two data tables.** `GuestsTable` and `ReservationsTable` keep their markup; only their prop types widen to the new view shapes.
3. **Wrap, don't replace, the shell.** `Navbar` becomes part of an `AppLayout` (sidebar IA + topbar org switcher + sign-out). The Dashboard page keeps its KPI/tier/table structure.
4. **Insert the missing layers** the demo never had: auth (`AuthProvider`, Login, `ProtectedRoute`), org context (`OrgProvider`), and a typed data-access layer (`src/api/*`) that is the *only* place `supabase` is touched by feature code.
5. **Delete demo surface** (Architecture, API Docs, webhook preview/log) — they have no place in the approved IA.
6. **Convert writes to RPCs.** No feature code calls `.insert()`/`.update()` on `guests`; reservations are created via RPC and status-updated via the permitted `tenant_reservations_update` policy.

**Net effect:** ~70% of the UI primitives survive; the data and security plumbing is new; the page roster changes from 4 demo routes to the 9-area approved IA.

---

## SECTION 3 — Reusable Component Inventory (carried forward)

| Component | Destination | Change |
|---|---|---|
| `Card` | `ui/Card.tsx` | none |
| `Spinner` | `ui/Spinner.tsx` | none |
| `Badge` | `ui/Badge.tsx` | none (variants already cover tiers + statuses) |
| `KPICard` | `ui/KPICard.tsx` | move only |
| `GuestsTable` | `features/guests/GuestsTable.tsx` | widen prop type |
| `ReservationsTable` | `features/reservations/ReservationsTable.tsx` | add property column |
| Tailwind theme / `index.css` | unchanged | none |
| brand block (from `Navbar`) | `layout/Sidebar.tsx` | reused inside new sidebar |

---

## SECTION 4 — Demo → Production Page Map (approved IA)

Approved IA: **Dashboard · Guests · Reservations · Properties · Team · Integrations (CRM / PMS) · Onboarding · Settings.**

| Approved page | Source | Primary data source |
|---|---|---|
| Dashboard | refactor `DashboardPage` | `kpi_summary`, `guest_summary`, `reservation_detail` (safe views) |
| Guests | new (reuses `GuestsTable`) | `guest_summary`; write via `upsert_guest` RPC |
| Reservations | replace demo `ReservationPage` (reuses `ReservationsTable` + refactored `ReservationForm`) | `reservation_detail`; create via `create_reservation` RPC; status via `reservations` UPDATE |
| Properties | new | `properties` (explicit columns); write owner/manager |
| Team | new | `users` + `user_roles` (+ `invitations` insert) |
| Integrations · CRM | new | `crm_integrations_safe` (read); `crm_integrations` (write, owner) |
| Integrations · PMS | new | `pms_integrations_safe` (read); `pms_integrations` (write, owner) |
| Onboarding | new | `onboarding_sessions` |
| Settings | new | `organizations` (explicit columns) + `loyalty_config` |
| ~~Architecture~~ | **deleted** | — |
| ~~API Docs~~ | **deleted** | — |
| ~~Webhook log/preview~~ | **deleted** | — |

---

## SECTION 5 — Phased Implementation Plan (sub-phases of Phase 2)

| Sub-phase | Deliverable | Exit criteria |
|---|---|---|
| **2.0 Foundation** | Folder restructure, `Database` types refresh, supabase client w/ generic, `AuthProvider` + Login + `ProtectedRoute`, `OrgProvider` + switcher, `AppLayout` + Sidebar, delete demo files | Authenticated user lands on an empty shell scoped to their active org; org switch works (refreshSession). |
| **2.1 Dashboard** | Refactor `DashboardPage` to safe-view reads, org-scoped | KPIs + tier breakdown + guest/reservation tables render for the active org only. |
| **2.2 Guests** | Guests list + create-guest (RPC) | Operator lists guests (`guest_summary`) and creates one via `upsert_guest`. |
| **2.3 Reservations** | Reservations list + create (RPC) + status update | Operator lists (`reservation_detail`), creates via `create_reservation`, advances status. |
| **2.4 Properties** | Properties list + create/edit | Owner/manager manages properties. |
| **2.5 Org Settings** | Organization name + `loyalty_config` | Owner edits org name + tier thresholds. |

> Team, Integrations, and Onboarding pages are **Phase 3** (Staff & Administration) per the roadmap, but their data-access modules are scaffolded in 2.0 so the IA renders end-to-end. This document delivers the full **Phase 2 Dashboard Foundation** (2.0–2.5) and the data layer for Phase 3.

---

## SECTION 6 — Exact Folder Structure

```
src/
├── main.tsx                      # keep
├── App.tsx                       # refactor — routing + providers
├── index.css                     # keep
├── vite-env.d.ts                 # keep
│
├── lib/
│   ├── supabase.ts               # refactor — typed client + session persistence
│   └── types.ts                  # refactor — v7-accurate Database + view/RPC types
│
├── api/                          # NEW — the ONLY place feature code touches supabase
│   ├── kpi.ts                    # kpi_summary
│   ├── guests.ts                 # guest_summary (read) + upsert_guest (write)
│   ├── reservations.ts           # reservation_detail (read) + create_reservation / status update
│   ├── properties.ts             # properties (explicit cols)
│   ├── team.ts                   # users + user_roles + invitations  (Phase 3 data layer)
│   ├── integrations.ts           # *_safe (read) + base tables (write, owner)  (Phase 3)
│   ├── onboarding.ts             # onboarding_sessions  (Phase 3)
│   └── orgs.ts                   # user_accessible_orgs + active-org switch + org settings + loyalty_config
│
├── context/                      # NEW
│   ├── AuthProvider.tsx          # session + sign in/out
│   └── OrgProvider.tsx           # active org + accessible orgs + switchOrg()
│
├── components/
│   ├── ui/                       # design system (carried forward)
│   │   ├── Card.tsx              # keep
│   │   ├── Spinner.tsx           # keep
│   │   ├── Badge.tsx             # keep
│   │   └── KPICard.tsx           # moved from dashboard/
│   ├── layout/                   # NEW shell
│   │   ├── AppLayout.tsx         # sidebar + topbar + <Outlet/>
│   │   ├── Sidebar.tsx           # 9-item IA nav (brand block reused)
│   │   ├── Topbar.tsx            # org switcher + user menu/sign-out
│   │   └── ProtectedRoute.tsx    # gate unauthenticated users
│   └── common/
│       ├── PageHeader.tsx        # title + subtitle + actions
│       ├── DataState.tsx         # loading / error / empty wrapper
│       └── TierBadge.tsx         # thin wrapper over Badge for tiers
│
├── features/                     # NEW — one folder per IA area
│   ├── dashboard/DashboardPage.tsx
│   ├── guests/{GuestsPage.tsx, GuestsTable.tsx, GuestFormModal.tsx}
│   ├── reservations/{ReservationsPage.tsx, ReservationsTable.tsx, ReservationForm.tsx}
│   ├── properties/{PropertiesPage.tsx, PropertyFormModal.tsx}
│   ├── team/TeamPage.tsx                       # Phase 3
│   ├── integrations/{CrmSettingsPage.tsx, PmsSettingsPage.tsx}   # Phase 3
│   ├── onboarding/OnboardingPage.tsx           # Phase 3
│   └── settings/SettingsPage.tsx
│
└── pages/
    └── LoginPage.tsx             # NEW — only public route

# DELETED: pages/ArchitecturePage.tsx, pages/ApiDocsPage.tsx,
#          pages/ReservationPage.tsx (demo), components/reservation/WebhookPayloadPreview.tsx,
#          components/dashboard/WebhookEventLog.tsx
```

---

## SECTION 7 — React Routing Structure

Public `/login`; everything else is behind `ProtectedRoute` + `AppLayout` and requires an active org.

```tsx
// src/App.tsx
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider } from './context/AuthProvider'
import { OrgProvider } from './context/OrgProvider'
import { ProtectedRoute } from './components/layout/ProtectedRoute'
import { AppLayout } from './components/layout/AppLayout'
import { LoginPage } from './pages/LoginPage'
import { DashboardPage } from './features/dashboard/DashboardPage'
import { GuestsPage } from './features/guests/GuestsPage'
import { ReservationsPage } from './features/reservations/ReservationsPage'
import { PropertiesPage } from './features/properties/PropertiesPage'
import { TeamPage } from './features/team/TeamPage'
import { CrmSettingsPage } from './features/integrations/CrmSettingsPage'
import { PmsSettingsPage } from './features/integrations/PmsSettingsPage'
import { OnboardingPage } from './features/onboarding/OnboardingPage'
import { SettingsPage } from './features/settings/SettingsPage'

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            element={
              <ProtectedRoute>
                <OrgProvider>
                  <AppLayout />
                </OrgProvider>
              </ProtectedRoute>
            }
          >
            <Route path="/"             element={<DashboardPage />} />
            <Route path="/guests"       element={<GuestsPage />} />
            <Route path="/reservations" element={<ReservationsPage />} />
            <Route path="/properties"   element={<PropertiesPage />} />
            <Route path="/team"         element={<TeamPage />} />
            <Route path="/integrations/crm" element={<CrmSettingsPage />} />
            <Route path="/integrations/pms" element={<PmsSettingsPage />} />
            <Route path="/onboarding"   element={<OnboardingPage />} />
            <Route path="/settings"     element={<SettingsPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  )
}
```

```tsx
// src/components/layout/ProtectedRoute.tsx
import { Navigate } from 'react-router-dom'
import { useAuth } from '../../context/AuthProvider'
import { Spinner } from '../ui/Spinner'

export function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { session, loading } = useAuth()
  if (loading) return <div className="flex justify-center py-24"><Spinner size="lg" /></div>
  if (!session) return <Navigate to="/login" replace />
  return <>{children}</>
}
```

```tsx
// src/components/layout/AppLayout.tsx
import { Outlet } from 'react-router-dom'
import { Sidebar } from './Sidebar'
import { Topbar } from './Topbar'

export function AppLayout() {
  return (
    <div className="min-h-screen bg-gray-50 flex">
      <Sidebar />
      <div className="flex-1 flex flex-col min-w-0">
        <Topbar />
        <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
```

```tsx
// src/components/layout/Sidebar.tsx  (brand block reused from old Navbar)
import { NavLink } from 'react-router-dom'

const nav = [
  { to: '/',               label: 'Dashboard' },
  { to: '/guests',         label: 'Guests' },
  { to: '/reservations',   label: 'Reservations' },
  { to: '/properties',     label: 'Properties' },
  { to: '/team',           label: 'Team' },
  { to: '/integrations/crm', label: 'CRM' },
  { to: '/integrations/pms', label: 'PMS' },
  { to: '/onboarding',     label: 'Onboarding' },
  { to: '/settings',       label: 'Settings' },
]

export function Sidebar() {
  return (
    <aside className="w-60 shrink-0 bg-white border-r border-gray-200 hidden md:flex flex-col">
      <div className="h-16 flex items-center gap-2 px-5 border-b border-gray-100">
        <span className="text-2xl">&#9978;</span>
        <span className="font-bold text-forest-700 text-lg tracking-tight">CampBase</span>
      </div>
      <nav className="flex-1 p-3 space-y-1">
        {nav.map(({ to, label }) => (
          <NavLink key={to} to={to} end={to === '/'}
            className={({ isActive }) =>
              `block px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                isActive ? 'bg-forest-50 text-forest-700' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'
              }`}>
            {label}
          </NavLink>
        ))}
      </nav>
    </aside>
  )
}
```

---

## SECTION 8 — Supabase Data-Access Layer

**Rule:** feature components never import `supabase` directly. They call `src/api/*` functions. Every read targets a **safe view** when one exists; every guest/reservation write targets an **RPC**.

### 8.1 — Typed client

```ts
// src/lib/supabase.ts
import { createClient } from '@supabase/supabase-js'
import type { Database } from './types'

const url = import.meta.env.VITE_SUPABASE_URL as string
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY as string
if (!url || !anon) throw new Error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY')

export const supabase = createClient<Database>(url, anon, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
})
```

### 8.2 — Types refresh (v7-accurate)

```ts
// src/lib/types.ts  (key shapes — replaces stale demo types)

// ---- Safe-view rows (read models) ----
export interface KpiSummary {
  total_guests: number; total_reservations: number; returning_guests: number
  bronze_guests: number; silver_guests: number; gold_guests: number
  estimated_revenue: number; synced_contacts: number
  active_crm_integrations: number; pending_webhooks: number; failed_webhooks: number
}

export interface GuestSummary {
  id: string; first_name: string; last_name: string; full_name: string
  email: string; phone: string | null
  ghl_contact_id: string | null
  crm_contact_ids: Record<string, string> | null
  organization_id: string
  total_visits: number; confirmed_visits: number; total_spend: number
  loyalty_tier: 'Bronze' | 'Silver' | 'Gold'
  last_visit: string | null; crm_synced_at: string | null; created_at: string
}

export interface ReservationDetail {
  id: string; external_reservation_id: string | null
  organization_id: string; property_id: string | null; property_name: string | null
  guest_id: string; guest_name: string; email: string
  site_number: string; check_in: string; check_out: string; num_nights: number
  num_guests: number; nightly_rate: number | null; total_amount: number | null
  status: 'confirmed' | 'checked_in' | 'checked_out' | 'cancelled'
  notes: string | null; created_at: string
}

export interface CrmIntegrationSafe {
  id: string; organization_id: string
  provider: 'gohighlevel' | 'hubspot' | 'salesforce' | 'none'
  name: string; external_account_id: string | null
  config: Record<string, unknown>; status: 'active' | 'inactive' | 'error'
  last_sync_at: string | null; created_at: string; updated_at: string
}

export interface PmsIntegrationSafe {
  id: string; organization_id: string
  provider: 'campspot' | 'rezworks' | 'hostfully' | 'rvshare' | 'hipcamp' | 'direct' | 'none'
  name: string; external_property_id: string | null
  config: Record<string, unknown>
  sync_direction: 'inbound' | 'bidirectional' | 'outbound'
  status: 'active' | 'inactive' | 'error'
  last_sync_at: string | null; created_at: string; updated_at: string
}

export interface UserAccessibleOrg {
  organization_id: string; organization_name: string
  role: 'owner' | 'manager' | 'staff' | 'viewer'
  property_id: string | null; is_org_wide: boolean
}

// ---- RPC argument shapes ----
export interface UpsertGuestArgs {
  p_first_name: string; p_last_name: string; p_email: string; p_phone?: string | null
}
export interface CreateReservationArgs {
  p_guest_id: string; p_property_id: string; p_site_number: string
  p_check_in: string; p_check_out: string
  p_num_guests?: number; p_nightly_rate?: number | null
  p_total_amount?: number | null; p_notes?: string | null
}

// ---- Database generic: views read-only, writes via RPC ----
export interface Database {
  public: {
    Tables: {
      properties: { Row: { id: string; organization_id: string; name: string; location: string | null; status: 'active' | 'inactive'; created_at: string; updated_at: string }; Insert: { organization_id: string; name: string; location?: string | null; status?: 'active' | 'inactive' }; Update: Partial<{ name: string; location: string | null; status: 'active' | 'inactive' }>; Relationships: [] }
      reservations: { Row: Record<string, unknown>; Insert: never; Update: Partial<{ status: ReservationDetail['status']; notes: string | null }>; Relationships: [] } // INSERT revoked → use create_reservation()
      organizations: { Row: { id: string; name: string; slug: string; plan: string; status: string; created_at: string; updated_at: string }; Insert: never; Update: Partial<{ name: string }>; Relationships: [] }
      loyalty_config: { Row: { id: string; organization_id: string; silver_threshold: number; gold_threshold: number; created_at: string; updated_at: string }; Insert: { organization_id: string; silver_threshold?: number; gold_threshold?: number }; Update: Partial<{ silver_threshold: number; gold_threshold: number }>; Relationships: [] }
      // users / user_roles / invitations / crm_integrations / pms_integrations / onboarding_sessions added in Phase 3
    }
    Views: {
      kpi_summary:          { Row: KpiSummary;        Relationships: [] }
      guest_summary:        { Row: GuestSummary;      Relationships: [] }
      reservation_detail:   { Row: ReservationDetail; Relationships: [] }
      crm_integrations_safe:{ Row: CrmIntegrationSafe;Relationships: [] }
      pms_integrations_safe:{ Row: PmsIntegrationSafe;Relationships: [] }
      user_accessible_orgs: { Row: UserAccessibleOrg; Relationships: [] }
    }
    Functions: {
      upsert_guest:       { Args: UpsertGuestArgs;       Returns: string }
      create_reservation: { Args: CreateReservationArgs; Returns: string }
    }
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
```

### 8.3 — API modules (safe views + RPCs)

```ts
// src/api/kpi.ts
import { supabase } from '../lib/supabase'
import type { KpiSummary } from '../lib/types'

export async function fetchKpiSummary(): Promise<KpiSummary> {
  // kpi_summary is security_invoker → already scoped to the caller's active org.
  const { data, error } = await supabase.from('kpi_summary').select('*').single()
  if (error) throw error
  return data as KpiSummary
}
```

```ts
// src/api/guests.ts
import { supabase } from '../lib/supabase'
import type { GuestSummary, UpsertGuestArgs } from '../lib/types'

// READ: safe view (PII sourced from guest_org_profiles; RLS scopes to active org)
export async function listGuests(): Promise<GuestSummary[]> {
  const { data, error } = await supabase
    .from('guest_summary').select('*')
    .order('total_visits', { ascending: false })
  if (error) throw error
  return (data ?? []) as GuestSummary[]
}

// WRITE: RPC only (direct guests INSERT is revoked). Returns guest_id.
export async function upsertGuest(args: UpsertGuestArgs): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_guest', args)
  if (error) throw error
  return data as string
}
```

```ts
// src/api/reservations.ts
import { supabase } from '../lib/supabase'
import type { ReservationDetail, CreateReservationArgs } from '../lib/types'

// READ: safe view (org-scoped; guest name from guest_org_profiles)
export async function listReservations(limit = 100): Promise<ReservationDetail[]> {
  const { data, error } = await supabase
    .from('reservation_detail').select('*')
    .order('created_at', { ascending: false }).limit(limit)
  if (error) throw error
  return (data ?? []) as ReservationDetail[]
}

// WRITE: RPC only (direct reservations INSERT is revoked). Binds guest+property to JWT org.
export async function createReservation(args: CreateReservationArgs): Promise<string> {
  const { data, error } = await supabase.rpc('create_reservation', args)
  if (error) throw error
  return data as string
}

// Status transition is permitted by tenant_reservations_update (owner/manager/staff).
export async function updateReservationStatus(id: string, status: ReservationDetail['status']) {
  const { error } = await supabase.from('reservations').update({ status }).eq('id', id)
  if (error) throw error
}
```

```ts
// src/api/properties.ts  (no secrets → explicit columns, not SELECT *)
import { supabase } from '../lib/supabase'

export interface Property {
  id: string; organization_id: string; name: string
  location: string | null; status: 'active' | 'inactive'
}

export async function listProperties(): Promise<Property[]> {
  const { data, error } = await supabase
    .from('properties').select('id,organization_id,name,location,status')
    .order('name')
  if (error) throw error
  return (data ?? []) as Property[]
}

export async function createProperty(organization_id: string, name: string, location?: string) {
  const { error } = await supabase.from('properties').insert({ organization_id, name, location })
  if (error) throw error
}
```

```ts
// src/api/orgs.ts  (org switch + org settings + loyalty_config)
import { supabase } from '../lib/supabase'
import type { UserAccessibleOrg } from '../lib/types'

export async function listAccessibleOrgs(): Promise<UserAccessibleOrg[]> {
  const { data, error } = await supabase.from('user_accessible_orgs').select('*')
  if (error) throw error
  return (data ?? []) as UserAccessibleOrg[]
}

// Switch active org: update own users row, then refresh JWT so the hook re-enriches claims.
export async function switchActiveOrg(orgId: string) {
  const { data: u } = await supabase.auth.getUser()
  const authId = u.user?.id
  if (!authId) throw new Error('Not authenticated')
  const { error } = await supabase.from('users').update({ active_org_id: orgId }).eq('auth_user_id', authId)
  if (error) throw error
  await supabase.auth.refreshSession()
}

// Org settings: NEVER select * (column-locked). Explicit columns only.
export async function getOrgSettings(orgId: string) {
  const { data, error } = await supabase
    .from('organizations').select('id,name,slug,plan,status').eq('id', orgId).single()
  if (error) throw error
  return data
}
export async function renameOrg(orgId: string, name: string) {
  const { error } = await supabase.from('organizations').update({ name }).eq('id', orgId)
  if (error) throw error // owner-only per RLS; slug/plan/status blocked by trigger
}
export async function getLoyaltyConfig(orgId: string) {
  const { data, error } = await supabase
    .from('loyalty_config').select('silver_threshold,gold_threshold').eq('organization_id', orgId).single()
  if (error) throw error
  return data
}
```

> **Phase 3 stubs** (`team.ts`, `integrations.ts`, `onboarding.ts`) follow the identical pattern: read `crm_integrations_safe` / `pms_integrations_safe` (never the base tables for display); write to base `crm_integrations` / `pms_integrations` (owner only, credentials write-only); `team.ts` reads `user_accessible_orgs` + `user_roles` and inserts `invitations` (the `claim_invitation()` claim flow is a deferred backend item — CHECKPOINT_V3 §16).

### 8.4 — Context providers

```tsx
// src/context/AuthProvider.tsx
import { createContext, useContext, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'

const Ctx = createContext<{ session: Session | null; loading: boolean
  signIn: (e: string, p: string) => Promise<void>; signOut: () => Promise<void> }>(null!)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setLoading(false) })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])
  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
  }
  const signOut = async () => { await supabase.auth.signOut() }
  return <Ctx.Provider value={{ session, loading, signIn, signOut }}>{children}</Ctx.Provider>
}
export const useAuth = () => useContext(Ctx)
```

```tsx
// src/context/OrgProvider.tsx
import { createContext, useContext, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { listAccessibleOrgs, switchActiveOrg } from '../api/orgs'
import type { UserAccessibleOrg } from '../lib/types'

const Ctx = createContext<{ activeOrgId: string | null; role: string | null
  orgs: UserAccessibleOrg[]; switchOrg: (id: string) => Promise<void> }>(null!)

export function OrgProvider({ children }: { children: React.ReactNode }) {
  const [orgs, setOrgs] = useState<UserAccessibleOrg[]>([])
  const [activeOrgId, setActiveOrgId] = useState<string | null>(null)
  const [role, setRole] = useState<string | null>(null)
  useEffect(() => {
    void (async () => {
      const { data } = await supabase.auth.getSession()
      const meta = data.session?.user.app_metadata as { org_id?: string; user_role?: string } | undefined
      setActiveOrgId(meta?.org_id ?? null)
      setRole(meta?.user_role ?? null)
      setOrgs(await listAccessibleOrgs())
    })()
  }, [])
  const switchOrg = async (id: string) => { await switchActiveOrg(id); setActiveOrgId(id) }
  return <Ctx.Provider value={{ activeOrgId, role, orgs, switchOrg }}>{children}</Ctx.Provider>
}
export const useOrg = () => useContext(Ctx)
```

---

## SECTION 9 — Safe-View Read Pattern (enforced)

| Need | Source | Module | Why |
|---|---|---|---|
| KPIs | `kpi_summary` (view) | `kpi.ts` | per-tenant aggregates via `security_invoker` |
| Guest list / display | `guest_summary` (view) | `guests.ts` | PII from `guest_org_profiles`; never read `guests` name columns |
| Reservation list | `reservation_detail` (view) | `reservations.ts` | org-scoped + property name |
| CRM config display | `crm_integrations_safe` (view) | `integrations.ts` | excludes `credentials` |
| PMS config display | `pms_integrations_safe` (view) | `integrations.ts` | excludes `credentials` |
| Org switcher | `user_accessible_orgs` (view) | `orgs.ts` | all orgs/roles for current user |
| Properties | `properties` (table) | `properties.ts` | no view exists, no secrets → explicit columns |
| Org settings | `organizations` (table) | `orgs.ts` | no view → **explicit columns only** (`SELECT *` is column-locked) |
| Guest write | `upsert_guest` (RPC) | `guests.ts` | direct INSERT revoked |
| Reservation write | `create_reservation` (RPC) | `reservations.ts` | direct INSERT revoked |

**Hard rules baked into the data layer:**
- No `select('*')` on `organizations`, `crm_integrations`, `pms_integrations`, `invitations` — explicit columns or the `*_safe` view only.
- No `.insert()` on `guests` or `reservations` — RPC only.
- Feature components import from `src/api/*`, never `src/lib/supabase` directly.

---

## SECTION 10 — Phase 2 Execution Plan

Ordered, each step gated by the prior. (Reference: ROADMAP Phase 2; deploy must pass Phase 1 / DEPLOYMENT_VALIDATION_CHECKLIST first.)

| # | Step | Files | Done when |
|---|---|---|---|
| 1 | **Refresh types** | `lib/types.ts` | Project compiles against v7 view/RPC shapes; stale `Database` removed. |
| 2 | **Typed client** | `lib/supabase.ts` | `createClient<Database>` with session persistence. |
| 3 | **Delete demo surface** | remove Architecture, ApiDocs, demo Reservation, WebhookPayloadPreview, WebhookEventLog | No demo routes/components remain; build clean. |
| 4 | **Auth** | `context/AuthProvider.tsx`, `pages/LoginPage.tsx`, `components/layout/ProtectedRoute.tsx` | Unauthed → `/login`; valid login → app; sign-out works. |
| 5 | **Org context + shell** | `context/OrgProvider.tsx`, `layout/AppLayout.tsx`, `Sidebar.tsx`, `Topbar.tsx` | Sidebar shows 9 IA items; Topbar org switcher lists `user_accessible_orgs`; switching refreshes JWT and re-scopes. |
| 6 | **Data layer** | `api/kpi.ts`, `guests.ts`, `reservations.ts`, `properties.ts`, `orgs.ts` (+ Phase 3 stubs) | All reads via safe views; writes via RPC; no direct `supabase` use in features. |
| 7 | **Dashboard (2.1)** | `features/dashboard/DashboardPage.tsx` (refactor), move `KPICard`→`ui/` | KPIs + tiers + guest/reservation tables render for active org; no webhook/Make.com copy. |
| 8 | **Guests (2.2)** | `features/guests/*` (reuse `GuestsTable`) | List from `guest_summary`; create via `upsert_guest`. |
| 9 | **Reservations (2.3)** | `features/reservations/*` (reuse table; refactor form) | List from `reservation_detail`; create via `create_reservation`; status update works. |
| 10 | **Properties (2.4)** | `features/properties/*` | Owner/manager lists + creates properties. |
| 11 | **Org Settings (2.5)** | `features/settings/SettingsPage.tsx` | Owner edits org name + `loyalty_config`; blocked fields (slug/plan/status) not exposed. |

### Phase 2 Exit Criteria
- An authenticated operator signs in, sees only their active org's data, and can switch orgs (multi-org users).
- Dashboard, Guests, Reservations, Properties, and Settings are functional against the live backend.
- Every read uses a safe view where one exists; every guest/reservation write uses an RPC; no `SELECT *` on secret-bearing tables.
- No demo pages, no webhook UI, no Make.com references remain.
- **Operators can manage data** (ROADMAP Phase 2 exit). Team / Integrations / Onboarding pages render via the IA and are completed in Phase 3 (their data modules already exist).

### Out of Scope (do not build here)
AI concierge, automation/N8N builders, revenue intelligence, maintenance routing, invitation **claim** flow (backend-deferred), feature entitlements, or any schema/RLS change. The backend is immutable.

---

*End of PHASE2_DASHBOARD_PLAN.md. Backend contract: [PROJECT_CHECKPOINT_V3.md](PROJECT_CHECKPOINT_V3.md). Sequencing: [PROJECT_ROADMAP.md](PROJECT_ROADMAP.md). Pre-deploy gate: [DEPLOYMENT_VALIDATION_CHECKLIST.md](DEPLOYMENT_VALIDATION_CHECKLIST.md).*
