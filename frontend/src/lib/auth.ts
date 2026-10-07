import { useMutation } from '@tanstack/react-query'
import { UserManager, WebStorageStateStore, type User as OidcUser } from 'oidc-client-ts'
import { useAuth as useOidc } from 'react-oidc-context'

export type User = {
  name: string
  email: string
  provider: 'password' | 'google'
}

export type PasswordChangeData = { currentPassword: string; newPassword: string }

// Public Cognito ids, baked in at build time (make deploy-auth writes them to .env).
const env = import.meta.env
export const authConfig = {
  userPoolId: env.COGNITO_USER_POOL_ID ?? '',
  clientId: env.COGNITO_CLIENT_ID ?? '',
  domain: env.COGNITO_DOMAIN ?? '',
  googleEnabled: env.COGNITO_GOOGLE_ENABLED === 'true',
}
export const authConfigured = Boolean(
  authConfig.userPoolId && authConfig.clientId && authConfig.domain,
)
// The pool id starts with its region: "us-east-1_AbC123".
const region = authConfig.userPoolId.split('_')[0]
const origin = window.location.origin

/** Where Cognito sends the browser after sign-in; listed in infra/auth.yaml (CallbackURLs). */
export const CALLBACK_PATH = '/auth/callback'

/**
 * Talks OIDC to the user pool: the authorization code flow with PKCE, from a public client.
 * The tokens live in localStorage, so the session survives a reload or a new tab, and are
 * renewed with the refresh token.
 */
export const userManager = new UserManager({
  authority: `https://cognito-idp.${region}.amazonaws.com/${authConfig.userPoolId}`,
  client_id: authConfig.clientId,
  redirect_uri: `${origin}${CALLBACK_PATH}`,
  response_type: 'code',
  // aws.cognito.signin.user.admin: the profile page edits the user's own attributes.
  scope: 'openid email profile aws.cognito.signin.user.admin',
  userStore: new WebStorageStateStore({ store: window.localStorage }),
})

/** Carried through the round trip to Cognito: the page to open once signed in. */
export type SigninState = { from?: string }

function toUser({ profile }: OidcUser): User {
  const email = String(profile.email ?? '')
  return {
    name: String(profile.name ?? email.split('@')[0]),
    email,
    // Federated (Google) accounts carry an "identities" claim.
    provider: profile.identities ? 'google' : 'password',
  }
}

// One refresh at a time, however many API calls find the tokens expired together.
let refreshing: Promise<OidcUser | null> | null = null

/** New tokens from the refresh token; signs out locally when that no longer works. */
function refreshTokens(): Promise<OidcUser | null> {
  refreshing ??= userManager
    .signinSilent()
    .catch(async () => {
      await userManager.removeUser()
      return null
    })
    .finally(() => {
      refreshing = null
    })
  return refreshing
}

/** The stored user, with tokens renewed first if they have expired. */
async function currentUser(): Promise<OidcUser | null> {
  if (!authConfigured) return null
  const user = await userManager.getUser()
  return user?.expired ? refreshTokens() : user
}

/** The ID token the API expects (`Authorization: Bearer ...`). */
export async function getIdToken(): Promise<string | null> {
  return (await currentUser())?.id_token ?? null
}

/** Ends the local session without leaving the page (the API rejected the token). */
export function forgetSession(): Promise<void> {
  return userManager.removeUser()
}

export type AuthContextValue = {
  /** undefined while the stored session (or Cognito's redirect back) is being processed. */
  user: User | null | undefined
  /** Leaves for Cognito's managed login; `google` skips it and goes straight to Google. */
  signIn: (options?: { from?: string; google?: boolean }) => Promise<void>
  signOut: () => Promise<void>
}

export function useAuth(): AuthContextValue {
  const oidc = useOidc()
  // An expired ID token is not the end of the session: the refresh token (30 days) renews it
  // before the next API call. Only a missing user means signed out.
  const user = !authConfigured
    ? null
    : oidc.isLoading
      ? undefined
      : oidc.user
        ? toUser(oidc.user)
        : null

  const signIn: AuthContextValue['signIn'] = ({ from, google } = {}) =>
    userManager.signinRedirect({
      state: { from } satisfies SigninState,
      ...(google && { extraQueryParams: { identity_provider: 'Google' } }),
    })

  // Cognito has no OIDC end-session endpoint: clear the local session, then let Cognito end
  // its own (the cookie that would otherwise sign the user straight back in) on /logout.
  const signOut = async () => {
    await userManager.removeUser()
    const params = new URLSearchParams({ client_id: authConfig.clientId, logout_uri: `${origin}/` })
    window.location.assign(`https://${authConfig.domain}/logout?${params}`)
  }

  return { user, signIn, signOut }
}

// --- Profile changes (password accounts only: Google sets the name and email every sign-in).
// They go to Cognito's user API with the user's own access token; no AWS credentials needed.

// Cognito's exception names -> messages for people.
const MESSAGES: Record<string, string> = {
  NotAuthorizedException: 'Current password is wrong',
  AliasExistsException: 'An account with this email already exists',
  CodeMismatchException: 'That code is not right; check the email and try again',
  ExpiredCodeException: 'That code has expired; send a new one',
  LimitExceededException: 'Too many attempts; wait a few minutes and try again',
  TooManyRequestsException: 'Too many attempts; wait a few minutes and try again',
  InvalidPasswordException: 'Use at least 8 characters, with a lowercase letter and a number',
}

async function cognito<T = unknown>(action: string, body: Record<string, unknown>): Promise<T> {
  const user = await currentUser()
  if (!user) throw new Error('You are signed out; sign in again')
  const response = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': `AWSCognitoIdentityProviderService.${action}`,
    },
    body: JSON.stringify({ AccessToken: user.access_token, ...body }),
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok) {
    // "__type" is the exception name, sometimes prefixed with a namespace and "#".
    const name =
      String(data.__type ?? '')
        .split('#')
        .pop() ?? ''
    throw new Error(MESSAGES[name] ?? data.message ?? 'Something went wrong')
  }
  return data as T
}

export const authApi = {
  updateName: async (name: string) => {
    await cognito('UpdateUserAttributes', { UserAttributes: [{ Name: 'name', Value: name }] })
    // Fresh tokens, so the new name reaches the app and the API (it reads the ID token).
    await refreshTokens()
  },
  /** Cognito emails a code to the new address; the email changes once `confirmEmail` checks it. */
  changeEmail: async (email: string) => {
    const { CodeDeliveryDetailsList } = await cognito<{ CodeDeliveryDetailsList?: unknown[] }>(
      'UpdateUserAttributes',
      { UserAttributes: [{ Name: 'email', Value: email }] },
    )
    return { needsConfirmation: Boolean(CodeDeliveryDetailsList?.length) }
  },
  confirmEmail: async (code: string) => {
    await cognito('VerifyUserAttribute', { AttributeName: 'email', Code: code })
    await refreshTokens()
  },
  resendEmailCode: async () => {
    await cognito('GetUserAttributeVerificationCode', { AttributeName: 'email' })
  },
  changePassword: async ({ currentPassword, newPassword }: PasswordChangeData) => {
    await cognito('ChangePassword', {
      PreviousPassword: currentPassword,
      ProposedPassword: newPassword,
    })
  },
}

export function useUpdateName() {
  return useMutation({ mutationFn: authApi.updateName })
}

export function useChangeEmail() {
  return useMutation({ mutationFn: authApi.changeEmail })
}

export function useConfirmEmail() {
  return useMutation({ mutationFn: authApi.confirmEmail })
}

export function useResendEmailCode() {
  return useMutation({ mutationFn: authApi.resendEmailCode })
}

export function useChangePassword() {
  return useMutation({ mutationFn: authApi.changePassword })
}
