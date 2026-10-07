import type { ReactNode } from 'react'
import { Navigate, Route, Routes } from 'react-router'

import { CALLBACK_PATH, useAuth } from '@/lib/auth'
import { HomePage } from '@/pages/home-page'
import { CallbackPage, LoginPage, SignedOutPage } from '@/pages/login-page'
import { ProfilePage } from '@/pages/profile-page'

/** Shows signed-out visitors a page with the Sign in buttons instead. */
function RequireAuth({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  // Still checking the stored session: render nothing rather than flash the signed-out page.
  if (user === undefined) return null
  if (!user) return <SignedOutPage />
  return children
}

// Paths match with or without a trailing slash: /login and /login/ are the same page.
export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Navigate to="/home" replace />} />
      <Route
        path="/home"
        element={
          <RequireAuth>
            <HomePage />
          </RequireAuth>
        }
      />
      <Route
        path="/profile"
        element={
          <RequireAuth>
            <ProfilePage />
          </RequireAuth>
        }
      />
      <Route path="/login" element={<LoginPage />} />
      {/* Cognito's managed login has its own "Create an account". */}
      <Route path="/signup" element={<Navigate to="/login" replace />} />
      <Route path={CALLBACK_PATH} element={<CallbackPage />} />
      <Route path="*" element={<Navigate to="/home" replace />} />
    </Routes>
  )
}
