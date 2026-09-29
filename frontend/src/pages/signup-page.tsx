import { zodResolver } from '@hookform/resolvers/zod'
import { useState } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { Link, useLocation, useNavigate } from 'react-router'
import { toast } from 'sonner'
import { z } from 'zod'

import { AuthLayout, GoogleButton, OrDivider, PasswordInput } from '@/components/auth-layout'
import { Button } from '@/components/ui/button'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { useConfirmSignup, useGoogleLogin, useResendCode, useSignup } from '@/lib/auth'

const signupSchema = z
  .object({
    name: z.string().trim().min(1, 'Enter your name').max(100),
    email: z.email('Enter a valid email'),
    password: z.string().min(8, 'Use at least 8 characters'),
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

type SignupValues = z.infer<typeof signupSchema>

const codeSchema = z.object({ code: z.string().trim().min(1, 'Enter the code from the email') })

/** Second step: the code Cognito emailed. Signs in straight away when it can. */
function ConfirmStep({ email, onBack }: { email: string; onBack: () => void }) {
  const navigate = useNavigate()
  const confirm = useConfirmSignup()
  const resend = useResendCode()
  const form = useForm<z.infer<typeof codeSchema>>({
    resolver: zodResolver(codeSchema),
    defaultValues: { code: '' },
  })
  const onSubmit = form.handleSubmit(({ code }) =>
    confirm.mutate(
      { email, code: code.trim() },
      {
        onSuccess: (user) =>
          user
            ? navigate('/home', { replace: true })
            : navigate('/login', {
                replace: true,
                state: { email, notice: 'Email confirmed. Sign in to continue.' },
              }),
        onError: (error) => form.setError('root', { message: error.message }),
      },
    ),
  )
  return (
    <AuthLayout
      title="Check your email"
      subtitle={`We sent a code to ${email}.`}
      footer={
        <button type="button" onClick={onBack} className="font-medium text-primary hover:underline">
          Use a different email
        </button>
      }
    >
      <form onSubmit={onSubmit} noValidate>
        <FieldGroup className="gap-4 short:gap-3">
          <Controller
            name="code"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-code">Verification code</FieldLabel>
                <Input
                  id="signup-code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  autoFocus
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          {form.formState.errors.root && (
            <FieldError>{form.formState.errors.root.message}</FieldError>
          )}
          <Button type="submit" className="w-full" disabled={confirm.isPending}>
            {confirm.isPending ? 'Verifying...' : 'Verify and continue'}
          </Button>
          <Button
            type="button"
            variant="ghost"
            className="w-full"
            disabled={resend.isPending}
            onClick={() =>
              resend.mutate(email, {
                onSuccess: () => toast.success('New code sent'),
                onError: (error) => toast.error(error.message),
              })
            }
          >
            Send a new code
          </Button>
        </FieldGroup>
      </form>
    </AuthLayout>
  )
}

export function SignupPage() {
  const navigate = useNavigate()
  // Set when Cognito wants the emailed code (after signup, or from the login page).
  const state = useLocation().state as { confirmEmail?: string } | null
  const [confirmEmail, setConfirmEmail] = useState<string | null>(state?.confirmEmail ?? null)
  const signup = useSignup()
  const googleLogin = useGoogleLogin()
  const pending = signup.isPending || googleLogin.isPending
  const form = useForm<SignupValues>({
    resolver: zodResolver(signupSchema),
    defaultValues: { name: '', email: '', password: '', confirmPassword: '' },
  })

  const onSuccess = () => navigate('/home', { replace: true })
  const onError = (error: Error) => form.setError('root', { message: error.message })

  const onSubmit = form.handleSubmit(({ name, email, password }) =>
    signup.mutate(
      { name: name.trim(), email, password },
      {
        onSuccess: ({ needsConfirmation }) =>
          needsConfirmation
            ? setConfirmEmail(email)
            : navigate('/login', { replace: true, state: { email } }),
        onError,
      },
    ),
  )

  if (confirmEmail) return <ConfirmStep email={confirmEmail} onBack={() => setConfirmEmail(null)} />

  return (
    <AuthLayout
      title="Create account"
      subtitle="Plan meetings with your team."
      footer={
        <>
          Already have an account?{' '}
          <Link to="/login" className="font-medium text-primary underline-offset-4 hover:underline">
            Sign in
          </Link>
        </>
      }
    >
      <GoogleButton
        disabled={pending}
        pending={googleLogin.isPending}
        onClick={() => googleLogin.mutate(undefined, { onSuccess, onError })}
      >
        Sign up with Google
      </GoogleButton>
      <OrDivider />
      <form onSubmit={onSubmit} noValidate>
        <FieldGroup className="gap-4 short:gap-3">
          <Controller
            name="name"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-name">Name</FieldLabel>
                <Input
                  id="signup-name"
                  autoComplete="name"
                  autoFocus
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          <Controller
            name="email"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-email">Email</FieldLabel>
                <Input
                  id="signup-email"
                  type="email"
                  autoComplete="email"
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          {/* Side by side on wider screens so the whole form fits without scrolling. */}
          <div className="grid gap-4 sm:grid-cols-2 short:gap-3">
            <Controller
              name="password"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-password">Password</FieldLabel>
                  <PasswordInput
                    id="signup-password"
                    autoComplete="new-password"
                    placeholder="At least 8 characters"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            <Controller
              name="confirmPassword"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-confirm">Confirm</FieldLabel>
                  <PasswordInput
                    id="signup-confirm"
                    autoComplete="new-password"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
          </div>
          {form.formState.errors.root && (
            <FieldError>{form.formState.errors.root.message}</FieldError>
          )}
          <Button type="submit" className="mt-1 w-full" disabled={pending}>
            {signup.isPending ? 'Creating account...' : 'Create account'}
          </Button>
        </FieldGroup>
      </form>
    </AuthLayout>
  )
}
