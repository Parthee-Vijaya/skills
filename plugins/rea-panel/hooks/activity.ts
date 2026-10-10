import type { ReaCall, ReaCallStatus } from '../types'

/** A REA tool as Claude Code names it: a configured `rea` server's, or a plugin's. */
export const REA_TOOL = /^mcp__(?:plugin_[\w-]+_)?rea__/

/** Keys of `tool.call`'s input that belong to the envelope, not to the tool. */
const ENVELOPE = new Set(['tool', 'tool_use_id', 'agentId', 'requestMeta'])

/** Arguments naming what a call works on, drawn bare. */
const SUBJECT_KEYS = [
  'input_path',
  'path',
  'document',
  'application',
  'url',
  'capture_path',
  'manifest_path',
  'snapshot_path',
  'left',
  'right',
  'before',
  'after',
]

/** Arguments naming what inside the subject a call looks at, drawn with their name. */
const DETAIL_KEYS = [
  'procedure',
  'address',
  'name',
  'class_name',
  'method_name',
  'query',
  'pattern',
  'target_id',
  'goal',
  'start',
]

/** Counters worth reading first in a result's statistics. */
const LEADING_COUNTS = [
  'findings',
  'functions',
  'procedures',
  'classes',
  'methods',
  'modules',
  'nodes',
  'edges',
  'symbols',
  'strings',
  'sections',
  'segments',
  'relevant_files',
]

const WORDS: Record<string, string> = {
  api: 'API',
  dylib: 'dylib',
  evm: 'EVM',
  javascript: 'JavaScript',
  macho: 'Mach-O',
  objc: 'ObjC',
  ui: 'UI',
  webmcp: 'WebMCP',
}

const INPUT_LIMIT = 2_000
const LINE_LIMIT = 240
const SPINNER = ['◐', '◓', '◑', '◒']

export type Outcome = {
  status: Exclude<ReaCallStatus, 'running' | 'lost'>
  summary: string
  facts: string[]
}

type Json = Record<string, unknown>

function isRecord(value: unknown): value is Json {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringOf(value: unknown): string | undefined {
  if (typeof value === 'string' && value !== '') {
    return value
  }
  if (typeof value === 'number') {
    return String(value)
  }

  return undefined
}

function words(key: string): string {
  return key.replace(/_/g, ' ')
}

function clip(text: string, limit = LINE_LIMIT): string {
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text
}

function firstLine(text: string): string {
  const line = text.split('\n').find(one => one.trim() !== '')

  return clip(line?.trim() ?? '')
}

export function parseToolName(name: string): { server: string; tool: string } {
  const match = /^mcp__(.+?)__(.+)$/.exec(name)

  return { server: match?.[1] ?? '', tool: match?.[2] ?? name }
}

/** `analyze_javascript_application` → `Analyze JavaScript application`. */
export function titleOf(tool: string): string {
  const [first = tool, ...rest] = tool
    .split('_')
    .filter(word => word !== '')
    .map(word => WORDS[word] ?? word)

  return [first.charAt(0).toUpperCase() + first.slice(1), ...rest].join(' ')
}

export function argumentsOf(e: Readonly<Json>): Json {
  return Object.fromEntries(Object.entries(e).filter(([key]) => !ENVELOPE.has(key)))
}

/** One line naming what a call works on, from its arguments. */
export function targetOf(args: Readonly<Json>): string {
  const subjects = SUBJECT_KEYS.flatMap(key => stringOf(args[key]) ?? [])
  const details = DETAIL_KEYS.flatMap(key => {
    const value = stringOf(args[key])

    return value === undefined ? [] : [`${words(key)} ${value}`]
  })
  const parts = [...subjects, ...details]

  if (parts.length === 0) {
    for (const [key, value] of Object.entries(args)) {
      const shown = stringOf(value)
      if (shown !== undefined) {
        parts.push(`${words(key)} ${shown}`)
      }
    }
  }

  return clip(parts.slice(0, 3).join(' · '))
}

export function inputOf(args: Readonly<Json>): string {
  const json = JSON.stringify(args, null, 2)

  return json.length > INPUT_LIMIT ? `${json.slice(0, INPUT_LIMIT)}\n…` : json
}

/** The result's full text: the tool's own record when it carries text, else what the model read. */
export function bodyOf(result: unknown, text: string | undefined): string {
  if (typeof result === 'string' && result !== '') {
    return result
  }
  if (Array.isArray(result)) {
    const texts = result.flatMap(block =>
      isRecord(block) && block.type === 'text' && typeof block.text === 'string' ? [block.text] : [],
    )
    if (texts.length > 0) {
      return texts.join('\n')
    }
  }
  if (isRecord(result) && ('evidence_id' in result || 'error' in result)) {
    return JSON.stringify(result)
  }

  return text ?? ''
}

export function parseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/** Where Claude Code saved an output too large to inline, when its text says so. */
export function savedPathOf(text: string): string | undefined {
  return /saved to:?\s+(\/\S+)/i.exec(text)?.[1]?.replace(/[)\].,;:]+$/, '')
}

export function deniedOutcome(reason: string): Outcome {
  return { status: 'denied', summary: firstLine(reason) || 'Refused.', facts: [clip(reason, 1_000)] }
}

/** What came back from a REA call, read for the panel. */
export function outcomeOf(isError: boolean, body: string): Outcome {
  const parsed = parseJson(body)

  if (isRecord(parsed) && isRecord(parsed.error)) {
    return errorOutcome(parsed.error)
  }
  if (isError) {
    return { status: 'failed', summary: firstLine(body) || 'REA reported an error.', facts: [] }
  }
  if (isRecord(parsed) && (isRecord(parsed.subject) || isRecord(parsed.normalized_result))) {
    return evidenceOutcome(parsed)
  }
  if (parsed !== undefined && typeof parsed === 'object' && parsed !== null) {
    return shapeOutcome(parsed)
  }

  return { status: 'done', summary: firstLine(body) || 'Done.', facts: [] }
}

function errorOutcome(error: Json): Outcome {
  const code = stringOf(error.code)
  const message = stringOf(error.message)
  const action = isRecord(error.remediation) ? stringOf(error.remediation.action) : undefined
  const facts: string[] = []

  if (code !== undefined) {
    facts.push(`Code: ${code}${error.retryable === true ? ' (retryable)' : ''}`)
  }
  if (message !== undefined) {
    facts.push(clip(message, 1_000))
  }
  if (action !== undefined && action !== message) {
    facts.push(`Next: ${clip(action, 1_000)}`)
  }

  return {
    status: 'failed',
    summary: clip([code, message].filter(Boolean).join(': ') || 'REA reported an error.'),
    facts,
  }
}

function countsOf(statistics: unknown): string[] {
  if (!isRecord(statistics)) {
    return []
  }
  const rank = (key: string) => {
    const at = LEADING_COUNTS.indexOf(key)

    return at === -1 ? LEADING_COUNTS.length : at
  }

  return Object.entries(statistics)
    .filter((entry): entry is [string, number] => typeof entry[1] === 'number' && entry[1] !== 0)
    .sort(([a], [b]) => rank(a) - rank(b))
    .map(([key, value]) => `${value} ${words(key)}`)
}

function evidenceOutcome(evidence: Json): Outcome {
  const subject = isRecord(evidence.subject) ? evidence.subject : {}
  const normalized = isRecord(evidence.normalized_result) ? evidence.normalized_result : {}
  const provider = isRecord(evidence.provider) ? stringOf(evidence.provider.name) : undefined
  const counts = countsOf(normalized.statistics)
  const limits = Array.isArray(evidence.limitations)
    ? evidence.limitations
    : Array.isArray(normalized.limitations)
      ? normalized.limitations
      : []
  const name = stringOf(subject.name)
  const format = stringOf(subject.format)
  const named = name === undefined ? undefined : format === undefined ? name : `${name} (${format})`
  const trust = [stringOf(evidence.confidence), stringOf(evidence.authority)].filter(Boolean)
  const facts = [
    provider === undefined ? undefined : `Provider: ${provider}`,
    trust.length === 0 ? undefined : `Evidence: ${trust.join(', ')}`,
    counts.length === 0 ? undefined : `Counts: ${counts.slice(0, 6).join(' · ')}`,
    limits.length === 0
      ? undefined
      : `Limitations (${limits.length}): ${clip(String(limits[0]), 400)}`,
  ].filter((fact): fact is string => fact !== undefined)

  return {
    status: 'done',
    summary: clip([named, ...counts.slice(0, 2)].filter(Boolean).join(' · ') || 'Evidence returned.'),
    facts,
  }
}

function shapeOutcome(value: object): Outcome {
  if (Array.isArray(value)) {
    return { status: 'done', summary: `${value.length} items`, facts: [] }
  }
  const parts = Object.entries(value).flatMap(([key, field]) => {
    if (Array.isArray(field)) {
      return [`${field.length} ${words(key)}`]
    }
    const shown = stringOf(field)

    return shown !== undefined && shown.length <= 80 ? [`${words(key)} ${shown}`] : []
  })

  return {
    status: 'done',
    summary: clip(parts.slice(0, 3).join(' · ') || `${Object.keys(value).length} fields`),
    facts: parts.slice(0, 8),
  }
}

export function formatDuration(ms: number): string {
  if (ms < 1_000) {
    return `${Math.max(0, Math.round(ms))}ms`
  }
  if (ms < 60_000) {
    return `${(ms / 1_000).toFixed(ms < 10_000 ? 1 : 0)}s`
  }

  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1_000)}s`
}

/** Whole seconds a running call has run, as the 1s tick shows them. */
export function formatElapsed(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1_000)

  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

export function spinnerFrame(now: number): string {
  return SPINNER[Math.floor(now / 1_000) % SPINNER.length] ?? SPINNER[0]!
}

/** The status line while REA works: the oldest running call, and how many more. */
export function statusLine(running: readonly ReaCall[], now: number): string | undefined {
  const [first] = running
  if (first === undefined) {
    return undefined
  }
  const more = running.length > 1 ? ` (+${running.length - 1} more)` : ''

  return `REA ${spinnerFrame(now)} ${titleOf(first.tool)}${more} · ${formatElapsed(now - first.startedAt)}`
}
