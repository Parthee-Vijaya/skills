import { describe, expect, mock, test } from 'claude-code/testing'
import type { On, RenderPropsOf } from 'claude-code'

import { formatDuration, outcomeOf, savedPathOf, targetOf, titleOf } from '../hooks/activity'

const TOOL = 'mcp__plugin_rea-panel_rea__analyze_javascript_application'
const SURFACES = ['terminal', 'desktop', 'vscode', 'mobile'] as const

const PANE_PROPS: RenderPropsOf['Pane'] = {
  title: 'REA',
  isFocused: false,
  bodyColumns: 72,
  placement: 'dock',
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

const EVIDENCE = JSON.stringify({
  evidence_id: 'ev_1',
  subject: { name: 'notes', format: 'directory', local_path: '/apps/notes' },
  provider: { id: 'rea-javascript-application', name: 'REA JavaScript application analyzer', version: '1' },
  operation: 'analyze_javascript_application',
  normalized_result: {
    statistics: { relevant_files: 3, parsed_javascript_files: 2, findings: 3, parse_failures: 0 },
  },
  confidence: 'derived',
  authority: 'shipped-artifact',
  limitations: ['JavaScript was parsed as inert text; nothing was executed.'],
})

const FAILURE = JSON.stringify({
  error: {
    code: 'target_unavailable',
    category: 'unavailable',
    message: 'No app is open.',
    retryable: false,
    remediation: { action: 'Call open_binary with its local path.' },
  },
})

/** The engine beneath the plugin's own `$` calls: the status line, the panes. */
function host(on: On) {
  const statuses: (string | undefined)[] = []
  const opened: string[] = []

  on('ui.status', ($, e) => {
    statuses.push(e.text)

    return { value: undefined }
  })
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', ($, e) => {
    opened.push(e.id)

    return { value: { isPlaced: true } }
  })

  return { statuses, opened }
}

function pane(surface: (typeof SURFACES)[number]) {
  return { plugin: 'rea-panel', surface, component: 'Pane', requestId: 'rea', props: PANE_PROPS } as const
}

test('a REA call shows running with its target, then what came back', async ($, on) => {
  const clock = mock.clock(on, { now: 10_000 })
  const { statuses, opened } = host(on)
  let release = () => {}
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  on('tool.call', { tool: TOOL }, async () => {
    await gate

    return { result: [{ type: 'text', text: EVIDENCE }], text: EVIDENCE }
  })

  const pending = $.tool.call({ tool: TOOL, input_path: '/apps/notes' })
  await clock.settle()
  expect(opened).toEqual(['rea'])

  for (const surface of SURFACES) {
    const ui = await $.ui.mount(pane(surface))
    expect((await ui.find({ type: 'Button', text: /Analyze JavaScript application/ }))?.text).toContain('0s')
    expect(await ui.find({ text: '/apps/notes' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /1 running/ })).toBeDefined()
    await ui.unmount()
  }

  await clock.advance(3_000)
  const later = await $.ui.mount(pane('desktop'))
  expect((await later.find({ type: 'Button', text: /Analyze JavaScript application/ }))?.text).toContain('3s')
  expect(statuses.at(-1)).toMatch(/^REA . Analyze JavaScript application · 3s$/)

  release()
  const ran = await pending
  expect(ran.text).toBe(EVIDENCE)
  expect(statuses.at(-1)).toBeUndefined()
  expect(await later.find({ type: 'Text', text: /running/ })).toBeUndefined()
  expect(await later.find({ type: 'Text', text: 'idle' })).toBeDefined()
  expect(await later.find({ text: 'notes (directory) · 3 findings · 3 relevant files' })).toBeDefined()
  await later.unmount()
})

test('a REA error reads as failed, with its code and message', async ($, on) => {
  mock.clock(on)
  host(on)
  on('tool.call', { tool: 'mcp__rea__procedure_pseudo_code' }, () => ({
    isError: true as const,
    result: FAILURE,
    text: FAILURE,
  }))

  const ran = await $.tool.call({ tool: 'mcp__rea__procedure_pseudo_code', procedure: 'main' })
  expect(ran.isError).toBe(true)

  for (const surface of SURFACES) {
    const ui = await $.ui.mount(pane(surface))
    expect((await ui.find({ type: 'Button', text: /Procedure pseudo code/ }))?.text).toContain('✗')
    expect(await ui.find({ text: 'procedure main' })).toBeDefined()
    expect(await ui.find({ text: 'target_unavailable: No app is open.' })).toBeDefined()
    await ui.unmount()
  }
})

test('a refused REA call reads as denied, with the reason', async ($, on) => {
  mock.clock(on)
  host(on)
  on('tool.call', { tool: TOOL }, () => ({ deny: 'Permission to use REA was denied.' }))

  const ran = await $.tool.call({ tool: TOOL, input_path: '/apps/notes' })
  expect(ran.deny).toBe('Permission to use REA was denied.')

  const ui = await $.ui.mount(pane('mobile'))
  expect((await ui.find({ type: 'Button', text: /Analyze JavaScript application/ }))?.text).toContain('⊘')
  expect(await ui.find({ type: 'Text', text: 'Permission to use REA was denied.' })).toBeDefined()
})

test('other tools stay out of the panel', async ($, on) => {
  mock.clock(on)
  const { opened } = host(on)
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))

  await $.tool.call({ tool: 'mcp__github__get_me' })
  await $.tool.call({ tool: 'mcp__plugin_other_reader__read' })

  expect(opened).toEqual([])
  const ui = await $.ui.mount(pane('terminal'))
  expect(await ui.find({ text: 'No REA calls yet.' })).toBeDefined()
})

test('a row expands to its facts and input, and Clear empties the panel', async ($, on) => {
  mock.clock(on)
  host(on)
  on('tool.call', { tool: TOOL }, () => ({ result: [{ type: 'text', text: EVIDENCE }], text: EVIDENCE }))
  await $.tool.call({ tool: TOOL, input_path: '/apps/notes' })

  for (const surface of SURFACES) {
    const ui = await $.ui.mount(pane(surface))
    const row = await ui.find({ type: 'Button', text: /Analyze JavaScript application/ })
    expect(await ui.find({ text: 'Provider: REA JavaScript application analyzer' })).toBeUndefined()

    await ui.press({ key: row?.key ?? '' })
    expect(await ui.find({ text: 'Provider: REA JavaScript application analyzer' })).toBeDefined()
    expect(await ui.find({ text: /Limitations \(1\)/ })).toBeDefined()
    expect(await ui.find({ type: 'Code', text: /"input_path": "\/apps\/notes"/ })).toBeDefined()

    await ui.press({ key: row?.key ?? '' })
    expect(await ui.find({ text: 'Provider: REA JavaScript application analyzer' })).toBeUndefined()
    await ui.unmount()
  }

  const ui = await $.ui.mount(pane('desktop'))
  await ui.press({ key: 'clear' })
  expect(await ui.find({ text: 'No REA calls yet.' })).toBeDefined()
})

test('/rea opens the panel, /rea clear empties it', async ($, on) => {
  mock.clock(on)
  const { opened } = host(on)
  on('tool.call', { tool: TOOL }, () => ({ result: [{ type: 'text', text: EVIDENCE }], text: EVIDENCE }))
  await $.tool.call({ tool: TOOL, input_path: '/apps/notes' })
  const command = {
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 160 },
  } as const

  expect((await $.command.run({ ...command, command: 'rea', args: '' })).text).toBe('REA panel opened.')
  expect(opened).toEqual(['rea', 'rea'])
  expect((await $.command.run({ ...command, command: 'rea', args: 'clear' })).text).toBe('Cleared the REA panel.')

  const ui = await $.ui.mount(pane('terminal'))
  expect(await ui.find({ text: 'No REA calls yet.' })).toBeDefined()
})

test('session start registers /rea and shows the server REA runs under', async ($, on) => {
  const clock = mock.clock(on)
  host(on)
  const registered: string[] = []
  on('command.register', ($, e) => {
    registered.push(e.name)

    return { value: { command: e.name } }
  })
  on('mcp.connect', () => ({ value: { isConnected: true, server: 'plugin:rea-panel:rea' } }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/work', surface: 'desktop', isInteractive: true })
  await clock.advance(1)

  expect(registered).toEqual(['rea'])
  const ui = await $.ui.mount(pane('desktop'))
  expect(await ui.find({ text: /server plugin:rea-panel:rea/ })).toBeDefined()
})

describe('reading REA', () => {
  test('tool names read as titles', () => {
    expect(titleOf('analyze_javascript_application')).toBe('Analyze JavaScript application')
    expect(titleOf('get_objc_classes')).toBe('Get ObjC classes')
    expect(titleOf('inspect_macho')).toBe('Inspect Mach-O')
  })

  test('targets name the subject first, then what inside it', () => {
    expect(targetOf({ document: '/bin/ls', procedure: 'main', address: '0x1000' })).toBe(
      '/bin/ls · procedure main · address 0x1000',
    )
    expect(targetOf({ limit: 20, include_script_sources: true })).toBe('limit 20')
    expect(targetOf({})).toBe('')
  })

  test('outcomes summarize evidence, errors and plain text', () => {
    expect(outcomeOf(false, EVIDENCE).summary).toBe('notes (directory) · 3 findings · 3 relevant files')
    expect(outcomeOf(true, FAILURE)).toEqual({
      status: 'failed',
      summary: 'target_unavailable: No app is open.',
      facts: ['Code: target_unavailable', 'No app is open.', 'Next: Call open_binary with its local path.'],
    })
    expect(outcomeOf(false, '\n  opened /bin/ls\nmore')).toEqual({ status: 'done', summary: 'opened /bin/ls', facts: [] })
    expect(outcomeOf(false, JSON.stringify({ procedures: [1, 2, 3], document: 'ls' })).summary).toBe(
      '3 procedures · document ls',
    )
  })

  test('a saved oversized output is found by its path', () => {
    expect(savedPathOf('Output too large (243KB). Full output saved to: /root/.claude/x/tool-results/a.txt\n')).toBe(
      '/root/.claude/x/tool-results/a.txt',
    )
    expect(savedPathOf('{"evidence_id": "ev"}')).toBeUndefined()
  })

  test('durations', () => {
    expect(formatDuration(234)).toBe('234ms')
    expect(formatDuration(1_500)).toBe('1.5s')
    expect(formatDuration(12_400)).toBe('12s')
    expect(formatDuration(61_000)).toBe('1m 1s')
  })
})
