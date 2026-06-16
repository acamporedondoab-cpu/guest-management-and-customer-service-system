interface BadgeProps {
  label: string
  variant: 'gold' | 'silver' | 'bronze' | 'confirmed' | 'checked_in' | 'checked_out' | 'cancelled' | 'pending' | 'sent' | 'failed' | 'neutral'
}

const styles: Record<BadgeProps['variant'], string> = {
  gold:        'bg-yellow-100 text-yellow-800',
  silver:      'bg-gray-100 text-gray-700',
  bronze:      'bg-orange-100 text-orange-700',
  confirmed:   'bg-blue-100 text-blue-800',
  checked_in:  'bg-green-100 text-green-800',
  checked_out: 'bg-gray-100 text-gray-600',
  cancelled:   'bg-red-100 text-red-700',
  pending:     'bg-yellow-100 text-yellow-700',
  sent:        'bg-green-100 text-green-700',
  failed:      'bg-red-100 text-red-700',
  neutral:     'bg-gray-100 text-gray-600',
}

export function Badge({ label, variant }: BadgeProps) {
  return (
    <span className={`badge ${styles[variant]}`}>
      {label}
    </span>
  )
}
