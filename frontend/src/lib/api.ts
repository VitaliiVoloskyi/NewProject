import { format } from 'date-fns'

import { forgetSession, getIdToken } from '@/lib/auth'

export type Participant = {
  id: string
  name: string
  email: string
}

export type Meeting = {
  id: string
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participants: Participant[]
  agenda: Agenda | null
  created_at: string
}

export type AgendaItem = { topic: string; owner: string | null; minutes: number | null }
export type ActionItem = { task: string; owner: string | null; due: string | null }
export type Agenda = { items: AgendaItem[]; action_items: ActionItem[] }

/** What the agenda parser returned: a suggestion the user checks before saving. */
export type ParsedAgenda = Agenda & {
  title: string | null
  starts_at: string | null
  duration_minutes: number | null
  language: string
}

/** The parser's answer as it came, stored next to the saved agenda (its quality signal). */
export type AiSuggestion = { agenda: ParsedAgenda; model: string; prompt_version: string }

export type AgendaSave = Agenda & { ai_suggestion: AiSuggestion | null }

export type MeetingCreate = {
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participant_ids: string[]
}

export type ParticipantCreate = {
  name: string
  email: string
}

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

// Backend origin, set at build time for AWS (the Lambda function URL). Empty locally,
// where the Vite dev server or nginx proxies /api to the backend.
const API_URL = (import.meta.env.VITE_API_URL ?? '').replace(/\/+$/, '')

type ValidationIssue = { loc?: (string | number)[]; msg: string }

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return (detail as ValidationIssue[])
      .map((issue) => {
        const field = issue.loc?.filter((part) => part !== 'body').join('.')
        const msg = issue.msg.replace(/^Value error, /, '')
        return field ? `${field}: ${msg}` : msg
      })
      .join('; ')
  }
  return fallback
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = await getIdToken()
  const response = await fetch(`${API_URL}/api${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
      ...init?.headers,
    },
  })

  // The session is gone (revoked, or the refresh token expired): forget it, which shows the
  // signed-out page (see RequireAuth in App.tsx).
  if (response.status === 401) await forgetSession().catch(() => undefined)

  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }

  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const api = {
  listMeetings: () => request<Meeting[]>('/meetings'),
  createMeeting: (data: MeetingCreate) =>
    request<Meeting>('/meetings', { method: 'POST', body: JSON.stringify(data) }),
  updateMeeting: ({ id, ...data }: MeetingCreate & { id: string }) =>
    request<Meeting>(`/meetings/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  saveAgenda: ({ id, ...data }: AgendaSave & { id: string }) =>
    request<Meeting>(`/meetings/${id}/agenda`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteMeeting: (id: string) => request<void>(`/meetings/${id}`, { method: 'DELETE' }),
  listParticipants: () => request<Participant[]>('/participants'),
  createParticipant: (data: ParticipantCreate) =>
    request<Participant>('/participants', { method: 'POST', body: JSON.stringify(data) }),
}

// --- Paste an agenda: the parser Lambda (infra/ai.yml), a separate function URL set at build
// time. It only suggests; saving goes through the API above. Empty: the feature is hidden.
const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? '').replace(/\/+$/, '')
export const parserConfigured = Boolean(PARSER_URL)
export const MAX_AGENDA_TEXT = 10_000

const PARSER_ERRORS: Record<number, string> = {
  401: 'Your session has expired; sign in again.',
  413: `The text is too long: paste at most ${MAX_AGENDA_TEXT.toLocaleString('en')} characters.`,
  422: 'No agenda found in this text. Try other text, or type the agenda below.',
  429: 'The AI service is busy right now. Try again in a minute, or type the agenda below.',
}

/** The agenda suggested for `text`. Throws ApiError with a message for people; an AbortError
 * when `signal` is aborted (the user pressed Cancel). */
export async function parseAgenda(text: string, signal?: AbortSignal): Promise<AiSuggestion> {
  const token = await getIdToken()
  // The user's "Monday" is in the user's time zone, not the function's (UTC).
  const today = format(new Date(), 'yyyy-MM-dd')
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      body: JSON.stringify({ text, today, tz }),
      signal,
    })
  } catch (error) {
    if (signal?.aborted) throw error
    throw new ApiError(0, 'Could not reach the AI service. Check your connection and try again.')
  }
  if (!response.ok) {
    throw new ApiError(
      response.status,
      PARSER_ERRORS[response.status] ??
        'The AI service is not available right now. Type the agenda below instead.',
    )
  }
  return response.json() as Promise<AiSuggestion>
}
