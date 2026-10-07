import { useQueryClient } from '@tanstack/react-query'
import { useEffect, type ReactNode } from 'react'
import { AuthProvider as OidcAuthProvider } from 'react-oidc-context'

import { userManager } from '@/lib/auth'

/** Drops the code and state from the address bar once they have been exchanged for tokens. */
function onSigninCallback() {
  window.history.replaceState(window.history.state, '', window.location.pathname)
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()

  // The next user must not see this user's cached meetings.
  useEffect(() => userManager.events.addUserUnloaded(() => queryClient.clear()), [queryClient])

  return (
    <OidcAuthProvider userManager={userManager} onSigninCallback={onSigninCallback}>
      {children}
    </OidcAuthProvider>
  )
}
