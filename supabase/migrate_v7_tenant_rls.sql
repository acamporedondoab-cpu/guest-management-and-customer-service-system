-- ============================================================
-- MIGRATION v6 → v7: Production Tenant RLS
-- Campground Guest Management & Revenue Intelligence
--
-- THIS IS THE SECURITY FLIP. After this migration:
--   • No demo_allow_all_* policy remains on any table
--   • anon has NO access to any table, view, or data function
--   • Every row a user can touch is scoped to jwt_org_id()
--   • Every write is gated by the role permission matrix
--
-- CLOSES AUDIT FINDINGS:
--   A-1  demo policies = world-readable DB        → Steps 5, 6, 7
--   A-2  production policy set unwritten          → Step 7
--   A-3  user_roles self-grant escalation         → Steps 4, 7.3
--   A-4  auth_user_id reassignment takeover       → Steps 4, 7.2
--   B-2  guest existence oracle                   → Step 2 (upsert_guest)
--   (bonus) kpi_summary cross-tenant aggregate leak → Step 8
--   (bonus) crm/pms_integrations_safe latently broken
--           (invoker view over base table with no SELECT
--            grant = permission denied)           → Step 5 column grants
--
-- CLOSES RED-TEAM (2nd pass) FINDINGS:
--   RT-A1 self-provisioned profile → global guests PII read
--         → Step 5c (guests SELECT column-locked to id,email,created_at)
--   RT-A2 guest_summary / reservation_detail leak global g.*
--         (incl. ghl_contact_id) → Step 8 (views rewritten to read
--         org-scoped guest_org_profiles only; no g.* PII fallback)
--   RT-A3 (2nd pass) guests.created_at re-opened the cross-tenant
--         existence oracle → Step 5c (created_at withheld; org "guest
--         since" exposed via guest_summary.gop.created_at)
--   RT-B1 PUBLIC EXECUTE on functions (REVOKE FROM anon was a no-op
--         against the PUBLIC grant) → Step 5d (REVOKE FROM PUBLIC +
--         explicit re-grants to authenticated / service_role only)
--   RT-B2 reservations INSERT did not bind guest_id to the caller's
--         org → Step 2.5 (create_reservation RPC validates the guest
--         has a profile in jwt_org_id()) + Step 5b (direct INSERT revoked)
--
-- PERMISSION MATRIX ENFORCED:
--   action                        owner manager staff viewer
--   read org data                   ✓      ✓      ✓     ✓
--   write reservations/guests       ✓      ✓      ✓     ✗
--   manage loyalty config           ✓      ✓      ✗     ✗
--   manage integrations (CRM/PMS)   ✓      ✗      ✗     ✗
--   read integrations config        ✓      ✓      ✗     ✗
--   invite/revoke staff             ✓      ✓*     ✗     ✗
--   manage org settings             ✓      ✗      ✗     ✗
--   * managers may grant/revoke only staff and viewer roles
--
-- HARD PRECONDITIONS — DO NOT APPLY UNTIL ALL ARE TRUE:
--   1. migrate_v4 post-migration steps completed:
--      auth users created, auth_user_id backfilled,
--      custom_access_token_hook REGISTERED AND VERIFIED.
--      If the hook is not live, every JWT lacks org_id and
--      this migration locks every user out of all data.
--   2. N8N / automation writes use the service role key
--      (service_role has BYPASSRLS — unaffected by this file).
--   3. The React frontend authenticates users. The anonymous
--      demo dashboard STOPS WORKING at Step 5 by design.
--
-- BREAKING CHANGES (intentional):
--   • anon role: all data access revoked
--   • SELECT * fails for authenticated on: organizations,
--     crm_integrations, pms_integrations, invitations
--     (column-level grants). Use the *_safe views / explicit
--     column lists. PostgREST: always request explicit columns
--     or the safe views for these four tables.
--   • SELECT on guests is column-locked to (id, email, created_at).
--     Guest names / phone / CRM ids are read ONLY through the
--     org-scoped guest_summary / reservation_detail views.
--     SELECT * on guests fails for authenticated.
--   • Direct INSERT/UPDATE/DELETE on guests is revoked.
--     Frontend guest writes go through upsert_guest() RPC.
--   • Direct INSERT on reservations is revoked. Reservation creation
--     goes through create_reservation() RPC, which binds guest_id to
--     the caller's org.
--   • DELETE revoked on all tables for authenticated.
--     Lifecycle columns are the deletion mechanism:
--     reservations.status, user_roles.revoked_at,
--     guest_org_profiles.deleted_at, invitations.revoked_at,
--     properties.status, organizations.status.
--     (Exception: crm/pms_integrations DELETE allowed, owner only.)
--
-- SAFETY CONTRACT:
--   • DROP POLICY IF EXISTS + CREATE POLICY     — idempotent
--   • CREATE OR REPLACE FUNCTION                — idempotent
--   • DROP TRIGGER IF EXISTS + CREATE TRIGGER   — idempotent
--   • GRANT / REVOKE                            — idempotent
--   • No columns dropped, no rows deleted, no schema redesign
--   • Run the whole file as one execution (single transaction
--     in the Supabase SQL editor) so there is no window where
--     demo policies are dropped but tenant policies are absent.
--
-- DEPENDS ON:
--   schema.sql → migrate_v2 → seed_simulation → migrate_v3
--   → migrate_v4 → migrate_v5 → migrate_v6
-- ============================================================


-- ============================================================
-- STEP 1: jwt_user_id() helper
--
-- v4 created jwt_org_id / jwt_property_id / jwt_role /
-- jwt_is_org_wide but not a reader for the user_id claim.
-- Needed by policies that must match "my own rows" across orgs
-- (user_roles for the org switcher, organizations membership).
-- Same shape as the v4 helpers: SQL, STABLE, SECURITY DEFINER,
-- pinned search_path.
-- ============================================================

CREATE OR REPLACE FUNCTION public.jwt_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(
    auth.jwt() -> 'app_metadata' ->> 'user_id',
    ''
  )::UUID;
$$;

COMMENT ON FUNCTION public.jwt_user_id IS
  'Returns public.users.id (NOT auth.users.id) from the current JWT app_metadata. '
  'NULL if no JWT or hook not registered. '
  'Use for own-row policies: USING (user_id = jwt_user_id()).';

GRANT EXECUTE ON FUNCTION public.jwt_user_id() TO authenticated;


-- ============================================================
-- STEP 2: upsert_guest() RPC
--
-- The guests table is GLOBAL (shared identity across orgs).
-- Direct INSERT is revoked in Step 5 for two reasons:
--   1. An INSERT ... ON CONFLICT round-trip reveals whether an
--      email already exists in the platform — a cross-tenant
--      existence oracle (audit B-2).
--   2. A bare guests row without a guest_org_profiles row is
--      invisible to its own creator under the Step 7 SELECT
--      policy (profile-EXISTS based), which invites bugs.
--
-- This RPC is the only authenticated write path into guests.
-- It atomically ensures the guest row AND the caller-org
-- profile row, and returns the guest id whether or not the
-- guest pre-existed — the caller cannot distinguish "created"
-- from "already existed elsewhere".
--
-- SECURITY DEFINER: runs as postgres, so it can write guests
-- and guest_org_profiles regardless of caller policies. All
-- tenant scoping is therefore enforced INSIDE the function
-- from JWT claims — never from caller-supplied org ids.
-- ============================================================

CREATE OR REPLACE FUNCTION public.upsert_guest(
  p_first_name TEXT,
  p_last_name  TEXT,
  p_email      TEXT,
  p_phone      TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id   UUID := jwt_org_id();
  v_role     TEXT := jwt_role();
  v_guest_id UUID;
BEGIN
  -- Tenant + role gate. viewers cannot create guests.
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'upsert_guest: no organization context in JWT'
      USING ERRCODE = '42501';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'staff') THEN
    RAISE EXCEPTION 'upsert_guest: role % may not create guests', COALESCE(v_role, 'none')
      USING ERRCODE = '42501';
  END IF;
  IF p_email IS NULL OR p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'upsert_guest: invalid email';
  END IF;

  -- Global identity row. first_name/last_name are NOT NULL on the
  -- (deprecated) global table so they must be written, but post-v7
  -- they are UNREADABLE to authenticated (Step 5c column grant), and
  -- phone is deliberately NOT propagated to the global row — all
  -- org PII lives only in guest_org_profiles (red-team RT-A1). The
  -- no-op DO UPDATE makes RETURNING yield the id on conflict, so the
  -- caller always gets an id and never learns whether the guest
  -- pre-existed in another tenant.
  INSERT INTO public.guests (first_name, last_name, email, phone)
  VALUES (p_first_name, p_last_name, lower(p_email), NULL)
  ON CONFLICT (email) DO UPDATE SET email = public.guests.email
  RETURNING id INTO v_guest_id;

  -- Caller-org profile overlay. Org-scoped PII lives here;
  -- the global row is never updated by org users.
  INSERT INTO public.guest_org_profiles
    (guest_id, organization_id, first_name, last_name, phone)
  VALUES
    (v_guest_id, v_org_id, p_first_name, p_last_name, p_phone)
  ON CONFLICT (guest_id, organization_id) DO UPDATE SET
    first_name = EXCLUDED.first_name,
    last_name  = EXCLUDED.last_name,
    phone      = COALESCE(EXCLUDED.phone, public.guest_org_profiles.phone),
    updated_at = NOW();

  RETURN v_guest_id;
END;
$$;

COMMENT ON FUNCTION public.upsert_guest IS
  'Only authenticated write path into the global guests table. '
  'Creates/finds guest by email and ensures a guest_org_profiles row for the '
  'caller''s JWT org. Returns guest id without revealing pre-existence (audit B-2). '
  'Roles: owner, manager, staff. Org id is taken from the JWT, never from arguments.';

REVOKE ALL ON FUNCTION public.upsert_guest(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_guest(TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;


-- ============================================================
-- STEP 2.5: create_reservation() RPC  (red-team RT-B2)
--
-- The tenant_reservations_insert policy can gate organization_id,
-- role and property — but RLS WITH CHECK cannot cheaply assert that
-- the supplied guest_id actually belongs to the caller's org. That
-- gap let any staff user book a reservation against ANY global
-- guest_id (data pollution + a guest-UUID existence oracle + it fed
-- the reservation_detail PII leak channel).
--
-- This RPC is the ONLY authenticated reservation-insert path. Direct
-- INSERT on reservations is revoked in Step 5b. It validates, from
-- JWT claims (never from caller-supplied org ids):
--   • a tenant + write role (owner|manager|staff)
--   • the guest has a live profile in jwt_org_id()
--   • the property belongs to jwt_org_id()
--   • property scope: non-org-wide users may only book their property
--
-- SECURITY DEFINER: the INSERT runs as postgres, so it succeeds
-- despite the revoked authenticated INSERT grant; all authorization
-- is enforced explicitly inside the function. The AFTER INSERT
-- loyalty trigger (Step 3, also SECURITY DEFINER) fires normally.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_reservation(
  p_guest_id     UUID,
  p_property_id  UUID,
  p_site_number  TEXT,
  p_check_in     DATE,
  p_check_out    DATE,
  p_num_guests   INTEGER       DEFAULT 1,
  p_nightly_rate NUMERIC       DEFAULT NULL,
  p_total_amount NUMERIC       DEFAULT NULL,
  p_notes        TEXT          DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id UUID := jwt_org_id();
  v_role   TEXT := jwt_role();
  v_res_id UUID;
BEGIN
  -- Tenant + role gate. viewers cannot create reservations.
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'create_reservation: no organization context in JWT'
      USING ERRCODE = '42501';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'staff') THEN
    RAISE EXCEPTION 'create_reservation: role % may not create reservations',
      COALESCE(v_role, 'none')
      USING ERRCODE = '42501';
  END IF;

  -- RT-B2 core check: the guest must already have a live profile in
  -- THIS org. No cross-tenant guest_id can be booked, and the guest
  -- must be created via upsert_guest() first.
  IF NOT EXISTS (
    SELECT 1 FROM public.guest_org_profiles gop
    WHERE gop.guest_id        = p_guest_id
      AND gop.organization_id = v_org_id
      AND gop.deleted_at      IS NULL
  ) THEN
    RAISE EXCEPTION 'create_reservation: guest not found in your organization'
      USING ERRCODE = '42501';
  END IF;

  -- Property must belong to this org.
  IF NOT EXISTS (
    SELECT 1 FROM public.properties p
    WHERE p.id = p_property_id AND p.organization_id = v_org_id
  ) THEN
    RAISE EXCEPTION 'create_reservation: property not found in your organization'
      USING ERRCODE = '42501';
  END IF;

  -- Property scope: a property-scoped user may only book their property.
  IF NOT jwt_is_org_wide() AND p_property_id IS DISTINCT FROM jwt_property_id() THEN
    RAISE EXCEPTION 'create_reservation: you may only book your assigned property'
      USING ERRCODE = '42501';
  END IF;

  -- Basic invariant (mirrors the schema CHECK; fail early with a clear message).
  IF p_check_out <= p_check_in THEN
    RAISE EXCEPTION 'create_reservation: check_out must be after check_in';
  END IF;

  INSERT INTO public.reservations
    (organization_id, property_id, guest_id, site_number,
     check_in, check_out, num_guests, nightly_rate, total_amount, status, notes)
  VALUES
    (v_org_id, p_property_id, p_guest_id, p_site_number,
     p_check_in, p_check_out, COALESCE(p_num_guests, 1),
     p_nightly_rate, p_total_amount, 'confirmed', p_notes)
  RETURNING id INTO v_res_id;

  RETURN v_res_id;
END;
$$;

COMMENT ON FUNCTION public.create_reservation IS
  'Only authenticated reservation-insert path (direct INSERT is revoked). '
  'Binds guest_id and property_id to the caller''s JWT org and enforces the '
  'write-role + property-scope matrix (red-team RT-B2). Guest must already exist '
  'in the org via upsert_guest(). Org id comes from the JWT, never from arguments.';

REVOKE ALL ON FUNCTION public.create_reservation(UUID, UUID, TEXT, DATE, DATE, INTEGER, NUMERIC, NUMERIC, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_reservation(UUID, UUID, TEXT, DATE, DATE, INTEGER, NUMERIC, NUMERIC, TEXT)
  TO authenticated, service_role;


-- ============================================================
-- STEP 3: Make loyalty trigger functions SECURITY DEFINER
--
-- Under RLS, AFTER triggers run with the privileges of the role
-- that performed the DML. A staff member inserting a reservation
-- would have the trigger try to write loyalty, loyalty_by_property
-- and webhook_events AS staff — tables where Step 5/7 deliberately
-- deny direct writes. Without this step, every reservation insert
-- by an authenticated user fails.
--
-- SECURITY DEFINER makes loyalty state server-authoritative:
-- the ONLY paths that write loyalty are these triggers and the
-- service role. No API caller can inflate visit counts directly.
--
-- search_path is pinned, as required for all SECURITY DEFINER
-- functions in this codebase.
-- ============================================================

ALTER FUNCTION public.handle_new_reservation()
  SECURITY DEFINER SET search_path = public;

ALTER FUNCTION public.handle_reservation_status_change()
  SECURITY DEFINER SET search_path = public;

ALTER FUNCTION public.handle_loyalty_tier_change()
  SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.handle_new_reservation IS
  'AFTER INSERT trigger on reservations. SECURITY DEFINER as of v7: '
  'loyalty/webhook_events writes succeed regardless of caller RLS, and direct '
  'API writes to loyalty tables are denied — loyalty state is server-authoritative.';


-- ============================================================
-- STEP 4: Column-protection and lockout-prevention triggers
--
-- RLS is row-level only. These BEFORE triggers add the
-- column-level and invariant guards that policies cannot express.
--
-- auth.role() returns the JWT role claim:
--   'authenticated' for API users  → guards apply
--   'service_role'  for N8N/admin  → guards skipped (but service
--                                     role bypasses RLS anyway;
--                                     triggers still fire, hence
--                                     the explicit role check)
--   NULL            for direct SQL  → guards skipped
-- ============================================================

-- 4a. users: an authenticated user may change ONLY full_name and
--     active_org_id on their own row (the row itself is gated by
--     the Step 7.2 UPDATE policy). id / email / auth_user_id are
--     immutable via the API. Blocking auth_user_id closes the
--     account-takeover path (audit A-4): re-pointing a platform
--     user at an attacker's auth identity inherits all roles.
CREATE OR REPLACE FUNCTION public.protect_users_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'authenticated' THEN
    IF NEW.id           IS DISTINCT FROM OLD.id
    OR NEW.email        IS DISTINCT FROM OLD.email
    OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
    OR NEW.created_at   IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION
        'users: id, email, auth_user_id are immutable via the API'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_users_columns ON public.users;
CREATE TRIGGER protect_users_columns
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.protect_users_columns();

-- 4b. organizations: owners may rename their org; everything that
--     touches billing, tenancy or deprecated secrets is service
--     role only. slug is an external identifier (URLs, webhooks)
--     and plan/status are billing-controlled.
CREATE OR REPLACE FUNCTION public.protect_organizations_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'authenticated' THEN
    IF NEW.id                  IS DISTINCT FROM OLD.id
    OR NEW.slug                IS DISTINCT FROM OLD.slug
    OR NEW.plan                IS DISTINCT FROM OLD.plan
    OR NEW.status              IS DISTINCT FROM OLD.status
    OR NEW.ghl_location_id     IS DISTINCT FROM OLD.ghl_location_id
    OR NEW.make_webhook_secret IS DISTINCT FROM OLD.make_webhook_secret
    OR NEW.created_at          IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION
        'organizations: slug, plan, status and integration secrets are managed by the platform'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_organizations_columns ON public.organizations;
CREATE TRIGGER protect_organizations_columns
  BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION public.protect_organizations_columns();

-- 4c. user_roles: prevent org lockout. The last active owner of
--     an org can be neither revoked nor demoted — by anyone,
--     including the service role (a deliberate fat-finger guard;
--     break-glass path is DELETE as service role, which bypasses
--     this UPDATE trigger).
CREATE OR REPLACE FUNCTION public.protect_last_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.role = 'owner'
     AND OLD.revoked_at IS NULL
     AND (NEW.revoked_at IS NOT NULL OR NEW.role <> 'owner') THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.organization_id = OLD.organization_id
        AND ur.role            = 'owner'
        AND ur.revoked_at      IS NULL
        AND ur.id             <> OLD.id
    ) THEN
      RAISE EXCEPTION
        'user_roles: cannot revoke or demote the last active owner of organization %',
        OLD.organization_id
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_last_owner ON public.user_roles;
CREATE TRIGGER protect_last_owner
  BEFORE UPDATE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION public.protect_last_owner();


-- ============================================================
-- STEP 5: Grant restructuring
--
-- Layer 1 of the two-layer model (grants gate the relation,
-- policies gate the rows). Demo grants were wide-open including
-- anon writes; production grants align with the matrix and the
-- lifecycle-column deletion model.
-- ============================================================

-- 5a. anon: revoke EVERYTHING. The anon key ships in the browser
--     bundle and authenticates nothing. anon keeps schema USAGE
--     only (Supabase internals; with zero table grants it can
--     resolve names but touch nothing).
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;
-- (covers all tables AND views, including guest_summary,
--  reservation_detail, kpi_summary, loyalty_config, invitations
--  INSERT, onboarding_sessions — every demo-era anon grant.)

-- 5b. authenticated: remove write paths that are now trigger-,
--     RPC- or service-role-only, and all DELETEs replaced by
--     lifecycle columns.
REVOKE INSERT, UPDATE, DELETE ON public.guests              FROM authenticated;
REVOKE DELETE                 ON public.properties          FROM authenticated;
REVOKE INSERT, DELETE         ON public.reservations        FROM authenticated;
-- (reservations INSERT is now create_reservation()-only — RT-B2.
--  UPDATE remains for status transitions via the 7.7 policy.)
REVOKE INSERT, UPDATE, DELETE ON public.loyalty             FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.loyalty_by_property FROM authenticated;
REVOKE INSERT, UPDATE         ON public.webhook_events      FROM authenticated;
REVOKE INSERT, DELETE         ON public.users               FROM authenticated;
REVOKE DELETE                 ON public.user_roles          FROM authenticated;
REVOKE DELETE                 ON public.guest_org_profiles  FROM authenticated;
REVOKE INSERT, DELETE         ON public.organizations       FROM authenticated;
REVOKE DELETE                 ON public.loyalty_config      FROM authenticated;
REVOKE DELETE                 ON public.invitations         FROM authenticated;
REVOKE DELETE                 ON public.onboarding_sessions FROM authenticated;

-- 5c. Column-level SELECT grants — secrets become structurally
--     unreadable for authenticated, independent of any policy.
--
--     This ALSO fixes a latent v5/v6 bug: crm_integrations_safe
--     and pms_integrations_safe are security_invoker views, which
--     check the CALLER's privilege on the base table. With no
--     base SELECT grant, authenticated got "permission denied"
--     through the safe views. Granting every column EXCEPT
--     credentials makes the safe views work exactly as intended
--     while SELECT credentials stays a hard permission error.

-- guests (GLOBAL identity table) — red-team RT-A1 + RT-A3.
--   authenticated may read only an opaque id and the email it already
--   supplied to upsert_guest(). first_name, last_name, phone and
--   ghl_contact_id are another tenant's first-writer PII and are now
--   UNREADABLE. created_at is ALSO withheld: the GLOBAL row's creation
--   timestamp reveals whether a guessed email pre-existed platform-wide
--   (an old value means another tenant already has the guest) — exactly
--   the cross-tenant existence oracle upsert_guest()'s no-op return was
--   built to defeat (RT-A3, second pass). The org-scoped "guest since"
--   date is exposed via guest_summary as gop.created_at instead.
--   All guest display data is read through the org-scoped guest_summary
--   / reservation_detail views (Step 8), which source PII from
--   guest_org_profiles only and reference only g.(id,email).
REVOKE SELECT ON public.guests FROM authenticated;
GRANT  SELECT (id, email) ON public.guests TO authenticated;

-- organizations: hide deprecated secret columns
--   (ghl_location_id, make_webhook_secret — superseded by
--    crm_integrations in v5, scheduled for drop in a future
--    cleanup migration).
REVOKE SELECT ON public.organizations FROM authenticated;
GRANT  SELECT (id, name, slug, plan, status, created_at, updated_at)
  ON public.organizations TO authenticated;

-- crm_integrations: hide credentials
REVOKE SELECT ON public.crm_integrations FROM authenticated;
GRANT  SELECT (id, organization_id, provider, name, external_account_id,
               config, status, last_sync_at, created_at, updated_at)
  ON public.crm_integrations TO authenticated;

-- pms_integrations: hide credentials
REVOKE SELECT ON public.pms_integrations FROM authenticated;
GRANT  SELECT (id, organization_id, provider, name, external_property_id,
               config, sync_direction, status, last_sync_at, created_at, updated_at)
  ON public.pms_integrations TO authenticated;

-- invitations: hide the live token. The invitee receives the token
-- by email; org members managing invitations never need to read it.
REVOKE SELECT ON public.invitations FROM authenticated;
GRANT  SELECT (id, organization_id, invited_email, role, property_id,
               expires_at, accepted_at, accepted_by, created_by,
               revoked_at, created_at)
  ON public.invitations TO authenticated;

-- 5d. Function EXECUTE lockdown — red-team RT-B1.
--
-- PostgreSQL grants EXECUTE to PUBLIC by default on every function.
-- PUBLIC is every role, so the demo-era "REVOKE ... FROM anon" was a
-- no-op: anon kept EXECUTE via PUBLIC. Revoke from PUBLIC (and anon)
-- across the schema, then re-grant ONLY the functions each audience
-- needs. Trigger functions (handle_*, protect_*) need no grant — the
-- trigger machinery invokes them as the table owner.
--
-- NOTE: custom_access_token_hook keeps its explicit v4 grant to
-- supabase_auth_admin (an explicit grant survives a PUBLIC revoke);
-- it is re-affirmed below for clarity.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- JWT claim readers — evaluated inside RLS policies as `authenticated`,
-- so authenticated MUST hold EXECUTE (SECURITY DEFINER does not waive
-- the caller's EXECUTE check).
GRANT EXECUTE ON FUNCTION
    public.jwt_org_id(),
    public.jwt_property_id(),
    public.jwt_role(),
    public.jwt_is_org_wide(),
    public.jwt_user_id()
  TO authenticated;

-- Write-path RPCs (definer; self-enforce tenant + role from JWT).
GRANT EXECUTE ON FUNCTION
    public.upsert_guest(TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION
    public.create_reservation(UUID, UUID, TEXT, DATE, DATE, INTEGER, NUMERIC, NUMERIC, TEXT)
  TO authenticated, service_role;

-- Pure tier helper — called inside definer triggers (as owner); also
-- harmless for the dashboard to call directly. Re-grant to keep it
-- callable after the PUBLIC revoke.
GRANT EXECUTE ON FUNCTION public.calculate_tier(INTEGER, UUID) TO authenticated;

-- Auth hook — only Supabase Auth (supabase_auth_admin) may invoke it.
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(JSONB) TO supabase_auth_admin;


-- ============================================================
-- STEP 6: Drop ALL demo policies (15)
--
-- Tenant policies are created in Step 7 within the same
-- transaction — there is no unprotected window. With RLS enabled
-- and no policy, PostgreSQL defaults to deny.
-- ============================================================

DROP POLICY IF EXISTS "demo_allow_all_properties"          ON public.properties;
DROP POLICY IF EXISTS "demo_allow_all_guests"              ON public.guests;
DROP POLICY IF EXISTS "demo_allow_all_reservations"        ON public.reservations;
DROP POLICY IF EXISTS "demo_allow_all_loyalty"             ON public.loyalty;
DROP POLICY IF EXISTS "demo_allow_all_webhook_events"      ON public.webhook_events;
DROP POLICY IF EXISTS "demo_allow_all_organizations"       ON public.organizations;
DROP POLICY IF EXISTS "demo_allow_all_users"               ON public.users;
DROP POLICY IF EXISTS "demo_allow_all_user_roles"          ON public.user_roles;
DROP POLICY IF EXISTS "demo_allow_all_guest_org_profiles"  ON public.guest_org_profiles;
DROP POLICY IF EXISTS "demo_allow_all_loyalty_by_property" ON public.loyalty_by_property;
DROP POLICY IF EXISTS "demo_allow_all_crm_integrations"    ON public.crm_integrations;
DROP POLICY IF EXISTS "demo_allow_all_loyalty_config"      ON public.loyalty_config;
DROP POLICY IF EXISTS "demo_allow_all_pms_integrations"    ON public.pms_integrations;
DROP POLICY IF EXISTS "demo_allow_all_invitations"         ON public.invitations;
DROP POLICY IF EXISTS "demo_allow_all_onboarding_sessions" ON public.onboarding_sessions;


-- ============================================================
-- STEP 7: Tenant-scoped policies
--
-- Conventions:
--   • Naming: tenant_<table>_<operation>
--   • Service role is never mentioned: it has BYPASSRLS.
--   • Property scoping: rows with a property_id are visible to
--     org-wide users and to users scoped to that property.
--     "property_id IS NULL" rows are org-level and visible to all
--     org members.
--   • No DELETE policies exist anywhere except integrations
--     (owner). Combined with revoked DELETE grants, deletion is
--     a service-role operation.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 7.1 organizations
-- SELECT must span ALL orgs the user belongs to — not just the
-- JWT-active one — because the org switcher (user_accessible_orgs,
-- security_invoker) reads through this policy.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_organizations_select" ON public.organizations;
CREATE POLICY "tenant_organizations_select"
  ON public.organizations FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.organization_id = organizations.id
        AND ur.user_id         = jwt_user_id()
        AND ur.revoked_at      IS NULL
    )
  );

DROP POLICY IF EXISTS "tenant_organizations_update" ON public.organizations;
CREATE POLICY "tenant_organizations_update"
  ON public.organizations FOR UPDATE
  USING      (id = jwt_org_id() AND jwt_role() = 'owner')
  WITH CHECK (id = jwt_org_id() AND jwt_role() = 'owner');
-- (column guard: Step 4b trigger. No INSERT — org creation is a
--  platform signup operation, service role only. No DELETE —
--  offboarding is status='cancelled' then service-role purge.)

-- ────────────────────────────────────────────────────────────
-- 7.2 users
-- Read: your own row, plus members of your active org (staff
-- lists). Update: your own row only; WITH CHECK additionally
-- requires that a non-null active_org_id points at an org where
-- you hold an unrevoked role — the same invariant the JWT hook
-- checks at token time, enforced here at write time (audit A-3
-- defense in depth). Mutable columns: Step 4a trigger.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_users_select" ON public.users;
CREATE POLICY "tenant_users_select"
  ON public.users FOR SELECT
  USING (
    auth_user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id         = users.id
        AND ur.organization_id = jwt_org_id()
        AND ur.revoked_at      IS NULL
    )
  );

DROP POLICY IF EXISTS "tenant_users_update" ON public.users;
CREATE POLICY "tenant_users_update"
  ON public.users FOR UPDATE
  USING (auth_user_id = auth.uid())
  WITH CHECK (
    auth_user_id = auth.uid()
    AND (
      active_org_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id         = users.id
          AND ur.organization_id = users.active_org_id
          AND ur.revoked_at      IS NULL
      )
    )
  );
-- (No INSERT — user rows are created by claim_invitation() /
--  service role. No DELETE — audit trail.)

-- ────────────────────────────────────────────────────────────
-- 7.3 user_roles  ← the privilege-escalation boundary (audit A-3)
--
-- The JWT hook trusts unrevoked rows in this table. These
-- policies are therefore the real tenant boundary:
--   • Writes only within the caller's JWT org.
--   • Owners may grant/modify any role in their org.
--   • Managers may grant/modify ONLY staff and viewer rows —
--     both the row they touch (USING) and the value they write
--     (WITH CHECK), so a manager can neither edit an owner row
--     nor write 'owner' into any row, including their own
--     (their own row is role='manager', outside their USING set).
--   • Reads: own rows across all orgs (org switcher) + all rows
--     in the active org (staff page).
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_user_roles_select" ON public.user_roles;
CREATE POLICY "tenant_user_roles_select"
  ON public.user_roles FOR SELECT
  USING (
    user_id = jwt_user_id()
    OR organization_id = jwt_org_id()
  );

DROP POLICY IF EXISTS "tenant_user_roles_insert" ON public.user_roles;
CREATE POLICY "tenant_user_roles_insert"
  ON public.user_roles FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  );

DROP POLICY IF EXISTS "tenant_user_roles_update" ON public.user_roles;
CREATE POLICY "tenant_user_roles_update"
  ON public.user_roles FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  );
-- (No DELETE — revocation is UPDATE revoked_at = NOW(); Step 4c
--  trigger blocks revoking/demoting the last active owner.)

-- ────────────────────────────────────────────────────────────
-- 7.4 properties
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_properties_select" ON public.properties;
CREATE POLICY "tenant_properties_select"
  ON public.properties FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND (jwt_is_org_wide() OR id = jwt_property_id())
  );

DROP POLICY IF EXISTS "tenant_properties_insert" ON public.properties;
CREATE POLICY "tenant_properties_insert"
  ON public.properties FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
    AND jwt_is_org_wide()
  );

DROP POLICY IF EXISTS "tenant_properties_update" ON public.properties;
CREATE POLICY "tenant_properties_update"
  ON public.properties FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
    AND (jwt_is_org_wide() OR id = jwt_property_id())
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );
-- (No DELETE — retire via status = 'inactive'.)

-- ────────────────────────────────────────────────────────────
-- 7.5 guests (GLOBAL identity table — the hard case)
--
-- A guest "belongs" to an org only through guest_org_profiles.
-- Visibility = an active (non-erased) profile row for the
-- caller's org. Column equality is impossible here; the EXISTS
-- form is the correct tenant boundary for shared identity.
-- All writes revoked (Step 5b) — upsert_guest() / service role.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_guests_select" ON public.guests;
CREATE POLICY "tenant_guests_select"
  ON public.guests FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.guest_org_profiles gop
      WHERE gop.guest_id        = guests.id
        AND gop.organization_id = jwt_org_id()
        AND gop.deleted_at      IS NULL
    )
  );

-- ────────────────────────────────────────────────────────────
-- 7.6 guest_org_profiles
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_guest_org_profiles_select" ON public.guest_org_profiles;
CREATE POLICY "tenant_guest_org_profiles_select"
  ON public.guest_org_profiles FOR SELECT
  USING (organization_id = jwt_org_id());

DROP POLICY IF EXISTS "tenant_guest_org_profiles_insert" ON public.guest_org_profiles;
CREATE POLICY "tenant_guest_org_profiles_insert"
  ON public.guest_org_profiles FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
  );

DROP POLICY IF EXISTS "tenant_guest_org_profiles_update" ON public.guest_org_profiles;
CREATE POLICY "tenant_guest_org_profiles_update"
  ON public.guest_org_profiles FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
  );
-- (No DELETE — GDPR erasure is UPDATE deleted_at, then service
--  role purges PII.)

-- ────────────────────────────────────────────────────────────
-- 7.7 reservations
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_reservations_select" ON public.reservations;
CREATE POLICY "tenant_reservations_select"
  ON public.reservations FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND (jwt_is_org_wide() OR property_id = jwt_property_id() OR property_id IS NULL)
  );

-- Backstop only: direct INSERT grant is revoked (Step 5b), so for
-- authenticated this policy is unreachable and reservations are
-- created via create_reservation() (RT-B2). Retained so that if the
-- grant is ever re-added, inserts still cannot escape org/role/property
-- scope. (It still cannot bind guest_id to the org — that check lives
-- in create_reservation(), which is why direct INSERT stays revoked.)
DROP POLICY IF EXISTS "tenant_reservations_insert" ON public.reservations;
CREATE POLICY "tenant_reservations_insert"
  ON public.reservations FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
    AND (jwt_is_org_wide() OR property_id = jwt_property_id())
  );

DROP POLICY IF EXISTS "tenant_reservations_update" ON public.reservations;
CREATE POLICY "tenant_reservations_update"
  ON public.reservations FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
    AND (jwt_is_org_wide() OR property_id = jwt_property_id() OR property_id IS NULL)
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager', 'staff')
  );
-- (No DELETE — lifecycle ends at status 'cancelled'/'checked_out'.)

-- ────────────────────────────────────────────────────────────
-- 7.8 loyalty — read-only for every API role.
-- Writes happen exclusively inside the Step 3 SECURITY DEFINER
-- triggers (and service role). Rows with NULL organization_id
-- (pre-v2 legacy) are intentionally invisible.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_loyalty_select" ON public.loyalty;
CREATE POLICY "tenant_loyalty_select"
  ON public.loyalty FOR SELECT
  USING (organization_id = jwt_org_id());

-- ────────────────────────────────────────────────────────────
-- 7.9 loyalty_by_property — read-only, property-scoped.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_loyalty_by_property_select" ON public.loyalty_by_property;
CREATE POLICY "tenant_loyalty_by_property_select"
  ON public.loyalty_by_property FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND (jwt_is_org_wide() OR property_id = jwt_property_id())
  );

-- ────────────────────────────────────────────────────────────
-- 7.10 webhook_events — read-only audit log for the dashboard.
-- Writes come from triggers (SECURITY DEFINER) and N8N (service
-- role). payload JSONB contains guest PII → same scoping as the
-- source tables.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_webhook_events_select" ON public.webhook_events;
CREATE POLICY "tenant_webhook_events_select"
  ON public.webhook_events FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND (jwt_is_org_wide() OR property_id = jwt_property_id() OR property_id IS NULL)
  );

-- ────────────────────────────────────────────────────────────
-- 7.11 crm_integrations — matrix: read owner+manager, write owner.
-- credentials column is unreadable regardless (Step 5c column
-- grant); these policies scope the remaining columns by tenant.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_crm_integrations_select" ON public.crm_integrations;
CREATE POLICY "tenant_crm_integrations_select"
  ON public.crm_integrations FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "tenant_crm_integrations_insert" ON public.crm_integrations;
CREATE POLICY "tenant_crm_integrations_insert"
  ON public.crm_integrations FOR INSERT
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');

DROP POLICY IF EXISTS "tenant_crm_integrations_update" ON public.crm_integrations;
CREATE POLICY "tenant_crm_integrations_update"
  ON public.crm_integrations FOR UPDATE
  USING      (organization_id = jwt_org_id() AND jwt_role() = 'owner')
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');

DROP POLICY IF EXISTS "tenant_crm_integrations_delete" ON public.crm_integrations;
CREATE POLICY "tenant_crm_integrations_delete"
  ON public.crm_integrations FOR DELETE
  USING (organization_id = jwt_org_id() AND jwt_role() = 'owner');

-- ────────────────────────────────────────────────────────────
-- 7.12 pms_integrations — identical model to crm_integrations.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_pms_integrations_select" ON public.pms_integrations;
CREATE POLICY "tenant_pms_integrations_select"
  ON public.pms_integrations FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "tenant_pms_integrations_insert" ON public.pms_integrations;
CREATE POLICY "tenant_pms_integrations_insert"
  ON public.pms_integrations FOR INSERT
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');

DROP POLICY IF EXISTS "tenant_pms_integrations_update" ON public.pms_integrations;
CREATE POLICY "tenant_pms_integrations_update"
  ON public.pms_integrations FOR UPDATE
  USING      (organization_id = jwt_org_id() AND jwt_role() = 'owner')
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');

DROP POLICY IF EXISTS "tenant_pms_integrations_delete" ON public.pms_integrations;
CREATE POLICY "tenant_pms_integrations_delete"
  ON public.pms_integrations FOR DELETE
  USING (organization_id = jwt_org_id() AND jwt_role() = 'owner');

-- ────────────────────────────────────────────────────────────
-- 7.13 loyalty_config — read all org members (tier display);
-- write owner+manager per matrix.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_loyalty_config_select" ON public.loyalty_config;
CREATE POLICY "tenant_loyalty_config_select"
  ON public.loyalty_config FOR SELECT
  USING (organization_id = jwt_org_id());

DROP POLICY IF EXISTS "tenant_loyalty_config_insert" ON public.loyalty_config;
CREATE POLICY "tenant_loyalty_config_insert"
  ON public.loyalty_config FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "tenant_loyalty_config_update" ON public.loyalty_config;
CREATE POLICY "tenant_loyalty_config_update"
  ON public.loyalty_config FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );

-- ────────────────────────────────────────────────────────────
-- 7.14 invitations
-- The role-escalation rule mirrors user_roles 7.3 exactly: an
-- invitation IS a future role grant, so a manager must not be
-- able to create — or edit an existing invitation into — an
-- owner/manager invite. token column unreadable (Step 5c).
-- The claim path (invitee, pre-membership) cannot work through
-- these policies by design; it requires the claim_invitation()
-- SECURITY DEFINER RPC (audit W-2/B-4, next migration).
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_invitations_select" ON public.invitations;
CREATE POLICY "tenant_invitations_select"
  ON public.invitations FOR SELECT
  USING (
    organization_id = jwt_org_id()
    AND jwt_role() IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "tenant_invitations_insert" ON public.invitations;
CREATE POLICY "tenant_invitations_insert"
  ON public.invitations FOR INSERT
  WITH CHECK (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  );

DROP POLICY IF EXISTS "tenant_invitations_update" ON public.invitations;
CREATE POLICY "tenant_invitations_update"
  ON public.invitations FOR UPDATE
  USING (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  )
  WITH CHECK (
    organization_id = jwt_org_id()
    AND (
      jwt_role() = 'owner'
      OR (jwt_role() = 'manager' AND role IN ('staff', 'viewer'))
    )
  );

-- ────────────────────────────────────────────────────────────
-- 7.15 onboarding_sessions — owner-driven wizard.
-- ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "tenant_onboarding_sessions_select" ON public.onboarding_sessions;
CREATE POLICY "tenant_onboarding_sessions_select"
  ON public.onboarding_sessions FOR SELECT
  USING (organization_id = jwt_org_id());

DROP POLICY IF EXISTS "tenant_onboarding_sessions_insert" ON public.onboarding_sessions;
CREATE POLICY "tenant_onboarding_sessions_insert"
  ON public.onboarding_sessions FOR INSERT
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');

DROP POLICY IF EXISTS "tenant_onboarding_sessions_update" ON public.onboarding_sessions;
CREATE POLICY "tenant_onboarding_sessions_update"
  ON public.onboarding_sessions FOR UPDATE
  USING      (organization_id = jwt_org_id() AND jwt_role() = 'owner')
  WITH CHECK (organization_id = jwt_org_id() AND jwt_role() = 'owner');


-- ============================================================
-- STEP 8: View hardening (security_invoker + org-scoped PII)
--   8.1 kpi_summary       → security_invoker (per-tenant aggregates)
--   8.2 guest_summary     → org-scoped PII only (red-team RT-A2)
--   8.3 reservation_detail→ org-scoped PII only (red-team RT-A2)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 8.1 kpi_summary → security_invoker
--
-- The v5 kpi_summary is a definer-context view granted to anon —
-- it computed GLOBAL counts across all tenants and bypassed RLS.
-- Recreated verbatim with security_invoker = true: every
-- subquery now evaluates under the caller's policies, so the
-- same view yields per-tenant KPIs automatically. (anon grant
-- already revoked in Step 5a.)
--
-- Note for staff/viewer callers: the active_crm_integrations
-- subquery reads crm_integrations, whose SELECT policy admits
-- owner/manager only — for staff/viewer that metric reads 0,
-- not an error. Acceptable; the dashboard shows it to
-- owner/manager only.
-- ============================================================

DROP VIEW IF EXISTS public.kpi_summary;
CREATE VIEW public.kpi_summary
WITH (security_invoker = true)
AS
SELECT
  (SELECT COUNT(*) FROM public.guests)                              AS total_guests,
  (SELECT COUNT(*) FROM public.reservations)                        AS total_reservations,
  (SELECT COUNT(*) FROM public.loyalty WHERE total_visits > 1)      AS returning_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Bronze')       AS bronze_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Silver')       AS silver_guests,
  (SELECT COUNT(*) FROM public.loyalty WHERE tier = 'Gold')         AS gold_guests,
  (SELECT COALESCE(SUM(total_amount), 0.00)
   FROM public.reservations WHERE status != 'cancelled')            AS estimated_revenue,
  (SELECT COUNT(*)
   FROM public.guest_org_profiles
   WHERE crm_contact_ids != '{}'::JSONB
      OR ghl_contact_id IS NOT NULL)                                AS synced_contacts,
  (SELECT COUNT(DISTINCT organization_id)
   FROM public.crm_integrations
   WHERE status = 'active' AND provider != 'none')                  AS active_crm_integrations,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'pending')  AS pending_webhooks,
  (SELECT COUNT(*) FROM public.webhook_events WHERE status = 'failed')   AS failed_webhooks;

GRANT SELECT ON public.kpi_summary TO authenticated;

COMMENT ON VIEW public.kpi_summary IS
  'Per-tenant KPI aggregates. security_invoker = true (v7): all counts evaluate '
  'under the caller''s RLS, so each org sees only its own numbers through the '
  'same view definition.';


-- ────────────────────────────────────────────────────────────
-- 8.2 guest_summary → org-scoped PII only  (red-team RT-A2)
--
-- The v5 definition fell back to the GLOBAL guests row for PII:
--   COALESCE(gop.first_name, g.first_name)          -- name fallback
--   COALESCE(..., gop.ghl_contact_id, g.ghl_contact_id)  -- GHL fallback
-- A user who self-provisioned a thin profile (upsert_guest) would see
-- another tenant's name / GHL id through those fallbacks — even though
-- the view is "safe". Rewritten to read PII from guest_org_profiles
-- ONLY (gop.first_name/last_name are NOT NULL), with no g.* fallback,
-- and INNER JOIN so a guest with no live profile in a visible org
-- never appears. g.id / g.email are the only global columns referenced
-- (within the Step 5c grant); "guest since" uses gop.created_at.
-- ────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.guest_summary;
CREATE VIEW public.guest_summary
WITH (security_invoker = true)
AS
SELECT
  g.id,
  gop.first_name,
  gop.last_name,
  (gop.first_name || ' ' || gop.last_name)            AS full_name,
  g.email,
  gop.phone,
  COALESCE(gop.crm_contact_ids->>'gohighlevel',
           gop.ghl_contact_id)                        AS ghl_contact_id,
  gop.crm_contact_ids,
  gop.organization_id,
  COALESCE(l.total_visits,     0)                     AS total_visits,
  COALESCE(l.confirmed_visits, l.total_visits, 0)     AS confirmed_visits,
  COALESCE(l.total_spend,      0.00)                  AS total_spend,
  COALESCE(l.tier, 'Bronze')                          AS loyalty_tier,
  l.last_visit,
  gop.crm_synced_at,
  gop.created_at                                      AS created_at
FROM public.guests g
JOIN public.guest_org_profiles gop
  ON gop.guest_id = g.id
 AND gop.deleted_at IS NULL
LEFT JOIN public.loyalty l
  ON  l.guest_id        = g.id
  AND l.organization_id = gop.organization_id;

GRANT SELECT ON public.guest_summary TO authenticated;

COMMENT ON VIEW public.guest_summary IS
  'Guests with loyalty state and org-scoped PII. security_invoker = true. '
  'PII (name, phone, GHL id) is sourced from guest_org_profiles ONLY — no '
  'fallback to the global guests row (red-team RT-A2). INNER JOIN on a live '
  'profile means a guest is visible only in orgs that have a profile for them.';


-- ────────────────────────────────────────────────────────────
-- 8.3 reservation_detail → org-scoped PII only  (red-team RT-A2)
--
-- The v2 definition built guest_name from g.first_name/last_name (the
-- global row). Combined with a reservation referencing a foreign
-- guest_id, that leaked another tenant's name. Now create_reservation
-- binds guest_id to the org, AND guest_name is sourced from the
-- matching guest_org_profiles row. Only g.id / g.email are referenced
-- on the global table (within the Step 5c grant). Under security_invoker,
-- reservations RLS already scopes rows to the caller's org.
-- ────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.reservation_detail;
CREATE VIEW public.reservation_detail
WITH (security_invoker = true)
AS
SELECT
  r.id,
  r.external_reservation_id,
  r.organization_id,
  r.property_id,
  p.name                                              AS property_name,
  r.guest_id,
  COALESCE(gop.first_name || ' ' || gop.last_name,
           '(guest)')                                 AS guest_name,
  g.email,
  r.site_number,
  r.check_in,
  r.check_out,
  (r.check_out - r.check_in)                          AS num_nights,
  r.num_guests,
  r.nightly_rate,
  r.total_amount,
  r.status,
  r.notes,
  r.created_at
FROM public.reservations r
JOIN public.guests g
  ON g.id = r.guest_id
LEFT JOIN public.guest_org_profiles gop
  ON  gop.guest_id        = r.guest_id
  AND gop.organization_id = r.organization_id
LEFT JOIN public.properties p
  ON p.id = r.property_id;

GRANT SELECT ON public.reservation_detail TO authenticated;

COMMENT ON VIEW public.reservation_detail IS
  'Reservations joined to org-scoped guest name (guest_org_profiles) and '
  'property. security_invoker = true. No global guests PII beyond id/email '
  '(red-team RT-A2). Rows are scoped to the caller''s org by reservations RLS.';


-- ============================================================
-- STEP 9: VERIFICATION QUERIES (commented — run manually)
--
-- Run AFTER applying, in the Supabase SQL editor. Each block is
-- wrapped in BEGIN/ROLLBACK so nothing persists. Impersonation
-- works by setting the JWT claims GUC that auth.jwt() reads.
--
-- Replace <aries_auth_uuid> / <blue_auth_uuid> with the real
-- auth.users ids for aries@test.com / blue@test.com.
-- Seeded platform ids:
--   aries user 00000000-0000-0000-0000-000000000020, org ...01
--   blue  user 00000000-0000-0000-0000-000000000021, org ...02
-- ============================================================

-- ── V0. Policy inventory: expect 0 demo policies, 30+ tenant_* ──
-- SELECT schemaname, tablename, policyname
-- FROM pg_policies
-- WHERE schemaname = 'public'
-- ORDER BY tablename, policyname;
-- -- PASS: no row whose policyname LIKE 'demo_allow_all%'

-- ── V1. anon is locked out entirely ──────────────────────────
-- BEGIN;
-- SET LOCAL ROLE anon;
-- SELECT COUNT(*) FROM public.guests;          -- PASS: permission denied
-- ROLLBACK;
-- BEGIN;
-- SET LOCAL ROLE anon;
-- SELECT COUNT(*) FROM public.guest_summary;   -- PASS: permission denied
-- ROLLBACK;

-- ── V2. Tenant isolation, both directions ────────────────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub',  '<aries_auth_uuid>',
--   'role', 'authenticated',
--   'app_metadata', json_build_object(
--     'org_id',      '00000000-0000-0000-0000-000000000001',
--     'user_role',   'owner',
--     'user_id',     '00000000-0000-0000-0000-000000000020',
--     'is_org_wide', true
--   ))::text, true);
-- SELECT COUNT(*) FROM public.reservations;     -- PASS: Aries rows only
-- SELECT COUNT(*) FROM public.reservations
--   WHERE organization_id = '00000000-0000-0000-0000-000000000002';
--                                               -- PASS: 0 (Blue Ridge invisible)
-- SELECT * FROM public.kpi_summary;             -- PASS: Aries-scoped counts
-- ROLLBACK;
-- -- Repeat with the Blue Ridge claims; expect the mirror result.

-- ── V3. A-3: cross-org self-grant is rejected ────────────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','owner',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- INSERT INTO public.user_roles (user_id, organization_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000020',
--         '00000000-0000-0000-0000-000000000002',   -- victim org
--         'owner');
-- -- PASS: new row violates row-level security policy
-- ROLLBACK;

-- ── V4. Manager cannot mint owners (escalation ceiling) ──────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','manager',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- INSERT INTO public.user_roles (user_id, organization_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000021',
--         '00000000-0000-0000-0000-000000000001', 'owner');
-- -- PASS: violates row-level security policy
-- INSERT INTO public.user_roles (user_id, organization_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000021',
--         '00000000-0000-0000-0000-000000000001', 'staff');
-- -- PASS: succeeds (manager may grant staff)
-- ROLLBACK;

-- ── V5. A-4: auth_user_id is immutable via the API ───────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','owner',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- UPDATE public.users SET auth_user_id = gen_random_uuid()
-- WHERE id = '00000000-0000-0000-0000-000000000020';
-- -- PASS: exception 'users: id, email, auth_user_id are immutable via the API'
-- ROLLBACK;

-- ── V6. active_org_id must point at a membership org ─────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- -- (same Aries owner claims as V5)
-- UPDATE public.users
-- SET active_org_id = '00000000-0000-0000-0000-000000000002'  -- not a member
-- WHERE id = '00000000-0000-0000-0000-000000000020';
-- -- PASS: new row violates row-level security policy (WITH CHECK)
-- ROLLBACK;

-- ── V7. credentials are structurally unreadable ──────────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- -- (Aries owner claims)
-- SELECT credentials FROM public.crm_integrations;
-- -- PASS: permission denied for table crm_integrations (column grant)
-- SELECT * FROM public.crm_integrations_safe;
-- -- PASS: succeeds, org-scoped rows, no credentials column
-- ROLLBACK;

-- ── V8. Staff can book; the definer trigger writes loyalty ───
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- -- (Aries claims with 'user_role','staff')
-- -- Insert a reservation for an existing Aries guest/property;
-- -- PASS: insert succeeds AND loyalty.total_visits increments
-- -- (trigger ran as definer despite staff having no loyalty grant).
-- ROLLBACK;

-- ── V9. Viewer is read-only ──────────────────────────────────
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- -- (Aries claims with 'user_role','viewer')
-- SELECT COUNT(*) FROM public.reservations;     -- PASS: succeeds
-- UPDATE public.reservations SET notes = 'x'
-- WHERE organization_id = '00000000-0000-0000-0000-000000000001';
-- -- PASS: 0 rows updated (USING filters all rows for viewer)
-- ROLLBACK;

-- ── V10. Last-owner lockout guard ────────────────────────────
-- BEGIN;
-- -- As postgres (no impersonation needed — guard applies to all):
-- UPDATE public.user_roles SET revoked_at = NOW()
-- WHERE role = 'owner' AND revoked_at IS NULL
--   AND organization_id = '00000000-0000-0000-0000-000000000001';
-- -- PASS: exception 'cannot revoke or demote the last active owner'
-- --        (assuming the org has exactly one active owner)
-- ROLLBACK;

-- ── V11. RT-A1: self-provisioned profile yields NO cross-tenant PII ──
-- Aries impersonates and provisions a thin profile for a Blue Ridge
-- guest, then tries to read the global guests PII.
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','owner',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- SELECT public.upsert_guest('mal','lory','victim@blueridge.example', NULL);
-- -- now a thin Aries profile exists for that global guest
-- SELECT first_name, last_name, phone, ghl_contact_id, created_at
--   FROM public.guests WHERE email = 'victim@blueridge.example';
-- -- PASS: ERROR — permission denied for table guests
-- --        (only id, email are granted; PII + created_at columns blocked)
-- SELECT id, email FROM public.guests WHERE email = 'victim@blueridge.example';
-- -- PASS: returns only an opaque id + the email the caller already typed.
-- --        No name / phone / GHL id / created_at (existence-oracle) disclosed.
-- ROLLBACK;

-- ── V12. RT-A2: guest_summary exposes only the caller-org profile ──
-- Even with a thin self-provisioned profile, guest_summary must show
-- the caller's own (placeholder) data and NEVER fall back to the
-- victim org's global name / GHL id.
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','owner',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- SELECT public.upsert_guest('mal','lory','victim@blueridge.example', NULL);
-- SELECT full_name, ghl_contact_id, organization_id
--   FROM public.guest_summary WHERE email = 'victim@blueridge.example';
-- -- PASS: full_name = 'mal lory' (Aries profile),
-- --        ghl_contact_id = NULL (no g.ghl_contact_id fallback),
-- --        organization_id = Aries. Blue Ridge's real name/GHL id never appear.
-- -- And the row count from Aries' view must not include Blue Ridge's
-- -- own profile for this guest:
-- SELECT count(*) FROM public.guest_summary WHERE email='victim@blueridge.example';
-- -- PASS: exactly 1 (the Aries profile only).
-- ROLLBACK;

-- ── V13. RT-B1 + RT-B2: function grants locked; reservation binding ──
-- (a) RT-B1 — anon cannot execute the SECURITY DEFINER RPCs at all
--     (PUBLIC execute revoked; the demo-era anon revoke is now real):
-- BEGIN;
-- SET LOCAL ROLE anon;
-- SELECT public.upsert_guest('x','y','a@b.example', NULL);
-- -- PASS: ERROR — permission denied for function upsert_guest
-- ROLLBACK;
-- BEGIN;
-- SET LOCAL ROLE anon;
-- SELECT public.create_reservation(
--   gen_random_uuid(), gen_random_uuid(), 'A1', '2026-07-01', '2026-07-02');
-- -- PASS: ERROR — permission denied for function create_reservation
-- ROLLBACK;
--
-- (b) RT-B2 — authenticated cannot book a guest with no profile in
--     their org (use a Blue-Ridge-only guest_id and an Aries property):
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub','<aries_auth_uuid>','role','authenticated',
--   'app_metadata', json_build_object(
--     'org_id','00000000-0000-0000-0000-000000000001',
--     'user_role','staff',
--     'user_id','00000000-0000-0000-0000-000000000020',
--     'is_org_wide',true))::text, true);
-- SELECT public.create_reservation(
--   '<blue_ridge_only_guest_id>'::uuid, '<aries_property_id>'::uuid,
--   'A1', '2026-07-01', '2026-07-02');
-- -- PASS: ERROR — create_reservation: guest not found in your organization
-- ROLLBACK;
--
-- (c) RT-B2 — direct INSERT into reservations is revoked for authenticated
--     (the bypass create_reservation exists to close):
-- BEGIN;
-- SET LOCAL ROLE authenticated;
-- -- (same Aries staff claims as (b))
-- INSERT INTO public.reservations
--   (organization_id, property_id, guest_id, site_number, check_in, check_out)
-- VALUES ('00000000-0000-0000-0000-000000000001',
--         '<aries_property_id>'::uuid, '<any_guest_id>'::uuid,
--         'A1', '2026-07-01', '2026-07-02');
-- -- PASS: ERROR — permission denied for table reservations
-- ROLLBACK;


-- ============================================================
-- POST-MIGRATION NOTES
--
-- 1. The frontend must be updated in the same release:
--    • authenticate before any query;
--    • create guests via supabase.rpc('upsert_guest', {...});
--    • create reservations via supabase.rpc('create_reservation', {...})
--      (direct INSERT into reservations is revoked — RT-B2);
--    • read guest names/phone/CRM ids ONLY from guest_summary /
--      reservation_detail — never SELECT name columns from guests
--      (column-locked to id,email,created_at — RT-A1);
--    • never SELECT * on organizations / crm_integrations /
--      pms_integrations / invitations (use safe views or explicit
--      columns).
-- 2. N8N/automation must use the service role key (BYPASSRLS).
--    Scoping it to a restricted 'automation' role is the
--    follow-up hardening item from the readiness audit (§5).
-- 3. Still open after this migration (tracked in audit):
--    claim_invitation() RPC (B-4), credentials → Vault (B-6),
--    webhook_events retention/PII minimization (B-7),
--    org soft-delete enforcement (B-8), audit_log table.
-- ============================================================
