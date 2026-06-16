import { createClient } from '@supabase/supabase-js'
import type { Database } from './types'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Missing Supabase environment variables. ' +
    'Copy .env.example to .env.local and fill in VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.'
  )
}

// Typed client against the v7 Database generic (lib/types.ts).
// Reads resolve to safe-view row types; the two write RPCs are typed.
// Session is persisted + auto-refreshed so the JWT (with org claims from
// custom_access_token_hook) stays valid across reloads. Org switching
// re-issues the JWT via supabase.auth.refreshSession() (Phase 2.0).
export const supabase = createClient<Database>(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})
