interface SpinnerProps {
  size?: 'sm' | 'md' | 'lg'
  label?: string
}

const sizeStyles = {
  sm: 'w-4 h-4',
  md: 'w-6 h-6',
  lg: 'w-10 h-10',
}

export function Spinner({ size = 'md', label = 'Loading...' }: SpinnerProps) {
  return (
    <div className="flex items-center gap-2 text-gray-500">
      <div
        className={`${sizeStyles[size]} border-2 border-gray-200 border-t-forest-600 rounded-full animate-spin`}
        role="status"
        aria-label={label}
      />
      {label && <span className="text-sm">{label}</span>}
    </div>
  )
}
