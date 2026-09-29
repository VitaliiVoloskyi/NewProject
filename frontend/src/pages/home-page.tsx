import { useState } from 'react'
import { addDays } from 'date-fns'
import { PlusIcon } from 'lucide-react'

import { AppShell } from '@/components/app-shell'
import { DateNavigation, ViewSwitcher } from '@/components/calendar-toolbar'
import { DeleteMeetingDialog } from '@/components/delete-meeting-dialog'
import { MeetingDetailsDialog } from '@/components/meeting-details-dialog'
import { MeetingFormDialog } from '@/components/meeting-form-dialog'
import { MeetingsView } from '@/components/meetings-view'
import { WeekStats } from '@/components/week-stats'
import { Button } from '@/components/ui/button'
import { useMeetings } from '@/hooks/queries'
import type { Meeting } from '@/lib/api'
import { useAuth } from '@/lib/auth'
import { STEP_DAYS, visibleDays, type ViewMode } from '@/lib/calendar'
import { formatRange } from '@/lib/format'

export function HomePage() {
  const { user } = useAuth()
  const meetings = useMeetings()
  const [mode, setMode] = useState<ViewMode>('list')
  const [anchor, setAnchor] = useState(() => new Date())
  const days = visibleDays(mode, anchor)
  const [formOpen, setFormOpen] = useState(false)
  // Kept after the form closes so the dialog doesn't flip to "Add meeting" while fading out.
  const [meetingToEdit, setMeetingToEdit] = useState<Meeting | null>(null)
  const [newMeetingStart, setNewMeetingStart] = useState<Date | null>(null)
  const [detailsOpen, setDetailsOpen] = useState(false)
  const [viewedId, setViewedId] = useState<string | null>(null)
  const [meetingToDelete, setMeetingToDelete] = useState<Meeting | null>(null)

  // Look the meeting up in the list so the details stay fresh after an edit.
  const viewedMeeting = meetings.data?.find((m) => m.id === viewedId) ?? null

  const openCreate = (start: Date | null = null) => {
    setMeetingToEdit(null)
    setNewMeetingStart(start)
    setFormOpen(true)
  }
  const openEdit = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToEdit(meeting)
    setFormOpen(true)
  }
  const openDetails = (meeting: Meeting) => {
    setViewedId(meeting.id)
    setDetailsOpen(true)
  }
  const openDelete = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToDelete(meeting)
  }

  const pickDay = (day: Date) => {
    setAnchor(day)
    setMode('day')
  }

  return (
    <AppShell>
      <header className="flex flex-col gap-3 px-4 pt-4 pb-3 md:px-6 md:pt-6">
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl">Meetings</h1>
            <p className="truncate text-sm text-muted-foreground">
              {user ? `Welcome back, ${user.name.split(' ')[0]}.` : 'Your schedule at a glance.'}
            </p>
          </div>
          <Button onClick={() => openCreate()} aria-label="Add meeting" className="max-sm:px-3">
            <PlusIcon />
            <span className="max-sm:hidden">New meeting</span>
          </Button>
        </div>
        {meetings.data && meetings.data.length > 0 && (
          <WeekStats
            meetings={meetings.data}
            anchor={anchor}
            onOpen={openDetails}
            className={mode === 'list' ? undefined : 'max-md:hidden'}
          />
        )}
        <div className="flex flex-wrap items-center justify-between gap-2">
          <DateNavigation
            rangeLabel={formatRange(mode, days)}
            onPrev={() => setAnchor((d) => addDays(d, -STEP_DAYS[mode]))}
            onNext={() => setAnchor((d) => addDays(d, STEP_DAYS[mode]))}
            onToday={() => setAnchor(new Date())}
          />
          <ViewSwitcher mode={mode} onModeChange={setMode} />
        </div>
      </header>

      <main className="min-h-0 flex-1 px-4 pb-4 md:px-6 md:pb-6">
        <MeetingsView
          mode={mode}
          days={days}
          onPickDay={pickDay}
          onAdd={() => openCreate()}
          onCreateAt={openCreate}
          onOpen={openDetails}
          onEdit={openEdit}
          onDelete={openDelete}
        />
      </main>

      <MeetingFormDialog
        open={formOpen}
        onOpenChange={setFormOpen}
        meeting={meetingToEdit}
        initialStart={newMeetingStart}
      />
      <MeetingDetailsDialog
        meeting={viewedMeeting}
        open={detailsOpen}
        onOpenChange={setDetailsOpen}
        onEdit={openEdit}
        onDelete={openDelete}
      />
      <DeleteMeetingDialog meeting={meetingToDelete} onClose={() => setMeetingToDelete(null)} />
    </AppShell>
  )
}
