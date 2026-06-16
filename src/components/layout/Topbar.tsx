import { useAuth } from '../../context/AuthProvider'

// Top bar: signed-in identity + sign out. (The org switcher lands here in a
// later step alongside OrgProvider — not implemented in 5A.)
export function Topbar() {
  const { session, signOut } = useAuth()
  const email = session?.user?.email ?? ''

  return (
    <header className="sticky top-0 z-30 h-16 bg-white border-b border-gray-200 flex items-center px-4 sm:px-6 lg:px-8">
      {/* Brand shown only on mobile where the sidebar is hidden */}
      <div className="md:hidden flex items-center gap-2">
        <span className="text-xl">&#9978;</span>
        <span className="font-bold text-forest-700 text-base tracking-tight">Campground OS</span>
      </div>

      <div className="flex-1" />

      <div className="flex items-center gap-3">
        {email && (
          <span className="hidden sm:block text-sm text-gray-500 truncate max-w-[220px]">{email}</span>
        )}
        <button
          onClick={() => { void signOut() }}
          className="px-3 py-2 rounded-lg text-sm font-medium text-gray-600 hover:text-gray-900 hover:bg-gray-50 transition-colors"
        >
          Sign out
        </button>
      </div>
    </header>
  )
}
