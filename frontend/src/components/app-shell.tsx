import { CalendarDaysIcon, LogOutIcon, UserRoundIcon } from 'lucide-react'
import type { ReactNode } from 'react'
import { Link, NavLink } from 'react-router'

import { Button } from '@/components/ui/button'
import { useAuth } from '@/lib/auth'
import { cn } from '@/lib/utils'

/** The Spry mark: a bolt in a rounded square, plus the wordmark. */
export function SpryLogo({
  className,
  inverted = false,
}: {
  className?: string
  inverted?: boolean
}) {
  return (
    <span className={cn('inline-flex items-center gap-2', className)}>
      <svg viewBox="0 0 32 32" className="size-7 shrink-0" aria-hidden>
        <rect width="32" height="32" rx="8" fill="var(--primary)" />
        <path fill="#fff" d="M17.8 6 9 18h6l-1.6 8L23 14h-6.2z" />
      </svg>
      <span
        className={cn(
          'text-lg font-semibold tracking-tight',
          inverted ? 'text-white' : 'text-foreground',
        )}
      >
        spry
      </span>
    </span>
  )
}

const NAV = [
  { to: '/home', label: 'Meetings', icon: CalendarDaysIcon },
  { to: '/profile', label: 'Profile', icon: UserRoundIcon },
]

function Avatar({ name, className }: { name: string; className?: string }) {
  return (
    <span
      className={cn(
        'flex size-8 shrink-0 items-center justify-center rounded-full bg-primary text-sm font-semibold text-primary-foreground',
        className,
      )}
    >
      {name.charAt(0).toUpperCase()}
    </span>
  )
}

/**
 * Signed-in layout: a dark sidebar on desktop (logo, navigation, the user), a slim top bar on
 * phones. The page content fills the rest of the viewport.
 */
export function AppShell({ children }: { children: ReactNode }) {
  const { user, signOut } = useAuth()

  return (
    <div className="flex h-svh">
      <aside className="hidden w-60 shrink-0 flex-col bg-sidebar px-3 py-5 text-sidebar-foreground lg:flex">
        <Link to="/home" className="px-2" aria-label="Spry home">
          <SpryLogo inverted />
        </Link>
        <nav className="mt-8 flex flex-col gap-1" aria-label="Main">
          {NAV.map(({ to, label, icon: Icon }) => (
            <NavLink
              key={to}
              to={to}
              className={({ isActive }) =>
                cn(
                  'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors outline-none hover:bg-sidebar-accent hover:text-white focus-visible:ring-2 focus-visible:ring-sidebar-ring',
                  isActive && 'bg-sidebar-accent text-white',
                )
              }
            >
              <Icon className="size-4" />
              {label}
            </NavLink>
          ))}
        </nav>
        {user && (
          <div className="mt-auto flex items-center gap-3 rounded-xl bg-sidebar-accent/60 p-2.5">
            <Avatar name={user.name} />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-white">{user.name}</p>
              <p className="truncate text-xs text-slate-400">{user.email}</p>
            </div>
            <button
              type="button"
              onClick={signOut}
              aria-label="Sign out"
              title="Sign out"
              className="rounded-md p-1.5 text-slate-400 transition-colors outline-none hover:bg-sidebar hover:text-white focus-visible:ring-2 focus-visible:ring-sidebar-ring"
            >
              <LogOutIcon className="size-4" />
            </button>
          </div>
        )}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b bg-card px-4 py-2.5 lg:hidden">
          <Link to="/home" aria-label="Spry home">
            <SpryLogo />
          </Link>
          {user && (
            <div className="flex items-center gap-1">
              <Link
                to="/profile"
                aria-label="Profile"
                title={`${user.name} · ${user.email}`}
                className="rounded-full outline-none focus-visible:ring-3 focus-visible:ring-ring/50"
              >
                <Avatar name={user.name} />
              </Link>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Sign out"
                title="Sign out"
                onClick={signOut}
              >
                <LogOutIcon />
              </Button>
            </div>
          )}
        </div>
        {children}
      </div>
    </div>
  )
}
