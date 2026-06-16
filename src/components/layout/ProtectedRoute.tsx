import { Navigate } from 'react-router-dom'
import { useAuth } from '../../context/AuthProvider'
import { Spinner } from '../ui/Spinner'

// Gates protected content. While the persisted session is being restored we
// show a spinner (avoids a flash redirect); with no session we send the user
// to /login. (Org context + layout are wired in Step 5.)
export function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { session, loading } = useAuth()

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <Spinner size="lg" label="Loading..." />
      </div>
    )
  }

  if (!session) {
    return <Navigate to="/login" replace />
  }

  return <>{children}</>
}
