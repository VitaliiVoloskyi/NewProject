import { useRef } from 'react'
import { ClockIcon, MapPinIcon, PencilIcon, Trash2Icon, UsersIcon } from 'lucide-react'

import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import type { Meeting } from '@/lib/api'
import { formatWhen } from '@/lib/format'

function isUrl(value: string): boolean {
  return /^https?:\/\/\S+$/.test(value)
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onEdit: (meeting: Meeting) => void
  onDelete: (meeting: Meeting) => void
}

export function MeetingDetailsDialog({ meeting, open, onOpenChange, onEdit, onDelete }: Props) {
  const editButtonRef = useRef<HTMLButtonElement>(null)

  return (
    <Dialog open={open && meeting !== null} onOpenChange={onOpenChange}>
      <DialogContent
        className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-lg"
        // Radix would focus the first button (Delete); start on Edit instead.
        onOpenAutoFocus={(event) => {
          event.preventDefault()
          editButtonRef.current?.focus()
        }}
      >
        {meeting && (
          <>
            <DialogHeader>
              <DialogTitle className="pr-8 text-xl leading-tight">{meeting.title}</DialogTitle>
              <DialogDescription className="flex items-center gap-2">
                <ClockIcon className="size-4 shrink-0" />
                {formatWhen(meeting)}
              </DialogDescription>
            </DialogHeader>

            <div className="-mx-6 flex flex-col gap-5 overflow-y-auto px-6">
              <div className="flex items-start gap-2">
                <MapPinIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                {isUrl(meeting.place) ? (
                  <a
                    href={meeting.place}
                    target="_blank"
                    rel="noreferrer"
                    className="break-all underline underline-offset-4 hover:text-primary"
                  >
                    {meeting.place}
                  </a>
                ) : (
                  <span className="break-words">{meeting.place}</span>
                )}
              </div>

              {meeting.description && (
                <>
                  <div className="hairline" />
                  <p className="leading-relaxed whitespace-pre-line text-foreground/90">
                    {meeting.description}
                  </p>
                </>
              )}

              <div className="hairline" />
              <div className="flex flex-col gap-3">
                <h3 className="flex items-center gap-2 text-sm">
                  <UsersIcon className="size-4" />
                  Participants
                  <span className="rounded-md bg-muted px-1.5 text-xs text-muted-foreground">
                    {meeting.participants.length}
                  </span>
                </h3>
                {meeting.participants.length === 0 ? (
                  <p className="text-muted-foreground">No participants yet.</p>
                ) : (
                  <ul className="flex flex-col gap-2">
                    {meeting.participants.map((p) => (
                      <li key={p.id} className="flex items-center gap-3">
                        <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-secondary text-xs font-semibold text-secondary-foreground">
                          {p.name.charAt(0).toUpperCase()}
                        </span>
                        <span className="flex min-w-0 flex-col">
                          <span className="truncate font-medium">{p.name}</span>
                          <a
                            href={`mailto:${p.email}`}
                            className="text-sm text-muted-foreground hover:text-primary"
                          >
                            {p.email}
                          </a>
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </div>

            <DialogFooter className="sm:justify-between">
              <Button variant="ghost" onClick={() => onDelete(meeting)}>
                <Trash2Icon />
                Delete
              </Button>
              <Button ref={editButtonRef} onClick={() => onEdit(meeting)}>
                <PencilIcon />
                Edit
              </Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
