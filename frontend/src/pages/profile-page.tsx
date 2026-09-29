import { zodResolver } from '@hookform/resolvers/zod'
import { ArrowLeftIcon, LogOutIcon } from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { Link } from 'react-router'
import { toast } from 'sonner'
import { z } from 'zod'

import { AppShell } from '@/components/app-shell'
import { PasswordInput } from '@/components/auth-layout'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import {
  useAuth,
  useChangeEmail,
  useChangePassword,
  useConfirmEmail,
  useResendEmailCode,
  useUpdateName,
  type User,
} from '@/lib/auth'

function Section({
  title,
  description,
  children,
}: {
  title: string
  description: string
  children: ReactNode
}) {
  return (
    <section className="grid gap-4 rounded-xl border bg-card p-5 shadow-xs md:grid-cols-[14rem_minmax(0,1fr)] md:gap-8">
      <div>
        <h2 className="text-base">{title}</h2>
        <p className="text-sm text-muted-foreground">{description}</p>
      </div>
      <div>{children}</div>
    </section>
  )
}

const nameSchema = z.object({ name: z.string().trim().min(1, 'Enter your name').max(100) })

function NameForm({ user }: { user: User }) {
  const updateName = useUpdateName()
  const form = useForm<z.infer<typeof nameSchema>>({
    resolver: zodResolver(nameSchema),
    defaultValues: { name: user.name },
  })
  const onSubmit = form.handleSubmit(({ name }) =>
    updateName.mutate(name.trim(), {
      onSuccess: () => {
        form.reset({ name: name.trim() })
        toast.success('Name saved')
      },
      onError: (error) => form.setError('root', { message: error.message }),
    }),
  )
  return (
    <form onSubmit={onSubmit} noValidate>
      <FieldGroup className="gap-3">
        <Controller
          name="name"
          control={form.control}
          render={({ field, fieldState }) => (
            <Field data-invalid={fieldState.invalid}>
              <FieldLabel htmlFor="profile-name">Name</FieldLabel>
              <Input
                id="profile-name"
                autoComplete="name"
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
        <Button
          type="submit"
          className="self-start"
          disabled={!form.formState.isDirty || updateName.isPending}
        >
          {updateName.isPending ? 'Saving...' : 'Save name'}
        </Button>
      </FieldGroup>
    </form>
  )
}

const emailSchema = z.object({ email: z.email('Enter a valid email') })
const codeSchema = z.object({ code: z.string().trim().min(1, 'Enter the code from the email') })

function EmailForm({ user }: { user: User }) {
  const [pendingEmail, setPendingEmail] = useState<string | null>(null)
  const changeEmail = useChangeEmail()
  const confirmEmail = useConfirmEmail()
  const resend = useResendEmailCode()
  const emailForm = useForm<z.infer<typeof emailSchema>>({
    resolver: zodResolver(emailSchema),
    defaultValues: { email: '' },
  })
  const codeForm = useForm<z.infer<typeof codeSchema>>({
    resolver: zodResolver(codeSchema),
    defaultValues: { code: '' },
  })

  const submitEmail = emailForm.handleSubmit(({ email }) =>
    changeEmail.mutate(email, {
      onSuccess: ({ needsConfirmation }) => {
        if (needsConfirmation) setPendingEmail(email)
        else toast.success('Email changed')
        emailForm.reset()
      },
      onError: (error) => emailForm.setError('root', { message: error.message }),
    }),
  )
  const submitCode = codeForm.handleSubmit(({ code }) =>
    confirmEmail.mutate(code.trim(), {
      onSuccess: () => {
        setPendingEmail(null)
        codeForm.reset()
        toast.success('Email changed')
      },
      onError: (error) => codeForm.setError('root', { message: error.message }),
    }),
  )

  if (pendingEmail) {
    return (
      <form onSubmit={submitCode} noValidate>
        <FieldGroup className="gap-3">
          <Alert>
            <AlertDescription>
              We sent a code to <strong>{pendingEmail}</strong>. Until you enter it, you keep
              signing in with {user.email}.
            </AlertDescription>
          </Alert>
          <Controller
            name="code"
            control={codeForm.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="profile-code">Code</FieldLabel>
                <Input
                  id="profile-code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          {codeForm.formState.errors.root && (
            <FieldError>{codeForm.formState.errors.root.message}</FieldError>
          )}
          <div className="flex flex-wrap gap-2">
            <Button type="submit" disabled={confirmEmail.isPending}>
              {confirmEmail.isPending ? 'Verifying...' : 'Verify email'}
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={resend.isPending}
              onClick={() =>
                resend.mutate(undefined, {
                  onSuccess: () => toast.success('New code sent'),
                  onError: (error) => toast.error(error.message),
                })
              }
            >
              Send a new code
            </Button>
            <Button type="button" variant="ghost" onClick={() => setPendingEmail(null)}>
              Cancel
            </Button>
          </div>
        </FieldGroup>
      </form>
    )
  }

  return (
    <form onSubmit={submitEmail} noValidate>
      <FieldGroup className="gap-3">
        <p className="text-sm">
          Current: <span className="font-medium">{user.email}</span>
        </p>
        <Controller
          name="email"
          control={emailForm.control}
          render={({ field, fieldState }) => (
            <Field data-invalid={fieldState.invalid}>
              <FieldLabel htmlFor="profile-email">New email</FieldLabel>
              <Input
                id="profile-email"
                type="email"
                autoComplete="email"
                aria-invalid={fieldState.invalid}
                {...field}
              />
              <FieldError errors={[fieldState.error]} />
            </Field>
          )}
        />
        {emailForm.formState.errors.root && (
          <FieldError>{emailForm.formState.errors.root.message}</FieldError>
        )}
        <Button type="submit" className="self-start" disabled={changeEmail.isPending}>
          {changeEmail.isPending ? 'Sending code...' : 'Change email'}
        </Button>
      </FieldGroup>
    </form>
  )
}

const passwordSchema = z
  .object({
    currentPassword: z.string().min(1, 'Enter your current password'),
    newPassword: z.string().min(8, 'Use at least 8 characters'),
    confirmPassword: z.string(),
  })
  .refine((v) => v.newPassword === v.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

type PasswordValues = z.infer<typeof passwordSchema>

function PasswordForm() {
  const changePassword = useChangePassword()
  const form = useForm<PasswordValues>({
    resolver: zodResolver(passwordSchema),
    defaultValues: { currentPassword: '', newPassword: '', confirmPassword: '' },
  })
  const onSubmit = form.handleSubmit(({ currentPassword, newPassword }) =>
    changePassword.mutate(
      { currentPassword, newPassword },
      {
        onSuccess: () => {
          form.reset()
          toast.success('Password changed')
        },
        onError: (error) => form.setError('root', { message: error.message }),
      },
    ),
  )
  const fields: { name: keyof PasswordValues; label: string; autoComplete: string }[] = [
    { name: 'currentPassword', label: 'Current password', autoComplete: 'current-password' },
    { name: 'newPassword', label: 'New password', autoComplete: 'new-password' },
    { name: 'confirmPassword', label: 'Confirm new password', autoComplete: 'new-password' },
  ]
  return (
    <form onSubmit={onSubmit} noValidate>
      <FieldGroup className="gap-3">
        {fields.map(({ name, label, autoComplete }) => (
          <Controller
            key={name}
            name={name}
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor={`profile-${name}`}>{label}</FieldLabel>
                <PasswordInput
                  id={`profile-${name}`}
                  autoComplete={autoComplete}
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
        ))}
        {form.formState.errors.root && (
          <FieldError>{form.formState.errors.root.message}</FieldError>
        )}
        <Button type="submit" className="self-start" disabled={changePassword.isPending}>
          {changePassword.isPending ? 'Saving...' : 'Change password'}
        </Button>
      </FieldGroup>
    </form>
  )
}

export function ProfilePage() {
  const { user, signOut } = useAuth()
  if (!user) return null

  return (
    <AppShell>
      <main className="min-h-0 flex-1 overflow-y-auto px-4 py-4 md:px-6 md:py-6">
        <div className="mx-auto flex max-w-3xl flex-col gap-5">
          <Link
            to="/home"
            className="inline-flex items-center gap-1.5 self-start rounded-md text-sm text-muted-foreground outline-none hover:text-foreground focus-visible:ring-3 focus-visible:ring-ring/50"
          >
            <ArrowLeftIcon className="size-4" />
            Back to meetings
          </Link>

          <div className="flex items-center gap-4">
            <span className="flex size-14 items-center justify-center rounded-full bg-primary text-xl font-semibold text-primary-foreground">
              {user.name.charAt(0).toUpperCase()}
            </span>
            <div className="min-w-0">
              <h1 className="truncate text-2xl">{user.name}</h1>
              <p className="truncate text-sm text-muted-foreground">{user.email}</p>
            </div>
          </div>

          {user.provider === 'google' ? (
            <Alert>
              <AlertDescription>
                You sign in with Google, which sets your name and email every time you sign in.
                Change them in your Google account.
              </AlertDescription>
            </Alert>
          ) : (
            <>
              <Section title="Name" description="How you appear to other people.">
                <NameForm user={user} />
              </Section>
              <Section title="Email" description="We send a code to confirm the new address.">
                <EmailForm user={user} />
              </Section>
              <Section title="Password" description="At least 8 characters.">
                <PasswordForm />
              </Section>
            </>
          )}

          <Button variant="outline" className="self-start" onClick={signOut}>
            <LogOutIcon />
            Sign out
          </Button>
        </div>
      </main>
    </AppShell>
  )
}
