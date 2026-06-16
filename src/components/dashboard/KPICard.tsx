interface KPICardProps {
  label: string
  value: string | number
  sub?: string
  icon: string
  accent?: 'green' | 'amber' | 'blue' | 'purple' | 'red'
}

const accentStyles = {
  green:  'bg-forest-50  text-forest-700',
  amber:  'bg-bark-50    text-bark-700',
  blue:   'bg-blue-50    text-blue-700',
  purple: 'bg-purple-50  text-purple-700',
  red:    'bg-red-50     text-red-700',
}

export function KPICard({ label, value, sub, icon, accent = 'green' }: KPICardProps) {
  return (
    <div className="bg-white rounded-xl border border-gray-200 shadow-sm p-6 flex items-start gap-4">
      <div className={`w-12 h-12 rounded-lg flex items-center justify-center text-2xl flex-shrink-0 ${accentStyles[accent]}`}>
        {icon}
      </div>
      <div className="min-w-0">
        <p className="text-sm text-gray-500 font-medium truncate">{label}</p>
        <p className="text-2xl font-bold text-gray-900 mt-0.5 tabular-nums">{value}</p>
        {sub && <p className="text-xs text-gray-400 mt-0.5">{sub}</p>}
      </div>
    </div>
  )
}
