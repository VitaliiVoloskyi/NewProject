import { addDays, differenceInMinutes, format, isToday, isTomorrow, startOfWeek } from 'date-fns'
import {
  ArrowDownRightIcon,
  ArrowUpRightIcon,
  CalendarCheckIcon,
  ClockIcon,
  MinusIcon,
  UsersIcon,
  ZapIcon,
} from 'lucide-react'
import type { ReactNode } from 'react'

import type { Meeting } from '@/lib/api'
import { cn } from '@/lib/utils'

type WeekNumbers = { count: number; hours: number; attendees: number }

/** Meetings that start in [from, from + 7 days). */
function weekNumbers(meetings: Meeting[], from: Date): WeekNumbers {
  const to = addDays(from, 7)
  const inWeek = meetings.filter((m) => {
    const start = new Date(m.starts_at)
    return start >= from && start < to
  })
  const minutes = inWeek.reduce(
    (sum, m) => sum + differenceInMinutes(new Date(m.ends_at), new Date(m.starts_at)),
    0,
  )
  const people = inWeek.reduce((sum, m) => sum + m.participants.length, 0)
  return {
    count: inWeek.length,
    hours: minutes / 60,
    attendees: inWeek.length ? people / inWeek.length : 0,
  }
}

const oneDecimal = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1))

function Delta({
  current,
  previous,
  unit = '',
}: {
  current: number
  previous: number
  unit?: string
}) {
  const diff = Math.round((current - previous) * 10) / 10
  const pct = previous >= 2 ? Math.round((diff / previous) * 100) : null
  const Icon = diff > 0 ? ArrowUpRightIcon : diff < 0 ? ArrowDownRightIcon : MinusIcon
  return (
    <span
      className={cn(
        'inline-flex items-center gap-0.5 rounded-md px-1.5 py-0.5 text-xs font-medium tabular-nums',
        diff > 0 && 'bg-emerald-50 text-success',
        diff < 0 && 'bg-rose-50 text-destructive',
        diff === 0 && 'bg-muted text-muted-foreground',
      )}
      title={`Last week: ${oneDecimal(previous)}${unit}`}
    >
      <Icon className="size-3.5" />
      {diff === 0 ? 'no change' : `${diff > 0 ? '+' : ''}${oneDecimal(diff)}${unit}`}
      {pct !== null && diff !== 0 && (
        <span className="opacity-70 max-sm:hidden">
          ({pct > 0 ? '+' : ''}
          {pct}%)
        </span>
      )}
    </span>
  )
}

function StatCard({
  label,
  icon,
  value,
  footer,
}: {
  label: string
  icon: ReactNode
  value: ReactNode
  footer: ReactNode
}) {
  return (
    <div className="flex h-full min-w-0 flex-col gap-1.5 rounded-xl border bg-card p-3 shadow-xs sm:gap-2 sm:p-4">
      <div className="flex items-center justify-between text-sm text-muted-foreground">
        <span className="truncate font-medium max-sm:text-xs">{label}</span>
        <span className="flex size-7 items-center justify-center rounded-lg bg-secondary text-secondary-foreground [&_svg]:size-4">
          {icon}
        </span>
      </div>
      <div className="truncate text-xl font-semibold tracking-tight tabular-nums sm:text-2xl">
        {value}
      </div>
      <div className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
        {footer}
      </div>
    </div>
  )
}

function nextLabel(start: Date): string {
  if (isToday(start)) return `Today, ${format(start, 'HH:mm')}`
  if (isTomorrow(start)) return `Tomorrow, ${format(start, 'HH:mm')}`
  return format(start, 'EEE d MMM, HH:mm')
}

/**
 * KPI row for the week that contains `anchor` (Monday to Sunday), each number compared with
 * the week before, plus the next upcoming meeting.
 */
export function WeekStats({
  meetings,
  anchor,
  onOpen,
  className,
}: {
  meetings: Meeting[]
  anchor: Date
  onOpen: (meeting: Meeting) => void
  className?: string
}) {
  const weekStart = startOfWeek(anchor, { weekStartsOn: 1 })
  const current = weekNumbers(meetings, weekStart)
  const previous = weekNumbers(meetings, addDays(weekStart, -7))
  const now = new Date()
  const next = meetings
    .filter((m) => new Date(m.starts_at) > now)
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))[0]
  const vs = <span className="max-sm:hidden">vs last week</span>

  return (
    <section
      aria-label={`Week of ${format(weekStart, 'd MMMM')}`}
      className={cn('grid grid-cols-2 gap-3 xl:grid-cols-4', className)}
    >
      <StatCard
        label="Meetings this week"
        icon={<CalendarCheckIcon />}
        value={current.count}
        footer={
          <>
            <Delta current={current.count} previous={previous.count} />
            {vs}
          </>
        }
      />
      <StatCard
        label="Hours booked"
        icon={<ClockIcon />}
        value={`${oneDecimal(Math.round(current.hours * 10) / 10)} h`}
        footer={
          <>
            <Delta
              current={Math.round(current.hours * 10) / 10}
              previous={Math.round(previous.hours * 10) / 10}
              unit=" h"
            />
            {vs}
          </>
        }
      />
      <StatCard
        label="Avg. attendees"
        icon={<UsersIcon />}
        value={oneDecimal(Math.round(current.attendees * 10) / 10)}
        footer={
          <>
            <Delta
              current={Math.round(current.attendees * 10) / 10}
              previous={Math.round(previous.attendees * 10) / 10}
            />
            {vs}
          </>
        }
      />
      <button
        type="button"
        disabled={!next}
        onClick={() => next && onOpen(next)}
        className="h-full rounded-xl text-left outline-none focus-visible:ring-3 focus-visible:ring-ring/50 enabled:hover:[&>div]:border-primary/40"
      >
        <StatCard
          label="Next up"
          icon={<ZapIcon />}
          value={
            <span className="text-base sm:text-lg">{next ? next.title : 'Nothing scheduled'}</span>
          }
          footer={
            next ? (
              <span className="truncate">
                {nextLabel(new Date(next.starts_at))} · {next.place}
              </span>
            ) : (
              <span>Your calendar is clear</span>
            )
          }
        />
      </button>
    </section>
  )
}
