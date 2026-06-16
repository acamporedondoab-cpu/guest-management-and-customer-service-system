import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { AuthProvider } from './context/AuthProvider'
import { ProtectedRoute } from './components/layout/ProtectedRoute'
import { AppLayout } from './components/layout/AppLayout'
import { LoginPage } from './pages/LoginPage'
import { DashboardPage } from './pages/DashboardPage'
import { GuestsPage } from './pages/GuestsPage'
import { ReservationsPage } from './pages/ReservationsPage'
import { NewReservationPage } from './pages/NewReservationPage'
import { PropertiesPage } from './pages/PropertiesPage'
import { TeamPage } from './pages/TeamPage'
import { OnboardingPage } from './pages/OnboardingPage'
import { IntegrationsPage } from './pages/IntegrationsPage'
import { SettingsPage } from './pages/SettingsPage'

// Read-only application pages wired under the AppLayout shell. Guests,
// Reservations, Properties, Integrations, and Settings read from safe views
// via src/api/*. All six nav routes now resolve to real pages. No OrgProvider,
// no writes, no org switching, no JWT/backend changes.
export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            element={
              <ProtectedRoute>
                <AppLayout />
              </ProtectedRoute>
            }
          >
            <Route path="/"             element={<DashboardPage />} />
            <Route path="/guests"       element={<GuestsPage />} />
            <Route path="/reservations" element={<ReservationsPage />} />
            <Route path="/reservations/new" element={<NewReservationPage />} />
            <Route path="/properties"   element={<PropertiesPage />} />
            <Route path="/team"         element={<TeamPage />} />
            <Route path="/onboarding"   element={<OnboardingPage />} />
            <Route path="/integrations" element={<IntegrationsPage />} />
            <Route path="/settings"     element={<SettingsPage />} />
          </Route>
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  )
}
