import { NavLink } from 'react-router-dom'

const navItems = [
  { to: '/',             label: 'Dashboard' },
  { to: '/guests',       label: 'Guests' },
  { to: '/reservations', label: 'Reservations' },
  { to: '/properties',   label: 'Properties' },
  { to: '/team',         label: 'Team' },
  { to: '/onboarding',   label: 'Onboarding' },
  { to: '/integrations', label: 'Integrations' },
  { to: '/settings',     label: 'Settings' },
]

export function Sidebar() {
  return (
    <aside className="w-60 shrink-0 bg-white border-r border-gray-200 hidden md:flex flex-col">
      {/* Brand */}
      <div className="h-16 flex items-center gap-2 px-5 border-b border-gray-100">
        <span className="text-2xl">&#9978;</span>
        <span className="font-bold text-forest-700 text-lg tracking-tight">Campground OS</span>
      </div>

      {/* Navigation */}
      <nav className="flex-1 p-3 space-y-1">
        {navItems.map(({ to, label }) => (
          <NavLink
            key={to}
            to={to}
            end={to === '/'}
            className={({ isActive }) =>
              `block px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                isActive
                  ? 'bg-forest-50 text-forest-700'
                  : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'
              }`
            }
          >
            {label}
          </NavLink>
        ))}
      </nav>
    </aside>
  )
}
