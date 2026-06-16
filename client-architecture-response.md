# Architecture Overview — Multi-Campground Guest Management Platform

Prepared for: Joe Klich, Klich Consulting
Prepared by: [Your Name]
Date: 2026-06-12

---

## Thought Process

The central design question for a system supporting hundreds of campgrounds is: **what is the tenant?**

Two approaches exist:

- **Option A — Property as Tenant**: Each campground is a fully isolated account. Simple, but cannot support an owner who manages multiple campgrounds under one account. Any multi-property reporting or shared guest recognition requires a schema rewrite later.

- **Option B — Organization as Tenant**: Campground owners (organizations) sit above their properties. A single owner manages multiple campgrounds under one account, with full portfolio visibility. Data isolation is enforced at the organization level, not the property level.

I recommend **Option B** for this platform. The moment your second customer owns more than one campground, Option A breaks. Building the organization layer now costs some upfront complexity but eliminates a forced migration later.

---

## Primary Tables and Relationships

### 1. Organizations
The billing and access control entity. One row per campground owner or management group.

| Field | Purpose |
|---|---|
| `id` | Unique identifier (tenant key) |
| `name` | "Aries Hospitality Group" |
| `plan` | Subscription tier (Starter / Pro / Enterprise) |
| `ghl_location_id` | Links to their GoHighLevel sub-account |
| `make_webhook_secret` | Authenticates inbound Make.com payloads |
| `status` | active / suspended |

**One organization owns many properties.**

---

### 2. Properties
Individual campground locations. A single owner may have one or many.

| Field | Purpose |
|---|---|
| `id` | Unique identifier |
| `organization_id` | Which owner this campground belongs to |
| `name` | "North Campground" |
| `location` | Physical address or region |
| `total_sites` | Required for occupancy % calculations |
| `status` | active / inactive |

**One property belongs to one organization. One organization has many properties.**

---

### 3. Guests (Shared Identity Registry)

This table is intentionally minimal — it stores only what is needed to recognize a person across the entire platform.

| Field | Purpose |
|---|---|
| `id` | Unique identifier |
| `email` | UNIQUE — the universal deduplication key |
| `created_at` | First time this person appeared on the platform |

**No PII (name, phone) lives here.** That lives in the profile table below.

**Why separate?** If the same person books at two campgrounds owned by different companies, both campgrounds deserve to know their guest is a returning traveler — but neither should see the other company's notes, internal tags, or CRM data about that person.

---

### 4. Guest Organization Profiles

This is the junction table between a guest's universal identity and a specific organization's view of that guest. Every piece of PII and CRM data lives here, scoped to the organization that collected it.

| Field | Purpose |
|---|---|
| `guest_id` | Links to the shared identity |
| `organization_id` | Scopes all data to this owner |
| `first_name` | Name as entered at this property |
| `last_name` | |
| `phone` | |
| `ghl_contact_id` | This organization's GoHighLevel contact ID |
| `internal_notes` | Staff notes — never visible to other orgs |
| `deleted_at` | Soft delete for GDPR erasure requests |

**Unique constraint on `(guest_id, organization_id)`** — one profile per guest per organization.

This design solves two critical problems:
1. **Cross-tenant PII exposure**: Campground A cannot query Campground B's guest notes, phone numbers, or CRM IDs.
2. **GoHighLevel contact ID collision**: Each organization has its own GHL sub-account. A guest who books at two different management companies gets two separate GHL contact IDs — one per org — stored independently here.

---

### 5. Reservations

One row per booking event.

| Field | Purpose |
|---|---|
| `id` | Unique identifier |
| `organization_id` | Denormalized from property — enables fast data isolation checks |
| `property_id` | Which campground |
| `guest_id` | Who booked |
| `site_number` | Specific site |
| `check_in` / `check_out` | Stay dates |
| `nightly_rate` / `total_amount` | Revenue capture |
| `status` | confirmed / checked_in / checked_out / cancelled |
| `external_reservation_id` | Idempotency key — prevents duplicate inserts from automation retries |

**Why `organization_id` is copied onto reservations**: Data isolation rules must evaluate instantly without joining back through properties. Copying the owner ID here keeps permission checks to a single indexed equality check on every query.

---

### 6. Loyalty

Two tables — one for the guest's standing within a management group, one for property-level analytics.

**`loyalty` (org-wide tier)**

| Field | Purpose |
|---|---|
| `guest_id` + `organization_id` | Unique pair — one record per guest per org |
| `confirmed_visits` | Excludes cancelled and no-shows |
| `total_spend` | Lifetime spend within this organization |
| `tier` | Bronze / Silver / Gold |
| `last_visit` | Used for re-engagement campaigns |

**`loyalty_by_property` (property-level analytics)**

| Field | Purpose |
|---|---|
| `guest_id` + `property_id` | Which guest at which location |
| `organization_id` | Denormalized for access control |
| `confirmed_visits` | How many times they've stayed specifically here |
| `total_spend` | Revenue from this property only |

**Tier logic:**

| Tier | Threshold |
|---|---|
| Bronze | 1–2 confirmed visits within the organization |
| Silver | 3–5 confirmed visits |
| Gold | 6+ confirmed visits |

Tier is calculated at the **organization level** — a guest who visits North Campground twice and South Campground twice under the same owner is a Silver, not two separate Bronzes.

**Cancellation handling**: The trigger that updates loyalty only fires for non-cancelled reservations. A separate update trigger decrements loyalty if a reservation is later cancelled, using the original booking amount to reverse the spend accurately.

---

### 7. User Roles

Flexible permission table that supports both organization-wide administrators and property-scoped managers.

| Field | Purpose |
|---|---|
| `user_id` | The staff member |
| `organization_id` | Which owner they belong to |
| `property_id` | NULL = org-wide access; set = scoped to one property |
| `role` | owner / manager / staff / viewer |
| `revoked_at` | Soft revoke — preserves audit trail when staff leave |

**Examples:**
- Owner of Aries Hospitality: `organization_id = aries, property_id = NULL, role = owner` → sees all campgrounds
- Manager of North Campground only: `organization_id = aries, property_id = north, role = manager` → sees North only
- Regional manager across 3 of 5 properties: 3 rows, one per property

---

## How a Guest Staying at Multiple Campgrounds Works

### Scenario: Sarah books at two campgrounds under different owners

**Step 1 — First booking at Pine Valley Campground (owned by Lakewood Group)**
- `guests` table: one row created for sarah@example.com
- `guest_org_profiles`: one row created scoped to Lakewood Group with her name, phone, GHL contact ID in their sub-account
- `reservations`: one row scoped to Lakewood Group's organization ID
- `loyalty`: one row for Sarah within Lakewood Group — Bronze, 1 visit

**Step 2 — Six months later, Sarah books at River Bend Campground (owned by Summit Parks)**
- `guests` table: same row — email already exists, no duplicate
- `guest_org_profiles`: a NEW row created scoped to Summit Parks — separate name entry, separate GHL contact in Summit's sub-account
- `reservations`: new row scoped to Summit Parks' organization ID
- `loyalty`: new row for Sarah within Summit Parks — Bronze, 1 visit (independent of Lakewood)

**What each owner sees:**
- Lakewood Group sees Sarah's 1 visit to Pine Valley, her loyalty tier within their organization, her notes, her GHL contact in their account. They cannot see her Summit Parks reservations.
- Summit Parks sees Sarah as a new guest — 1 visit to River Bend, their own GHL contact record, their own loyalty tracking.

**What Sarah experiences:** She is recognized by email on the platform if either organization uses the same system. Within each organization, her loyalty status is tracked independently.

---

## Data Isolation Between Campground Owners

All data isolation is enforced at the database level through **Row Level Security (RLS)** — not application logic.

Every table that holds tenant-specific data has a policy that evaluates:

```
organization_id = the organization of the currently authenticated user
```

This means:
- A Lakewood Group staff member who queries the reservations table gets back only Lakewood reservations — even if they somehow constructed a direct database query
- No application code change can accidentally expose another organization's data
- The isolation is enforced at the PostgreSQL layer, before any data is returned

The `guests` table is the only shared table, and it intentionally holds no PII — just email and ID. A guest lookup by email confirms whether a person exists on the platform, but retrieving their profile, history, or CRM data always requires a matching `guest_org_profiles` row scoped to the authenticated organization.

---

## Relationship Summary

```
organizations
  └── properties (many per org)
  └── user_roles (many per org — some property-scoped, some org-wide)
  └── guest_org_profiles (one per guest who has booked within this org)
  └── loyalty (one per guest per org)
  └── reservations (all bookings across all properties in this org)

guests (shared identity — email only)
  └── guest_org_profiles (one per org they've booked with)
  └── reservations (one per booking, scoped to the org where it occurred)
  └── loyalty (one per org they've engaged with)
  └── loyalty_by_property (one per property they've stayed at)

properties
  └── reservations (all bookings at this location)
  └── loyalty_by_property (per-property visit analytics)
```

---

## What This Enables Long-Term

| Capability | How It's Supported |
|---|---|
| Owner with 50 campgrounds | One organization row, 50 property rows — single login, portfolio dashboard |
| Guest recognized across 3 sibling properties | Shared email identity, org-wide loyalty tier |
| CRM sync per owner | `ghl_location_id` on org → one GHL sub-account per owner, not per property |
| AI pricing and revenue forecasting | `daily_occupancy_facts` table, pre-computed occupancy % and ADR per property |
| GDPR erasure request | Soft-delete the `guest_org_profiles` row — PII removed, identity token retained for audit |
| Staff turnover | `revoked_at` on user_roles — access removed instantly, history preserved |
| New campground onboards in minutes | One INSERT to organizations, one INSERT to properties — all automation flows inherit |

---

## Summary

The architecture is built around a single core principle: **the organization is the tenant, not the property.** This allows the platform to scale to owners with one campground today and fifty campgrounds tomorrow without schema changes.

Guest identity is shared across the platform by email, but all PII, CRM data, and loyalty state is scoped per organization. This gives each owner a complete view of their guests while making it structurally impossible to view another owner's data.

Happy to walk through any of these design decisions on our next call and discuss how they apply specifically to your current and planned customer base.
