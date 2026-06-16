interface StatusPillProps {
  status: string
}

const styles: Record<string, string> = {
  active:   'bg-green-100 text-green-700',
  inactive: 'bg-gray-100 text-gray-600',
  error:    'bg-red-100 text-red-700',
  revoked:  'bg-gray-100 text-gray-500',
  pending:  'bg-yellow-100 text-yellow-700',
  expired:  'bg-gray-100 text-gray-500',
}

// Small read-only status indicator for properties (active/inactive),
// integrations (active/inactive/error), and team (revoked/pending/expired).
export function StatusPill({ status }: StatusPillProps) {
  const cls = styles[status] ?? 'bg-gray-100 text-gray-600'
  return (
    <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-medium ${cls}`}>
      {status}
    </span>
  )
}
