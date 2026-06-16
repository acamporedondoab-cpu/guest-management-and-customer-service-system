-- ============================================================
-- MIGRATION v4: Auth Context + JWT Enrichment
-- Campground Guest Management & Revenue Intelligence
--
-- WHAT THIS ADDS:
--   STEP 1 — Schema additions on users table
--             auth_user_id  — link to auth.users.id (Supabase Auth identity)
--             active_org_id — persistent multi-org preference
--
--   STEP 2 — Indexes for auth context lookups
--             idx_users_auth_user_id  (primary JWT hook lookup — every login)
--             idx_users_active_org_id (org resolution analytics)
--
--   STEP 3 — JWT helper functions (SECURITY DEFINER, STABLE)
--             jwt_org_id()      → UUID
--             jwt_property_id() → UUID (NULL for org-wide users)
--             jwt_role()        → TEXT (owner|manager|staff|viewer)
--             jwt_is_org_wide() → BOOLEAN
--
--   STEP 4 — custom_access_token_hook(event JSONB)
--             Called by Supabase Auth on every JWT issuance.
--             Enriches app_metadata with: org_id, property_id,
--             user_role, user_id, is_org_wide.
--             Org resolution: active_org_id → highest-privilege role fallback.
--             Never breaks auth — all errors caught and logged as warnings.
--
--   STEP 5 — user_accessible_orgs view (security_invoker = true)
--             Shows all orgs and roles for the current authenticated user.
--             Powers the React org-switcher and settings pages.
--
--   STEP 6 — Grants
--             JWT helpers → anon, authenticated
--             user_accessible_orgs → authenticated
--             custom_access_token_hook → supabase_auth_admin only
--
--   STEP 7 — Verification queries (commented, run manually)
--             + Post-migration manual steps
--
-- DEPENDS ON:
--   schema.sql (v1)              — tables
--   migrate_v2_multi_tenant.sql  — organizations, users, user_roles tables
--   migrate_v3_loyalty_lifecycle — not a direct dependency; apply v3 first
--                                  for consistent migration ordering
--
-- SAFETY CONTRACT:
--   ALTER TABLE  — IF NOT EXISTS throughout (idempotent)
--   CREATE INDEX — IF NOT EXISTS throughout (idempotent)
--   CREATE OR REPLACE FUNCTION — idempotent
--   CREATE OR REPLACE VIEW     — idempotent
--   No columns dropped, no data deleted
--   Existing RLS policies and triggers left untouched
--
-- POST-MIGRATION MANUAL STEPS (see Step 7 for detail):
--   1. Backfill auth_user_id for demo users via Supabase Auth dashboard
--   2. Register custom_access_token_hook in Authentication → Hooks
--   3. Verify JWT enrichment via browser console
--   4. Test active_org_id switching with supabase.auth.refreshSession()
-- ============================================================


-- ============================================================
-- STEP 1: Schema additions on users table
--
-- auth_user_id
--   Links this platform user row to the Supabase Auth identity.
--   Null until the user completes their first login and the link
--   is established (manually or via onboarding flow).
--   UNIQUE: one auth.users entry maps to exactly one platform user.
--   ON DELETE SET NULL: if the auth user is deleted (account purge),
--     the platform user row is preserved for audit and reservation history.
--
-- active_org_id
--   Stores the user's current org selection across sessions.
--   NULL means: resolve the JWT context from their highest-privilege role.
--   Non-null means: always scope the JWT to this specific org.
--   Updated by the React org-switcher; JWT re-enriched on the next
--   supabase.auth.refreshSession() call in the frontend.
--   ON DELETE SET NULL: if an org is deleted, fall back to auto-resolution.
-- ============================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS auth_user_id UUID
    UNIQUE
    REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS active_org_id UUID
    REFERENCES public.organizations(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.users.auth_user_id IS
  'Links to auth.users.id (Supabase Auth identity). '
  'Nullable until first login. UNIQUE — one auth identity per platform user. '
  'ON DELETE SET NULL preserves the user row for audit if auth account is deleted.';

COMMENT ON COLUMN public.users.active_org_id IS
  'Persistent org preference for multi-org users. '
  'NULL = JWT hook resolves highest-privilege org from user_roles automatically. '
  'Non-null = JWT always scoped to this org. '
  'Updated by org-switcher UI; JWT refreshed via supabase.auth.refreshSession().';


-- ============================================================
-- STEP 2: Indexes
--
-- idx_users_auth_user_id
--   Critical path: the JWT hook runs on every login and token refresh.
--   The first query is: SELECT id, active_org_id FROM users WHERE auth_user_id = $1.
--   This index makes that lookup O(log n). Filtered to non-null rows only.
--
-- idx_users_active_org_id
--   Used when querying all users currently scoped to a specific org
--   (admin tooling, org deletion checks). Filtered to non-null rows only.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_users_auth_user_id
  ON public.users(auth_user_id)
  WHERE auth_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_active_org_id
  ON public.users(active_org_id)
  WHERE active_org_id IS NOT NULL;


-- ============================================================
-- STEP 3: JWT helper functions
--
-- These are thin wrappers around auth.jwt() app_metadata reads.
-- Wrapping them as named functions allows RLS policies to read
-- as: USING (organization_id = jwt_org_id())
-- instead of: USING (organization_id = (auth.jwt()->'app_metadata'->>'org_id')::UUID)
--
-- SECURITY DEFINER
--   Required so these functions run as their defining user (postgres)
--   in all execution contexts — including RLS policy evaluation,
--   where the calling role may not have explicit EXECUTE on auth.jwt().
--
-- STABLE
--   auth.jwt() reads current_setting('request.jwt.claims'), which is
--   set once per HTTP request by PostgREST and does not change within
--   the request. STABLE allows PostgreSQL to optimize away repeated
--   calls within the same query.
--
-- SET search_path = public
--   Security hardening for SECURITY DEFINER functions. Prevents
--   search path manipulation attacks where a malicious schema inserts
--   objects that shadow the intended targets.
-- ============================================================

CREATE OR REPLACE FUNCTION public.jwt_org_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(
    auth.jwt() -> 'app_metadata' ->> 'org_id',
    ''
  )::UUID;
$$;

COMMENT ON FUNCTION public.jwt_org_id IS
  'Returns organization_id from the current JWT app_metadata. '
  'NULL if no JWT is present, or if the custom_access_token_hook '
  'has not yet been registered and executed for this session. '
  'Primary RLS pattern: USING (organization_id = jwt_org_id()).';


CREATE OR REPLACE FUNCTION public.jwt_property_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(
    auth.jwt() -> 'app_metadata' ->> 'property_id',
    ''
  )::UUID;
$$;

COMMENT ON FUNCTION public.jwt_property_id IS
  'Returns property_id from the current JWT app_metadata. '
  'NULL for org-wide users (owners, org-level managers). '
  'Non-null for property-scoped staff or managers. '
  'Use in property-scoped RLS: USING (property_id = jwt_property_id() OR jwt_is_org_wide()).';


CREATE OR REPLACE FUNCTION public.jwt_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.jwt() -> 'app_metadata' ->> 'user_role';
$$;

COMMENT ON FUNCTION public.jwt_role IS
  'Returns the user_role from the current JWT app_metadata. '
  'Values: owner | manager | staff | viewer. '
  'NULL if hook not registered or token is a service role. '
  'Use for write-permission gates: WITH CHECK (jwt_role() IN (''owner'', ''manager'')).';


CREATE OR REPLACE FUNCTION public.jwt_is_org_wide()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'app_metadata' ->> 'is_org_wide')::BOOLEAN,
    false
  );
$$;

COMMENT ON FUNCTION public.jwt_is_org_wide IS
  'Returns true if the current user has org-wide access (property_id IS NULL in their role). '
  'False for property-scoped users; false if hook not registered. '
  'Use in property RLS: USING (property_id = jwt_property_id() OR jwt_is_org_wide()).';


-- ============================================================
-- STEP 4: custom_access_token_hook(event JSONB)
--
-- Supabase Auth calls this function on every JWT issuance event:
-- initial login, token refresh, and explicit refreshSession() calls.
-- The hook enriches the JWT so RLS policies can evaluate tenant
-- context without additional round trips to the database.
--
-- Input event structure:
--   {
--     "user_id": "<auth.users.id UUID>",
--     "claims": {
--       "aud": "authenticated",
--       "sub": "<auth.users.id>",
--       "email": "...",
--       "app_metadata": {},
--       "user_metadata": {},
--       ...standard JWT claims...
--     }
--   }
--
-- Output: the full event JSONB with claims.app_metadata enriched.
--
-- Claims written to app_metadata:
--   org_id      UUID    — the org the user is currently scoped to
--   property_id UUID    — NULL for org-wide users, set for property-scoped
--   user_role   TEXT    — owner | manager | staff | viewer
--   user_id     UUID    — public.users.id (NOT auth.users.id)
--   is_org_wide BOOLEAN — true when property_id IS NULL
--
-- Org resolution order:
--   1. Find public.users row where auth_user_id = event.user_id
--   2. If users.active_org_id IS NOT NULL → use it (explicit preference)
--   3. Else → find highest-privilege org from active user_roles
--      Priority: owner(1) > manager(2) > staff(3) > viewer(4)
--      Tie-break: earliest role assignment (created_at ASC)
--   4. If no org resolved → return event unchanged
--
-- Role resolution (within resolved org):
--   Selects highest-privilege role for this user in the resolved org.
--   Org-wide roles (property_id IS NULL) are preferred over
--   property-scoped roles of the same privilege level.
--
-- Error handling:
--   All errors caught by EXCEPTION block and logged as WARNINGS.
--   Auth is NEVER blocked by this function — worst case is a JWT
--   without tenant context (no app_metadata enrichment).
--
-- SECURITY DEFINER: hook is invoked by supabase_auth_admin which
-- has no table-level grants. SECURITY DEFINER runs as postgres,
-- which can read users and user_roles.
-- ============================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_auth_user_id  UUID;
  v_user_id       UUID;
  v_active_org_id UUID;
  v_org_id        UUID;
  v_property_id   UUID;
  v_role          TEXT;
  v_is_org_wide   BOOLEAN;
  v_claims        JSONB;
BEGIN
  v_auth_user_id := (event ->> 'user_id')::UUID;

  -- ── Lookup internal user record ──────────────────────────────
  -- The platform user row linked to this Supabase Auth identity.
  -- Returns NULL for users who haven't been linked yet.
  SELECT u.id, u.active_org_id
  INTO   v_user_id, v_active_org_id
  FROM   public.users u
  WHERE  u.auth_user_id = v_auth_user_id;

  -- User not in public.users: service account, unlinked pre-provisioned
  -- user, or an auth identity with no platform record. Return unchanged.
  IF v_user_id IS NULL THEN
    RETURN event;
  END IF;

  -- ── Resolve target org ───────────────────────────────────────
  IF v_active_org_id IS NOT NULL THEN
    -- Explicit org preference stored on the user row.
    -- Validate that the user still has an active role in this org.
    -- If not (role revoked, org deleted), fall through to auto-resolve.
    SELECT ur.organization_id
    INTO   v_org_id
    FROM   public.user_roles ur
    WHERE  ur.user_id         = v_user_id
      AND  ur.organization_id = v_active_org_id
      AND  ur.revoked_at      IS NULL
    LIMIT 1;
  END IF;

  IF v_org_id IS NULL THEN
    -- No valid active_org_id: resolve from highest-privilege active role.
    -- Priority: owner(1) > manager(2) > staff(3) > viewer(4).
    -- Tie-break: earliest created_at (first assigned role wins).
    SELECT ur.organization_id
    INTO   v_org_id
    FROM   public.user_roles ur
    WHERE  ur.user_id    = v_user_id
      AND  ur.revoked_at IS NULL
    ORDER BY
      CASE ur.role
        WHEN 'owner'   THEN 1
        WHEN 'manager' THEN 2
        WHEN 'staff'   THEN 3
        WHEN 'viewer'  THEN 4
        ELSE 5
      END,
      ur.created_at ASC
    LIMIT 1;
  END IF;

  -- User exists but has no active roles anywhere — no tenant context to add.
  IF v_org_id IS NULL THEN
    RETURN event;
  END IF;

  -- ── Resolve role within the target org ───────────────────────
  -- Prefer org-wide roles (property_id IS NULL) over property-scoped
  -- roles at the same privilege level. Within the same privilege level
  -- and scope, prefer the earliest assignment.
  SELECT ur.role, ur.property_id, (ur.property_id IS NULL)
  INTO   v_role, v_property_id, v_is_org_wide
  FROM   public.user_roles ur
  WHERE  ur.user_id         = v_user_id
    AND  ur.organization_id = v_org_id
    AND  ur.revoked_at      IS NULL
  ORDER BY
    CASE ur.role
      WHEN 'owner'   THEN 1
      WHEN 'manager' THEN 2
      WHEN 'staff'   THEN 3
      WHEN 'viewer'  THEN 4
      ELSE 5
    END,
    (ur.property_id IS NULL) DESC,
    ur.created_at ASC
  LIMIT 1;

  -- Guard: org resolved but role query returned nothing.
  -- Shouldn't happen (org came from user_roles), but handle it cleanly.
  IF v_role IS NULL THEN
    RETURN event;
  END IF;

  -- ── Enrich JWT app_metadata ───────────────────────────────────
  v_claims := event -> 'claims';
  v_claims := jsonb_set(
    v_claims,
    '{app_metadata}',
    COALESCE(v_claims -> 'app_metadata', '{}') || jsonb_build_object(
      'org_id',      v_org_id,
      'property_id', v_property_id,
      'user_role',   v_role,
      'user_id',     v_user_id,
      'is_org_wide', COALESCE(v_is_org_wide, false)
    )
  );

  RETURN jsonb_set(event, '{claims}', v_claims);

EXCEPTION WHEN OTHERS THEN
  -- Auth is never blocked by this hook. Log the failure and return
  -- the original event. The user gets a JWT without tenant context
  -- (demo_allow_all_* policies still permit access).
  RAISE WARNING
    'custom_access_token_hook: error for auth_user_id=%, SQLERRM=%, SQLSTATE=%',
    v_auth_user_id, SQLERRM, SQLSTATE;
  RETURN event;
END;
$$;

COMMENT ON FUNCTION public.custom_access_token_hook IS
  'Supabase Auth custom_access_token_hook. Register in: '
  'Authentication → Hooks → Custom Access Token. '
  'Enriches JWT app_metadata with: org_id, property_id, user_role, user_id, is_org_wide. '
  'Org resolution: active_org_id preference → highest-privilege role fallback. '
  'Returns event unchanged if user is not found or has no active roles. '
  'Never blocks auth — all errors are caught and logged as WARNINGs.';


-- ============================================================
-- STEP 5: user_accessible_orgs view
--
-- security_invoker = true
--   The view executes in the calling user's security context.
--   RLS policies on users, user_roles, and organizations are
--   evaluated as if the calling user queried those tables directly.
--   When demo_allow_all_* policies are replaced with tenant-scoped
--   policies, this view automatically respects the new restrictions
--   without requiring a view change.
--
-- The WHERE clause filters to the current auth.uid() regardless
-- of RLS mode. This ensures each user only sees their own orgs
-- even in demo mode where RLS allows all rows through.
--
-- Use cases:
--   • Org-switcher dropdown — show all orgs the user can access
--   • Settings page header — show current org name and user role
--   • Onboarding flow — check if user already has an org or needs to create one
--   • Permission guards — check if user has 'owner' role before showing admin UI
-- ============================================================

CREATE OR REPLACE VIEW public.user_accessible_orgs
WITH (security_invoker = true)
AS
SELECT
  o.id                           AS organization_id,
  o.name                         AS organization_name,
  o.slug,
  o.plan,
  o.status                       AS organization_status,
  ur.role                        AS user_role,
  ur.property_id,
  (ur.property_id IS NULL)       AS is_org_wide,
  ur.created_at                  AS role_granted_at
FROM public.organizations o
JOIN public.user_roles ur ON ur.organization_id = o.id
JOIN public.users u        ON u.id              = ur.user_id
WHERE ur.revoked_at IS NULL
  AND u.auth_user_id = auth.uid();

COMMENT ON VIEW public.user_accessible_orgs IS
  'All organizations and roles accessible to the current authenticated user. '
  'security_invoker = true — RLS on underlying tables is applied in the calling '
  'user''s context. Filters by auth.uid() so each user only sees their own orgs. '
  'Returns no rows when called without an auth session (e.g., SQL editor with no JWT). '
  'Consumers: org-switcher dropdown, settings header, onboarding checks.';


-- ============================================================
-- STEP 6: Grants
-- ============================================================

-- JWT helpers are read-only wrappers around auth.jwt().
-- Safe to expose to all roles including anon (for RLS evaluation
-- on public-read endpoints where the JWT may be empty).
GRANT EXECUTE ON FUNCTION public.jwt_org_id()        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jwt_property_id()   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jwt_role()          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.jwt_is_org_wide()   TO anon, authenticated;

-- user_accessible_orgs: requires auth.uid() to return meaningful rows.
-- Granting to authenticated only — anon users have no auth identity.
GRANT SELECT ON public.user_accessible_orgs TO authenticated;

-- custom_access_token_hook: callable only by the Supabase Auth service.
-- Revoke from PUBLIC (the default) so no frontend or API call can invoke it.
-- supabase_auth_admin is the role used by Supabase Auth when executing hooks.
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(JSONB)
  TO supabase_auth_admin;

REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(JSONB)
  FROM PUBLIC;


-- ============================================================
-- STEP 7: Verification queries + post-migration manual steps
--
-- Verification queries are commented out. Run each block
-- individually in the Supabase SQL editor after applying this file.
-- ============================================================

-- ──────────────────────────────────────────────────────────────
-- 7a. Confirm auth_user_id and active_org_id columns exist.
--     Expected: 2 rows.
--
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM   information_schema.columns
-- WHERE  table_schema = 'public'
--   AND  table_name   = 'users'
--   AND  column_name  IN ('auth_user_id', 'active_org_id')
-- ORDER BY column_name;
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7b. Confirm indexes exist on users.
--     Expected: 2 rows.
--
-- SELECT indexname, indexdef
-- FROM   pg_indexes
-- WHERE  schemaname = 'public'
--   AND  tablename  = 'users'
--   AND  indexname  IN ('idx_users_auth_user_id', 'idx_users_active_org_id')
-- ORDER BY indexname;
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7c. Confirm JWT helper functions exist, are SECURITY DEFINER,
--     and return the correct types.
--     Expected: 4 rows — proname, return_type, security_definer=true.
--
-- SELECT
--   proname,
--   pg_get_function_result(oid) AS return_type,
--   prosecdef                   AS security_definer
-- FROM   pg_proc
-- WHERE  pronamespace = 'public'::regnamespace
--   AND  proname IN ('jwt_org_id', 'jwt_property_id', 'jwt_role', 'jwt_is_org_wide')
-- ORDER BY proname;
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7d. Confirm custom_access_token_hook exists, is SECURITY DEFINER.
--     Expected: 1 row, security_definer = true.
--
-- SELECT
--   proname,
--   pg_get_function_result(oid) AS return_type,
--   prosecdef                   AS security_definer
-- FROM   pg_proc
-- WHERE  pronamespace = 'public'::regnamespace
--   AND  proname = 'custom_access_token_hook';
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7e. Confirm hook grant: supabase_auth_admin can execute,
--     PUBLIC cannot.
--     Expected: 1 row — grantee = supabase_auth_admin, privilege_type = EXECUTE.
--     There should be NO row for grantee = PUBLIC or grantee = anon.
--
-- SELECT grantee, privilege_type, is_grantable
-- FROM   information_schema.routine_privileges
-- WHERE  routine_schema = 'public'
--   AND  routine_name   = 'custom_access_token_hook'
-- ORDER BY grantee;
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7f. Confirm user_accessible_orgs view exists with security_invoker.
--     Expected: 1 row. reloptions should contain 'security_invoker=true'.
--
-- SELECT relname, reloptions
-- FROM   pg_class
-- WHERE  relnamespace = 'public'::regnamespace
--   AND  relname      = 'user_accessible_orgs';
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7g. Test JWT helpers return NULL when called without an auth
--     session (SQL editor has no JWT by default).
--     Expected: all four values are NULL / false.
--
-- SELECT
--   jwt_org_id()      AS org_id,
--   jwt_property_id() AS property_id,
--   jwt_role()        AS role,
--   jwt_is_org_wide() AS is_org_wide;
-- ──────────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────────
-- 7h. Dry-run the hook with the Aries org owner's hypothetical auth_user_id.
--     This simulates what the Auth service sends to the hook.
--     Replace <AUTH_USER_UUID> with an actual UUID after backfilling.
--
--     Expected output: claims.app_metadata includes org_id (Aries UUID),
--     user_role = 'owner', is_org_wide = true, property_id = null.
--
-- SELECT public.custom_access_token_hook(jsonb_build_object(
--   'user_id', '<AUTH_USER_UUID>'::TEXT,
--   'claims',  jsonb_build_object(
--     'aud',          'authenticated',
--     'sub',          '<AUTH_USER_UUID>',
--     'email',        'aries@test.com',
--     'app_metadata', '{}'::JSONB
--   )
-- ));
-- ──────────────────────────────────────────────────────────────


-- ============================================================
-- POST-MIGRATION MANUAL STEPS
-- ============================================================
--
-- ──────────────────────────────────────────────────────────────
-- STEP A: Backfill auth_user_id for demo users
-- ──────────────────────────────────────────────────────────────
-- Create Supabase Auth users for your demo accounts:
--   Supabase Dashboard → Authentication → Users → Invite User
--     aries@test.com
--     blue@test.com
--
-- Then find each user's auth.users UUID in the dashboard and run:
--
--   UPDATE public.users
--   SET auth_user_id = '<UUID from Supabase Auth dashboard>'
--   WHERE email = 'aries@test.com';
--
--   UPDATE public.users
--   SET auth_user_id = '<UUID from Supabase Auth dashboard>'
--   WHERE email = 'blue@test.com';
--
-- Confirm the links:
--   SELECT email, auth_user_id, active_org_id FROM public.users;
--
--
-- ──────────────────────────────────────────────────────────────
-- STEP B: Register custom_access_token_hook in Supabase Auth
-- ──────────────────────────────────────────────────────────────
-- Location:
--   Supabase Dashboard → Authentication → Hooks → Custom Access Token Hook
--
-- Settings:
--   Hook type : Custom Access Token
--   Schema    : public
--   Function  : custom_access_token_hook
--
-- After saving:
--   All new JWTs include the enriched app_metadata.
--   Existing active sessions are NOT enriched until token expiry
--   or an explicit supabase.auth.refreshSession() call.
--
--
-- ──────────────────────────────────────────────────────────────
-- STEP C: Verify JWT enrichment after first login
-- ──────────────────────────────────────────────────────────────
-- In the browser console after logging in as aries@test.com:
--
--   const { data: { session } } = await supabase.auth.getSession();
--   const payload = JSON.parse(atob(session.access_token.split('.')[1]));
--   console.log(payload.app_metadata);
--
-- Expected output:
--   {
--     "org_id":      "00000000-0000-0000-0000-000000000001",  ← Aries org UUID
--     "property_id": null,
--     "user_role":   "owner",
--     "user_id":     "<aries_platform_user_uuid>",
--     "is_org_wide": true
--   }
--
-- For blue@test.com, expected:
--   {
--     "org_id":      "00000000-0000-0000-0000-000000000002",  ← Blue Ridge UUID
--     "property_id": null,
--     "user_role":   "owner",
--     "user_id":     "<blue_platform_user_uuid>",
--     "is_org_wide": true
--   }
--
--
-- ──────────────────────────────────────────────────────────────
-- STEP D: Test active_org_id switching
-- ──────────────────────────────────────────────────────────────
-- To test org-switching for a user with roles in multiple orgs:
--
--   -- Switch to a specific org
--   const { error } = await supabase
--     .from('users')
--     .update({ active_org_id: '<target_org_uuid>' })
--     .eq('auth_user_id', session.user.id);
--
--   -- Force JWT refresh to pick up the new org context
--   const { data: { session: newSession } } = await supabase.auth.refreshSession();
--   const newPayload = JSON.parse(atob(newSession.access_token.split('.')[1]));
--   console.log(newPayload.app_metadata.org_id); // should equal target_org_uuid
--
--
-- ──────────────────────────────────────────────────────────────
-- STEP E: Replace demo_allow_all_* RLS policies (after JWT verified)
-- ──────────────────────────────────────────────────────────────
-- Do NOT proceed until Step C confirms jwt_org_id() returns the correct
-- UUID for at least one logged-in test user. Replacing policies before
-- verifying the hook will lock out all users including the demo frontend.
--
-- Example replacement for reservations (apply per-table):
--
--   -- Remove the permissive demo policy
--   DROP POLICY IF EXISTS "demo_allow_all_reservations" ON public.reservations;
--
--   -- Tenant-scoped read: only see your org's reservations
--   CREATE POLICY "tenant_select_reservations"
--     ON public.reservations FOR SELECT
--     USING (organization_id = jwt_org_id());
--
--   -- Tenant-scoped insert: can only insert into your org
--   CREATE POLICY "tenant_insert_reservations"
--     ON public.reservations FOR INSERT
--     WITH CHECK (organization_id = jwt_org_id());
--
--   -- Tenant-scoped update: owners and managers only
--   CREATE POLICY "tenant_update_reservations"
--     ON public.reservations FOR UPDATE
--     USING  (organization_id = jwt_org_id())
--     WITH CHECK (
--       organization_id = jwt_org_id()
--       AND jwt_role() IN ('owner', 'manager')
--     );
--
-- Repeat for: guests, loyalty, loyalty_by_property, guest_org_profiles,
-- webhook_events, properties, organizations, users, user_roles.
--
-- The jwt_org_id(), jwt_role(), jwt_is_org_wide(), jwt_property_id()
-- helpers defined in Step 3 are the building blocks for all of these.
-- ============================================================
