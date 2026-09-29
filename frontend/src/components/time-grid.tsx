import { addMinutes, differenceInMinutes, format, isToday, startOfDay } from 'date-fns'
import { PlusIcon } from 'lucide-react'
import { useEffect, useLayoutEffect, useRef, useState, type MouseEvent } from 'react'

import { cn } from '@/lib/utils'
import type { Meeting } from '@/lib/api'
import { layoutDay, type PositionedMeeting } from '@/lib/calendar'
import { formatTimeOnDay } from '@/lib/format'

const HOUR_PX = 48
const GRID_PX = 24 * HOUR_PX
const MIN_BLOCK_PX = 20
const SLOT_MIN = 30
/** Where the grid scrolls to when nothing better is known. */
const DEFAULT_SCROLL_HOUR = 8
/** Height of the sticky day headings; block titles stick just below it. */
const HEADER_CLASS = 'h-[4.5rem]'

function useNow(intervalMs = 60_000): Date {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

const minutesToPx = (min: number) => (min / 60) * HOUR_PX

function MeetingBlock({
  item,
  day,
  onOpen,
}: {
  item: PositionedMeeting
  day: Date
  onOpen: (meeting: Meeting) => void
}) {
  const { meeting } = item
  const height = Math.max(MIN_BLOCK_PX, minutesToPx(item.endMin - item.startMin))
  const time = formatTimeOnDay(meeting, day)
  // Short meetings put the time on the title line, like Google Calendar.
  const compact = height < 40
  return (
    <button
      type="button"
      onClick={() => onOpen(meeting)}
      title={`${meeting.title} · ${time} · ${meeting.place}`}
      className="absolute flex flex-col justify-start overflow-clip rounded-md border-l-3 border-primary bg-secondary px-1.5 py-0.5 text-left text-secondary-foreground shadow-[0_0_0_1.5px_var(--card)] transition-colors outline-none hover:bg-[#dfe5fd] focus-visible:ring-3 focus-visible:ring-ring/50"
      style={{
        top: minutesToPx(item.startMin),
        height,
        left: `calc(${(item.lane / item.lanes) * 100}% + 1px)`,
        width: `calc(${100 / item.lanes}% - 3px)`,
      }}
    >
      {compact ? (
        <p className="truncate text-xs leading-4">
          <span className="text-xs font-semibold">{meeting.title}</span>
          <span className="tabular-nums">, {time}</span>
        </p>
      ) : (
        // Sticky, so a long meeting scrolled halfway out of view still shows what it is.
        <div className="sticky top-[4.5rem]">
          <p className="truncate text-xs leading-tight font-semibold">{meeting.title}</p>
          <p className="truncate text-xs tabular-nums">{time}</p>
          {height >= 60 && (
            <p className="truncate text-xs text-muted-foreground">{meeting.place}</p>
          )}
        </div>
      )}
    </button>
  )
}

type Props = {
  days: Date[]
  meetings: Meeting[]
  onOpen: (meeting: Meeting) => void
  /** Clicking an empty slot: add a meeting starting there. */
  onCreateAt: (start: Date) => void
  /** Clicking a day heading, e.g. to jump from the week to that day. */
  onPickDay?: (day: Date) => void
}

/**
 * Day or week calendar: one column per day, all 24 hours in a scroll area that fills the
 * screen. It opens scrolled to the current time (if today is shown) or the first meeting.
 */
export function TimeGrid({ days, meetings, onOpen, onCreateAt, onPickDay }: Props) {
  const now = useNow()
  const scrollRef = useRef<HTMLDivElement>(null)
  // The empty slot under the mouse, previewed as "+ 10:30".
  const [hovered, setHovered] = useState<{ day: number; min: number } | null>(null)
  const columns = days.map((day) => layoutDay(meetings, day))
  const nowMin = differenceInMinutes(now, startOfDay(now))
  const gridTemplateColumns = `3.5rem repeat(${days.length}, minmax(0, 1fr))`

  // Scroll only when the visible days change, not when meetings are saved or deleted.
  const rangeKey = `${days[0].toISOString()}/${days.length}`
  const scrollTargetMin = days.some((d) => isToday(d))
    ? nowMin - 90
    : Math.min(
        DEFAULT_SCROLL_HOUR * 60,
        ...columns.flat().map((item) => (item.continuesBefore ? Infinity : item.startMin - 30)),
      )
  useLayoutEffect(() => {
    scrollRef.current?.scrollTo({ top: minutesToPx(Math.max(0, scrollTargetMin)) })
    // eslint-disable-next-line react-hooks/exhaustive-deps -- rerun only for a new range
  }, [rangeKey])

  /** Minutes since midnight of the 30-minute slot under the pointer. */
  const slotAt = (event: MouseEvent<HTMLElement>) => {
    const y = event.clientY - event.currentTarget.getBoundingClientRect().top
    const slot = Math.floor((y / HOUR_PX) * (60 / SLOT_MIN))
    return Math.min(Math.max(slot, 0), (24 * 60) / SLOT_MIN - 1) * SLOT_MIN
  }

  return (
    <div ref={scrollRef} className="h-full overflow-auto rounded-xl border bg-card shadow-xs">
      <div className={cn('relative', days.length > 1 && 'min-w-[44rem]')}>
        {/* Day headings stay visible while the hours scroll. */}
        <div
          className={cn('sticky top-0 z-20 grid items-center border-b bg-card', HEADER_CLASS)}
          style={{ gridTemplateColumns }}
        >
          <div className="sticky left-0 bg-card" />
          {days.map((day) => {
            const today = isToday(day)
            const content = (
              <>
                <span
                  className={cn(
                    'text-[0.7rem] font-semibold tracking-[0.15em] text-muted-foreground uppercase',
                    today && 'text-primary',
                  )}
                >
                  {format(day, 'EEE')}
                </span>
                <span
                  className={cn(
                    'flex size-9 items-center justify-center rounded-full text-lg font-semibold',
                    today && 'bg-primary text-primary-foreground',
                  )}
                >
                  {format(day, 'd')}
                </span>
              </>
            )
            return onPickDay ? (
              <button
                key={day.toISOString()}
                type="button"
                onClick={() => onPickDay(day)}
                aria-label={format(day, 'EEEE, d MMMM')}
                className="flex flex-col items-center gap-0.5 rounded-xl py-0.5 outline-none hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/50"
              >
                {content}
              </button>
            ) : (
              <div key={day.toISOString()} className="flex flex-col items-center gap-0.5 py-0.5">
                {content}
              </div>
            )
          })}
        </div>

        {/* Hours and meetings */}
        <div className="grid pt-2 pb-2" style={{ gridTemplateColumns }}>
          <div className="sticky left-0 z-10 bg-card" style={{ height: GRID_PX }}>
            {Array.from({ length: 23 }, (_, i) => i + 1).map((hour) => (
              <span
                key={hour}
                className="absolute right-2 -translate-y-1/2 text-[0.7rem] text-muted-foreground tabular-nums"
                style={{ top: hour * HOUR_PX }}
              >
                {String(hour).padStart(2, '0')}:00
              </span>
            ))}
          </div>
          {days.map((day, i) => (
            <div
              key={day.toISOString()}
              className={cn('relative cursor-pointer border-l', isToday(day) && 'bg-secondary/40')}
              title="Click to add a meeting"
              // Only the empty column counts; clicks on meeting blocks open the meeting instead.
              onMouseMove={(event) =>
                setHovered(
                  event.target === event.currentTarget ? { day: i, min: slotAt(event) } : null,
                )
              }
              onMouseLeave={() => setHovered(null)}
              onClick={(event) => {
                if (event.target !== event.currentTarget) return
                onCreateAt(addMinutes(startOfDay(day), slotAt(event)))
              }}
              style={{
                height: GRID_PX,
                backgroundImage: 'linear-gradient(var(--border) 1px, transparent 1px)',
                backgroundSize: `100% ${HOUR_PX}px`,
              }}
            >
              {hovered?.day === i && (
                <div
                  className="pointer-events-none absolute inset-x-0.5 flex items-start gap-1 rounded-md border border-dashed border-primary bg-primary/10 px-1.5 py-0.5 text-xs font-semibold text-primary tabular-nums"
                  style={{
                    top: minutesToPx(hovered.min),
                    height: Math.min(HOUR_PX, GRID_PX - minutesToPx(hovered.min)),
                  }}
                  aria-hidden
                >
                  <PlusIcon className="size-3.5 shrink-0" />
                  {format(addMinutes(startOfDay(day), hovered.min), 'HH:mm')}
                </div>
              )}
              {columns[i].map((item) => (
                <MeetingBlock key={item.meeting.id} item={item} day={day} onOpen={onOpen} />
              ))}
              {isToday(day) && (
                <div
                  className="pointer-events-none absolute inset-x-0 z-10 h-0.5 bg-hover"
                  style={{ top: minutesToPx(nowMin) }}
                  aria-hidden
                >
                  <span className="absolute -top-1 -left-1 size-2.5 rounded-full bg-hover" />
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
