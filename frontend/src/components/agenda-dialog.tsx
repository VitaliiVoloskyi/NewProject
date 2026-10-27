import { useEffect, useRef, useState } from 'react'
import { format, isValid } from 'date-fns'
import { Loader2Icon, PlusIcon, SparklesIcon, XIcon } from 'lucide-react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Field, FieldDescription, FieldError, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useSaveAgenda } from '@/hooks/queries'
import {
  MAX_AGENDA_TEXT,
  parseAgenda,
  parserConfigured,
  type Agenda,
  type AiSuggestion,
  type Meeting,
} from '@/lib/api'

// Form rows hold strings (what the inputs show) and the names of the fields the model filled
// that the user has not touched yet: those carry a "suggested" badge.
type ItemRow = { key: number; topic: string; owner: string; minutes: string; suggested: string[] }
type ActionRow = { key: number; task: string; owner: string; due: string; suggested: string[] }

let nextKey = 0
const newKey = () => nextKey++

function filled(values: Record<string, unknown>): string[] {
  return Object.keys(values).filter((name) => values[name] !== null && values[name] !== '')
}

function toItemRows(agenda: Agenda | null, suggested: boolean): ItemRow[] {
  return (agenda?.items ?? []).map((item) => ({
    key: newKey(),
    topic: item.topic,
    owner: item.owner ?? '',
    minutes: item.minutes?.toString() ?? '',
    suggested: suggested ? filled(item) : [],
  }))
}

function toActionRows(agenda: Agenda | null, suggested: boolean): ActionRow[] {
  return (agenda?.action_items ?? []).map((action) => ({
    key: newKey(),
    task: action.task,
    owner: action.owner ?? '',
    due: action.due ?? '',
    suggested: suggested ? filled(action) : [],
  }))
}

const emptyItem = (): ItemRow => ({
  key: newKey(),
  topic: '',
  owner: '',
  minutes: '',
  suggested: [],
})
const emptyAction = (): ActionRow => ({
  key: newKey(),
  task: '',
  owner: '',
  due: '',
  suggested: [],
})

/** What the form would save, or the first problem with it. Blank rows are ignored. */
function toAgenda(items: ItemRow[], actions: ActionRow[]): Agenda | string {
  const agenda: Agenda = { items: [], action_items: [] }
  for (const row of items) {
    if (!row.topic.trim() && !row.owner.trim() && !row.minutes) continue
    if (!row.topic.trim()) return 'Every agenda item needs a topic'
    const minutes = row.minutes ? Number(row.minutes) : null
    if (minutes !== null && !(Number.isInteger(minutes) && minutes >= 1 && minutes <= 480)) {
      return 'Minutes must be a whole number from 1 to 480'
    }
    agenda.items.push({ topic: row.topic.trim(), owner: row.owner.trim() || null, minutes })
  }
  for (const row of actions) {
    if (!row.task.trim() && !row.owner.trim() && !row.due) continue
    if (!row.task.trim()) return 'Every action item needs a task'
    agenda.action_items.push({
      task: row.task.trim(),
      owner: row.owner.trim() || null,
      due: row.due || null,
    })
  }
  return agenda
}

/** A suggested start as a date, or as the model wrote it when that is not a date ("2026-11-03
 * after lunch"): model output is never trusted to be well-formed. */
function formatSuggestedStart(value: string): string {
  const date = new Date(value)
  return isValid(date) ? format(date, 'EEE d MMM, HH:mm') : value
}

/** What else the model found in the text, shown as a hint: the meeting itself is edited with
 * Edit, not here. */
function meetingHint({ agenda }: AiSuggestion): string | null {
  const parts = [
    agenda.title && `"${agenda.title}"`,
    agenda.starts_at && formatSuggestedStart(agenda.starts_at),
    agenda.duration_minutes && `${agenda.duration_minutes} min`,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : null
}

function Suggested({ show }: { show: boolean }) {
  if (!show) return null
  return (
    <Badge variant="secondary" className="h-5 px-1.5 text-[10px]">
      <SparklesIcon />
      suggested
    </Badge>
  )
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AgendaDialog({ meeting, open, onOpenChange }: Props) {
  return (
    <Dialog open={open && meeting !== null} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl">
        {/* Mounted on every open, so the form starts from the saved agenda each time and a
            refetch of the meetings while it is open does not reset what the user typed. */}
        {meeting && <AgendaEditor meeting={meeting} onClose={() => onOpenChange(false)} />}
      </DialogContent>
    </Dialog>
  )
}

function AgendaEditor({ meeting, onClose }: { meeting: Meeting; onClose: () => void }) {
  const saveAgenda = useSaveAgenda()
  const [text, setText] = useState('')
  const [parsing, setParsing] = useState(false)
  const [parseError, setParseError] = useState<string | null>(null)
  const [suggestion, setSuggestion] = useState<AiSuggestion | null>(null)
  const [items, setItems] = useState<ItemRow[]>(() => {
    const rows = toItemRows(meeting.agenda, false)
    return rows.length ? rows : [emptyItem()]
  })
  const [actions, setActions] = useState<ActionRow[]>(() => toActionRows(meeting.agenda, false))
  const [formError, setFormError] = useState<string | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  // Closing the dialog stops a parse that is still running.
  useEffect(() => () => abortRef.current?.abort(), [])

  const parse = async () => {
    const controller = new AbortController()
    abortRef.current = controller
    setParsing(true)
    setParseError(null)
    try {
      const result = await parseAgenda(text, controller.signal)
      setSuggestion(result)
      const rows = toItemRows(result.agenda, true)
      setItems(rows.length ? rows : [emptyItem()])
      setActions(toActionRows(result.agenda, true))
      setFormError(null)
      if (!rows.length) setParseError('No agenda items found in this text. Type them below.')
    } catch (error) {
      if (!controller.signal.aborted) setParseError((error as Error).message)
    } finally {
      if (abortRef.current === controller) setParsing(false)
    }
  }

  const cancelParse = () => {
    abortRef.current?.abort()
    setParsing(false)
  }

  // Touching a field clears its "suggested" badge: from then on the value is the user's.
  const editItem = (key: number, field: 'topic' | 'owner' | 'minutes', value: string) =>
    setItems((rows) =>
      rows.map((row) =>
        row.key === key
          ? { ...row, [field]: value, suggested: row.suggested.filter((f) => f !== field) }
          : row,
      ),
    )
  const editAction = (key: number, field: 'task' | 'owner' | 'due', value: string) =>
    setActions((rows) =>
      rows.map((row) =>
        row.key === key
          ? { ...row, [field]: value, suggested: row.suggested.filter((f) => f !== field) }
          : row,
      ),
    )

  const save = (event: React.FormEvent) => {
    event.preventDefault()
    const agenda = toAgenda(items, actions)
    if (typeof agenda === 'string') {
      setFormError(agenda)
      return
    }
    saveAgenda.mutate(
      { id: meeting.id, ...agenda, ai_suggestion: suggestion },
      {
        onSuccess: () => {
          toast.success(agenda.items.length ? 'Agenda saved' : 'Agenda removed')
          onClose()
        },
        onError: (error) => setFormError(error.message),
      },
    )
  }

  const tooLong = text.length > MAX_AGENDA_TEXT
  const hint = suggestion && meetingHint(suggestion)

  return (
    <>
      <DialogHeader>
        <DialogTitle>{meeting.agenda ? 'Edit agenda' : 'Add agenda'}</DialogTitle>
        <DialogDescription>{meeting.title}</DialogDescription>
      </DialogHeader>

      <form
        id="agenda-form"
        onSubmit={save}
        className="-mx-6 flex flex-col gap-6 overflow-y-auto px-6 py-1"
      >
        {parserConfigured && (
          <section className="flex flex-col gap-3 rounded-xl border border-dashed bg-muted/40 p-4">
            <Field data-invalid={tooLong}>
              <FieldLabel htmlFor="agenda-paste" className="flex items-center gap-2">
                <SparklesIcon className="size-4" />
                Paste an agenda
              </FieldLabel>
              <Textarea
                id="agenda-paste"
                placeholder="Paste an email, a chat message or notes. The agenda below is filled in for you to check."
                className="min-h-24 bg-background"
                value={text}
                onChange={(e) => setText(e.target.value)}
                disabled={parsing}
                aria-invalid={tooLong}
              />
              <FieldDescription>
                {text.length.toLocaleString('en')} / {MAX_AGENDA_TEXT.toLocaleString('en')}{' '}
                characters. The text is sent to an AI model (Claude on Amazon Bedrock).
              </FieldDescription>
            </Field>
            <div className="flex flex-wrap items-center gap-3">
              {parsing ? (
                <>
                  <span
                    className="flex items-center gap-2 text-sm text-muted-foreground"
                    role="status"
                  >
                    <Loader2Icon className="size-4 animate-spin" />
                    Reading the agenda… this takes a few seconds
                  </span>
                  <Button type="button" variant="outline" size="sm" onClick={cancelParse}>
                    Cancel
                  </Button>
                </>
              ) : (
                <Button type="button" size="sm" onClick={parse} disabled={!text.trim() || tooLong}>
                  <SparklesIcon />
                  Parse
                </Button>
              )}
            </div>
            {parseError && <FieldError>{parseError}</FieldError>}
            {hint && (
              <p className="text-sm text-muted-foreground">
                Also found: {hint}. Change the meeting itself with Edit.
              </p>
            )}
          </section>
        )}

        <section className="flex flex-col gap-3">
          <h3 className="text-sm font-medium">Agenda items</h3>
          {items.map((row, index) => (
            <div
              key={row.key}
              className="grid grid-cols-[1fr_auto] gap-2 sm:grid-cols-[minmax(0,1fr)_10rem_6rem_auto]"
            >
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Topic <Suggested show={row.suggested.includes('topic')} />
                </span>
                <Input
                  aria-label={`Topic ${index + 1}`}
                  value={row.topic}
                  onChange={(e) => editItem(row.key, 'topic', e.target.value)}
                />
              </Field>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="self-end sm:order-last"
                aria-label={`Remove item ${index + 1}`}
                onClick={() => setItems((rows) => rows.filter((r) => r.key !== row.key))}
              >
                <XIcon />
              </Button>
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Owner <Suggested show={row.suggested.includes('owner')} />
                </span>
                <Input
                  aria-label={`Owner of item ${index + 1}`}
                  value={row.owner}
                  onChange={(e) => editItem(row.key, 'owner', e.target.value)}
                />
              </Field>
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Min <Suggested show={row.suggested.includes('minutes')} />
                </span>
                <Input
                  aria-label={`Minutes for item ${index + 1}`}
                  type="number"
                  min={1}
                  max={480}
                  value={row.minutes}
                  onChange={(e) => editItem(row.key, 'minutes', e.target.value)}
                />
              </Field>
            </div>
          ))}
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="self-start"
            onClick={() => setItems((rows) => [...rows, emptyItem()])}
          >
            <PlusIcon />
            Add item
          </Button>
        </section>

        <section className="flex flex-col gap-3">
          <h3 className="text-sm font-medium">Action items</h3>
          {actions.length === 0 && (
            <p className="text-sm text-muted-foreground">No action items.</p>
          )}
          {actions.map((row, index) => (
            <div
              key={row.key}
              className="grid grid-cols-[1fr_auto] gap-2 sm:grid-cols-[minmax(0,1fr)_10rem_9rem_auto]"
            >
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Task <Suggested show={row.suggested.includes('task')} />
                </span>
                <Input
                  aria-label={`Task ${index + 1}`}
                  value={row.task}
                  onChange={(e) => editAction(row.key, 'task', e.target.value)}
                />
              </Field>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="self-end sm:order-last"
                aria-label={`Remove action ${index + 1}`}
                onClick={() => setActions((rows) => rows.filter((r) => r.key !== row.key))}
              >
                <XIcon />
              </Button>
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Owner <Suggested show={row.suggested.includes('owner')} />
                </span>
                <Input
                  aria-label={`Owner of action ${index + 1}`}
                  value={row.owner}
                  onChange={(e) => editAction(row.key, 'owner', e.target.value)}
                />
              </Field>
              <Field className="gap-1">
                <span className="flex h-5 items-center gap-2 text-xs text-muted-foreground">
                  Due <Suggested show={row.suggested.includes('due')} />
                </span>
                <Input
                  aria-label={`Due date of action ${index + 1}`}
                  type="date"
                  value={row.due}
                  onChange={(e) => editAction(row.key, 'due', e.target.value)}
                />
              </Field>
            </div>
          ))}
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="self-start"
            onClick={() => setActions((rows) => [...rows, emptyAction()])}
          >
            <PlusIcon />
            Add action item
          </Button>
        </section>

        {formError && <FieldError>{formError}</FieldError>}
      </form>

      <DialogFooter>
        <Button type="button" variant="outline" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" form="agenda-form" disabled={saveAgenda.isPending || parsing}>
          {saveAgenda.isPending ? 'Saving...' : 'Save agenda'}
        </Button>
      </DialogFooter>
    </>
  )
}
