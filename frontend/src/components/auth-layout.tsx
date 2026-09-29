import { EyeIcon, EyeOffIcon } from 'lucide-react'
import { useState, type ComponentProps, type ReactNode } from 'react'

import { SpryLogo } from '@/components/app-shell'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { authConfig } from '@/lib/auth'

type Props = {
  title: string
  subtitle: string
  children: ReactNode
  footer: ReactNode
}

/**
 * Split screen shared by the login and signup pages: a dark Spry panel on wide screens, the
 * form on the right. Tightens on short screens so it fits without scrolling.
 */
export function AuthLayout({ title, subtitle, children, footer }: Props) {
  return (
    <div className="grid min-h-svh lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
      <aside className="relative hidden overflow-hidden bg-sidebar p-10 text-white lg:flex lg:flex-col">
        <div
          className="pointer-events-none absolute -top-40 -right-40 size-[32rem] rounded-full bg-primary/40 blur-3xl"
          aria-hidden
        />
        <SpryLogo inverted className="relative" />
        <div className="relative mt-auto flex max-w-md flex-col gap-4">
          <p className="text-3xl leading-tight font-semibold tracking-tight">
            Fewer, shorter, better meetings.
          </p>
          <p className="text-slate-400">
            See the whole week at a glance, spot where the hours go, and book the next one in
            seconds.
          </p>
          <div className="mt-4 grid grid-cols-3 gap-3">
            {[
              ['12', 'meetings / week'],
              ['−18%', 'hours vs last week'],
              ['3.4', 'avg. attendees'],
            ].map(([value, label]) => (
              <div key={label} className="rounded-xl border border-white/10 bg-white/5 p-3">
                <p className="text-xl font-semibold tabular-nums">{value}</p>
                <p className="text-xs text-slate-400">{label}</p>
              </div>
            ))}
          </div>
        </div>
      </aside>

      <div className="flex flex-col items-center justify-center-safe px-4 py-6 short:py-3">
        <div className="flex w-full max-w-sm flex-col gap-6 short:gap-3">
          <SpryLogo className="lg:hidden short:hidden" />
          <div className="flex flex-col gap-1">
            <h1 className="text-2xl leading-tight">{title}</h1>
            <p className="text-sm text-muted-foreground short:hidden">{subtitle}</p>
          </div>
          <div className="flex flex-col gap-4 short:gap-3">{children}</div>
          <p className="text-sm text-muted-foreground">{footer}</p>
        </div>
      </div>
    </div>
  )
}

/** "or" between the Google button and the form. */
export function OrDivider() {
  return (
    <div className="flex items-center gap-3" aria-hidden>
      <div className="hairline flex-1" />
      <span className="text-xs font-medium text-muted-foreground uppercase">or</span>
      <div className="hairline flex-1" />
    </div>
  )
}

function GoogleLogo() {
  return (
    <svg viewBox="0 0 48 48" className="size-5" aria-hidden>
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  )
}

/** Stays visible but disabled until Google is set up in Cognito (COGNITO_GOOGLE_ENABLED). */
export function GoogleButton({
  pending,
  children,
  disabled,
  ...props
}: ComponentProps<typeof Button> & { pending?: boolean }) {
  const enabled = authConfig.googleEnabled
  return (
    <Button
      type="button"
      variant="outline"
      className="w-full"
      disabled={disabled || !enabled}
      title={enabled ? undefined : 'Google sign-in is not enabled yet'}
      {...props}
    >
      <GoogleLogo />
      {pending ? 'Connecting to Google...' : children}
      {!enabled && (
        <span className="rounded-md bg-secondary px-1.5 py-0.5 text-[0.7rem] text-secondary-foreground">
          Soon
        </span>
      )}
    </Button>
  )
}

/** Shown instead of working forms when the build has no Cognito ids. */
export function AuthNotConfigured() {
  return (
    <Alert variant="destructive">
      <AlertTitle>Sign-in is not configured</AlertTitle>
      <AlertDescription>
        Run <code>make deploy-auth</code>, then rebuild the app (<code>make up</code>).
      </AlertDescription>
    </Alert>
  )
}

/** Password input with a show/hide toggle. */
export function PasswordInput(props: Omit<ComponentProps<typeof Input>, 'type'>) {
  const [visible, setVisible] = useState(false)
  return (
    <div className="relative">
      <Input type={visible ? 'text' : 'password'} className="pr-11" {...props} />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="absolute top-1/2 right-1 -translate-y-1/2"
        aria-label={visible ? 'Hide password' : 'Show password'}
        title={visible ? 'Hide password' : 'Show password'}
        onClick={() => setVisible((v) => !v)}
      >
        {visible ? <EyeOffIcon /> : <EyeIcon />}
      </Button>
    </div>
  )
}
