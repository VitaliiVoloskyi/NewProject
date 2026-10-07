import { useEffect, useRef, useState } from 'react'
import { Link, Navigate, useLocation } from 'react-router'
import { useAuth as useOidc } from 'react-oidc-context'

import { AuthLayout, AuthNotConfigured, GoogleButton } from '@/components/auth-layout'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { authConfig, authConfigured, useAuth, type SigninState } from '@/lib/auth'

/** Where a signed-out visitor was headed (set by RequireAuth). */
function useFrom(): string | undefined {
  return (useLocation().state as SigninState | null)?.from
}

/**
 * /login: sends the browser to Cognito's managed login (email and password, sign-up, and
 * "Continue with Google") as soon as it loads. The login has to start here, not on a copied
 * Cognito URL: the library keeps the random state and PKCE verifier that the callback checks.
 */
export function LoginPage() {
  const { user, signIn } = useAuth()
  const from = useFrom()
  const [error, setError] = useState<string | null>(null)
  const started = useRef(false)

  useEffect(() => {
    // The ref keeps React's development double-run from starting two logins.
    if (!authConfigured || user !== null || started.current) return
    started.current = true
    signIn({ from }).catch((reason: Error) => setError(reason.message))
  }, [user, signIn, from])

  if (user) return <Navigate to={from ?? '/home'} replace />

  return (
    <AuthLayout
      title="Sign in"
      subtitle="Taking you to the sign-in page..."
      footer={<>Email and password or Google, on the next page.</>}
    >
      {!authConfigured && <AuthNotConfigured />}
      {error && (
        <>
          <Alert variant="destructive">
            <AlertTitle>Could not reach the sign-in page</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
          <Button onClick={() => window.location.reload()}>Try again</Button>
        </>
      )}
    </AuthLayout>
  )
}

/** /auth/callback: Cognito sends the browser back here with a code; the library swaps it for tokens. */
export function CallbackPage() {
  const oidc = useOidc()

  if (oidc.error) {
    return (
      <AuthLayout
        title="Sign-in failed"
        subtitle="Cognito sent you back without a session."
        footer={<>If it keeps happening, open the site in a new tab and sign in from there.</>}
      >
        <Alert variant="destructive">
          <AlertDescription>{oidc.error.message}</AlertDescription>
        </Alert>
        <Button asChild>
          <Link to="/login">Try again</Link>
        </Button>
      </AuthLayout>
    )
  }
  if (oidc.isLoading) return null
  const from = (oidc.user?.state as SigninState | undefined)?.from
  return <Navigate to={from ?? '/home'} replace />
}

/** What signed-out visitors see instead of a page that needs an account. */
export function SignedOutPage() {
  const { signIn } = useAuth()
  const from = useLocation().pathname
  const [pending, setPending] = useState(false)

  return (
    <AuthLayout
      title="Welcome to Spry"
      subtitle="Sign in to see your meetings."
      footer={<>New here? Choose “Create an account” on the sign-in page.</>}
    >
      {!authConfigured && <AuthNotConfigured />}
      <Button asChild className="w-full">
        <Link to="/login" state={{ from } satisfies SigninState}>
          Sign in
        </Link>
      </Button>
      {authConfig.googleEnabled && (
        <GoogleButton
          disabled={pending || !authConfigured}
          pending={pending}
          onClick={() => {
            setPending(true)
            signIn({ from, google: true }).catch(() => setPending(false))
          }}
        >
          Continue with Google
        </GoogleButton>
      )}
    </AuthLayout>
  )
}
