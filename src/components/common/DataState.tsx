import { Spinner } from '../ui/Spinner'

interface DataStateProps {
  loading: boolean
  error: string | null
  children: React.ReactNode
}

// Wraps a page body with shared loading / error handling. Renders children
// once data has loaded without error.
export function DataState({ loading, error, children }: DataStateProps) {
  if (loading) {
    return (
      <div className="flex items-center justify-center py-24">
        <Spinner size="lg" label="Loading..." />
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-200 bg-red-50 p-6 text-red-700 text-sm">
        <strong>Connection error:</strong> {error}
      </div>
    )
  }

  return <>{children}</>
}
