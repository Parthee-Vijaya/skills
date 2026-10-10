import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer, ToolCallResult } from 'claude-code'

import type { ReaCall, ReaCallStatus, ReaServer } from '../types'
import {
  REA_TOOL,
  argumentsOf,
  bodyOf,
  deniedOutcome,
  formatDuration,
  formatElapsed,
  inputOf,
  outcomeOf,
  parseJson,
  parseToolName,
  savedPathOf,
  spinnerFrame,
  statusLine,
  targetOf,
  titleOf,
} from './activity'

const PANE = 'rea'
const TITLE = 'REA'
const KEEP = 50

const calls = atom({ plugin: 'rea-panel', key: 'calls' } as const, [])
const now = atom({ plugin: 'rea-panel', key: 'now' } as const, 0)
const expanded = atom({ plugin: 'rea-panel', key: 'expanded' } as const, null)
const server = atom({ plugin: 'rea-panel', key: 'server' } as const, { state: 'unknown' })
const isDismissed = atom({ plugin: 'rea-panel', key: 'isDismissed' } as const, false)

const GLYPH: Record<Exclude<ReaCallStatus, 'running'>, string> = {
  done: '✓',
  failed: '✗',
  denied: '⊘',
  lost: '?',
}

const COLOR: Record<ReaCallStatus, string> = {
  running: 'warning',
  done: 'success',
  failed: 'error',
  denied: 'error',
  lost: 'inactive',
}

/** REA calls this copy of the module is waiting on; the ticker runs while any are. */
let active = 0
let ticker: Timer | undefined

function startTicking($: EngineInterface): void {
  ticker ??= $.clock.every(1_000, () => {
    void tick($)
  })
}

async function tick($: EngineInterface): Promise<void> {
  if (active === 0) {
    ticker?.cancel()
    ticker = undefined
    $.ui.status(undefined)

    return
  }
  const time = await $.clock.now()
  await update($, now, () => time)
  const running = (await read($, calls)).filter(call => call.status === 'running')

  if (active > 0) {
    $.ui.status(statusLine(running, time))
  }
}

/** Opens the pane when REA starts working, unless the person closed it. */
async function reveal($: EngineInterface): Promise<void> {
  if (await read($, isDismissed)) {
    return
  }
  const panes = await $.ui.panes()

  if (!panes.some(pane => pane.id === PANE)) {
    await $.ui.open({ id: PANE, title: TITLE })
  }
}

/** The result's full text, read back from disk when Claude Code saved it there. */
async function fullBody($: EngineInterface, ran: ToolCallResult): Promise<string> {
  const body = bodyOf(ran.result, ran.text)
  const saved = parseJson(body) === undefined ? savedPathOf(body) : undefined

  if (saved === undefined) {
    return body
  }
  try {
    return await $.fs.read(saved)
  } catch {
    return body
  }
}

type Started = { tool: string; id: string; agentId: string | undefined; args: Record<string, unknown> }

/** Records a call as running and shows it; answers its id once recorded, undefined if it was not. */
async function begin($: EngineInterface, started: Started): Promise<string | undefined> {
  try {
    const startedAt = await $.clock.now()
    const { server: via, tool } = parseToolName(started.tool)
    const call: ReaCall = {
      id: started.id,
      tool,
      server: via,
      target: targetOf(started.args),
      input: inputOf(started.args),
      agentId: started.agentId ?? null,
      status: 'running',
      startedAt,
      endedAt: null,
      summary: null,
      facts: [],
    }

    await update($, calls, list => [call, ...list.filter(one => one.id !== call.id)].slice(0, KEEP))
    await update($, now, () => startedAt)
    $.ui.status(statusLine([call], startedAt))
    startTicking($)
    await reveal($).catch(() => undefined)

    return call.id
  } catch {
    return undefined
  }
}

/** Records what came back; `ran` is undefined when the call ended without a result. */
async function settle($: EngineInterface, id: string, ran: ToolCallResult | undefined): Promise<void> {
  try {
    const endedAt = await $.clock.now()
    const outcome =
      ran === undefined
        ? { status: 'failed' as const, summary: 'Ended without a result (interrupted).', facts: [] }
        : ran.deny === undefined
          ? outcomeOf(ran.isError === true, await fullBody($, ran))
          : deniedOutcome(ran.deny)

    await update($, calls, list =>
      list.map(call => (call.id === id ? { ...call, ...outcome, endedAt } : call)),
    )
  } catch {
    // The panel is a view: what it failed to record never touches the call.
  }
}

async function connect($: EngineInterface): Promise<void> {
  let link: ReaServer

  try {
    const joined = await $.mcp.connect('rea')
    link = joined.isConnected
      ? { state: 'connected', name: joined.server }
      : { state: 'unavailable', message: joined.message }
  } catch (error) {
    link = { state: 'unavailable', message: error instanceof Error ? error.message : String(error) }
  }
  await update($, server, () => link)
}

async function clear($: EngineInterface): Promise<void> {
  await update($, calls, list => list.filter(call => call.status === 'running'))
  await update($, expanded, () => null)
}

function serverLine(link: ReaServer): string {
  switch (link.state) {
    case 'connected':
      return `server ${link.name}`
    case 'unavailable':
      return `server unavailable: ${link.message}`
    case 'unknown':
      return 'server starting'
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'rea',
      description: 'Show the REA activity panel (/rea clear empties it)',
      argumentHint: '[clear]',
    })
    // A call still marked running was cut off by a reload of this module.
    await update($, calls, list =>
      list.map(call =>
        call.status === 'running'
          ? { ...call, status: 'lost', summary: 'The panel reloaded while this ran; its result is in the transcript.' }
          : call,
      ),
    )
    $.clock.after(1, () => {
      void connect($)
    })

    return next(e)
  })

  // Watches REA's calls and never changes one: whatever fails here, the call runs.
  on('tool.call', { tool: REA_TOOL }, async ($, e, next) => {
    active += 1
    const id = await begin($, {
      tool: e.tool,
      id: e.tool_use_id,
      agentId: e.agentId,
      args: argumentsOf(e as Readonly<Record<string, unknown>>),
    })
    let ran: ToolCallResult | undefined

    try {
      ran = await next(e)

      return ran
    } finally {
      active -= 1
      if (active === 0) {
        $.ui.status(undefined)
      }
      if (id !== undefined) {
        await settle($, id, ran)
      }
    }
  }).catch(($, e, next) => next(e))

  on('ui.close', { id: PANE }, async ($, e, next) => {
    if (e.origin.kind === 'person') {
      await update($, isDismissed, () => true)
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'rea' }, async ($, e) => {
    if (e.args.trim() === 'clear') {
      await clear($)

      return { text: 'Cleared the REA panel.' }
    }
    await update($, isDismissed, () => false)
    const opened = await $.ui.open({ id: PANE, title: TITLE })

    return { text: opened.isPlaced ? 'REA panel opened.' : `REA panel waits for room: ${opened.reason}` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Code, Text } = $.ui.resolve(e)
    const list = await read($, calls)
    const time = await read($, now)
    const open = await read($, expanded)
    const link = await read($, server)
    const running = list.filter(call => call.status === 'running').length
    const failed = list.filter(call => call.status === 'failed').length
    const tally =
      list.length === 0 ? '' : ` · ${list.length} ${list.length === 1 ? 'call' : 'calls'}${failed > 0 ? `, ${failed} failed` : ''}`

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" justifyContent="space-between">
          <Text bold>REA activity</Text>
          <Text color={running > 0 ? 'warning' : 'subtle'}>
            {running > 0 ? `${spinnerFrame(time)} ${running} running` : 'idle'}
          </Text>
        </Box>
        <Text dimColor wrap="truncate-end">
          {serverLine(link)}
          {tally}
        </Text>
        {list.length === 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text dimColor>No REA calls yet.</Text>
            <Text dimColor>
              Ask Claude to inspect a binary, an app or a website: each REA tool call shows up here while it
              runs, with what it works on and what came back.
            </Text>
          </Box>
        )}
        {list.map(call => {
          const isOpen = open === call.id
          const glyph = call.status === 'running' ? spinnerFrame(time) : GLYPH[call.status]
          const took =
            call.status === 'running'
              ? formatElapsed(time - call.startedAt)
              : call.endedAt === null
                ? ''
                : formatDuration(call.endedAt - call.startedAt)

          return (
            <Box flexDirection="column" marginTop={1}>
              <Button
                key={`call-${call.id}`}
                plain
                onPress={() => update($, expanded, current => (current === call.id ? null : call.id))}
              >
                <Text color={COLOR[call.status]}>{glyph}</Text> {titleOf(call.tool)}{' '}
                <Text dimColor>
                  {took}
                  {call.agentId === null ? '' : ' · subagent'}
                </Text>
              </Button>
              <Box flexDirection="column" paddingLeft={2}>
                {call.target !== '' && (
                  <Text dimColor wrap="truncate-middle">
                    {call.target}
                  </Text>
                )}
                {call.summary !== null && (
                  <Text
                    color={call.status === 'done' ? 'text' : COLOR[call.status]}
                    wrap={isOpen ? 'wrap' : 'truncate-end'}
                  >
                    {call.summary}
                  </Text>
                )}
                {isOpen && (
                  <Box flexDirection="column">
                    {call.facts.map(fact => (
                      <Text wrap="wrap">{fact}</Text>
                    ))}
                    <Text dimColor wrap="truncate-end">
                      {`${call.tool} via ${call.server}`}
                      {call.agentId === null ? '' : ` in subagent ${call.agentId}`}
                    </Text>
                    <Code language="json" source={call.input} />
                  </Box>
                )}
              </Box>
            </Box>
          )
        })}
        {list.length > 0 && (
          <Box marginTop={1}>
            <Button key="clear" label="Clear" onPress={() => clear($)} />
          </Box>
        )}
      </Box>
    )
  })
}
