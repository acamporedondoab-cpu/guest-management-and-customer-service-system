import { createContext, useContext, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'

export type AppRole = 'owner' | 'manager' | 'staff' | 'viewer'

interface AuthContextValue {
  session: Session | null
  loading: boolean
  // Custom claims from custom_access_token_hook, read from the JWT (NOT from
  // session.user.app_metadata, which only holds {provider, providers}).
  role: AppRole | null
  orgId: string | null
  propertyId: string | null
  isOrgWide: boolean
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined)

interface Claims {
  role: AppRole | null
  orgId: string | null
  propertyId: string | null
  isOrgWide: boolean
}

const EMPTY_CLAIMS: Claims = { role: null, orgId: null, propertyId: null, isOrgWide: false }
const ROLES: AppRole[] = ['owner', 'manager', 'staff', 'viewer']

function asRole(v: unknown): AppRole | null {
  return typeof v === 'string' && (ROLES as string[]).includes(v) ? (v as AppRole) : null
}
function asString(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null
}

// Decode the enriched claims from the access token. getClaims() verifies and
// returns the JWT payload; the hook writes our custom keys into app_metadata.
async function readClaims(jwt: string): Promise<Claims> {
  try {
    const { data, error } = await supabase.auth.getClaims(jwt)
    if (error || !data) return EMPTY_CLAIMS
    const am = (data.claims.app_metadata ?? {}) as Record<string, unknown>
    return {
      role: asRole(am.user_role),
      orgId: asString(am.org_id),
      propertyId: asString(am.property_id),
      isOrgWide: am.is_org_wide === true,
    }
  } catch {
    return EMPTY_CLAIMS
  }
}

// Owns the Supabase Auth session AND the derived JWT claims. Session
// persistence + token refresh are configured on the client (lib/supabase.ts);
// this provider mirrors the session into React state, decodes the custom claims
// from the access token, and exposes sign in / sign out.
export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [claims, setClaims] = useState<Claims>(EMPTY_CLAIMS)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let mounted = true

    // Resolve session + claims together so they always update atomically.
    async function sync(next: Session | null) {
      const nextClaims = next ? await readClaims(next.access_token) : EMPTY_CLAIMS
      if (!mounted) return
      setSession(next)
      setClaims(nextClaims)
    }

    // Restore any persisted session on first load.
    void supabase.auth.getSession().then(({ data }) => {
      void sync(data.session).finally(() => { if (mounted) setLoading(false) })
    })

    // Keep state in sync with sign in / sign out / token refresh. Each event
    // carries the current session, so claims are re-decoded from the new token.
    const { data: sub } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      void sync(nextSession)
    })

    return () => {
      mounted = false
      sub.subscription.unsubscribe()
    }
  }, [])

  async function signIn(email: string, password: string) {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
  }

  async function signOut() {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
  }

  return (
    <AuthContext.Provider
      value={{
        session,
        loading,
        role: claims.role,
        orgId: claims.orgId,
        propertyId: claims.propertyId,
        isOrgWide: claims.isOrgWide,
        signIn,
        signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider')
  return ctx
}
