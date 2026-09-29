import { CalendarXIcon, PlusIcon } from 'lucide-react'

import { MeetingList } from '@/components/meeting-list'
import { TimeGrid } from '@/components/time-grid'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useMeetings } from '@/hooks/queries'
import type { Meeting } from '@/lib/api'
import type { ViewMode } from '@/lib/calendar'

type Props = {
  mode: ViewMode
  days: Date[]
  onAdd: () => void
  /** Add a meeting starting at the given time (a clicked calendar slot). */
  onCreateAt: (start: Date) => void
  onOpen: (meeting: Meeting) => void
  onEdit: (meeting: Meeting) => void
  onDelete: (meeting: Meeting) => void
  onPickDay: (day: Date) => void
}

/** Loading, error and empty states around the list / day / week views. */
export function MeetingsView({
  mode,
  days,
  onAdd,
  onCreateAt,
  onOpen,
  onEdit,
  onDelete,
  onPickDay,
}: Props) {
  const meetings = useMeetings()

  if (meetings.isPending) {
    return (
      <div className="flex flex-col gap-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Skeleton key={i} className="h-20 w-full rounded-xl border bg-card" />
        ))}
      </div>
    )
  }

  if (meetings.isError) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Could not load meetings</AlertTitle>
        <AlertDescription className="flex flex-col items-start gap-2">
          <span>{meetings.error.message}</span>
          <Button variant="outline" size="sm" onClick={() => meetings.refetch()}>
            Retry
          </Button>
        </AlertDescription>
      </Alert>
    )
  }

  if (meetings.data.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed bg-card py-20 text-center">
        <span className="flex size-12 items-center justify-center rounded-xl bg-secondary text-secondary-foreground">
          <CalendarXIcon className="size-6" />
        </span>
        <h2 className="text-xl">No meetings yet</h2>
        <p className="text-sm text-muted-foreground">
          Plan the first one — it only takes a minute.
        </p>
        <Button onClick={onAdd}>
          <PlusIcon />
          Add meeting
        </Button>
      </div>
    )
  }

  if (mode === 'list') {
    return (
      <div className="h-full overflow-y-auto">
        <MeetingList
          days={days}
          meetings={meetings.data}
          onCreateAt={onCreateAt}
          onOpen={onOpen}
          onEdit={onEdit}
          onDelete={onDelete}
        />
      </div>
    )
  }

  return (
    <TimeGrid
      days={days}
      meetings={meetings.data}
      onOpen={onOpen}
      onCreateAt={onCreateAt}
      onPickDay={mode === 'week' ? onPickDay : undefined}
    />
  )
}
