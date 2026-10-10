export type ReaCallStatus = 'running' | 'done' | 'failed' | 'denied' | 'lost'

export type ReaCall = {
  /** The tool_use_id: the same at every event of the call. */
  id: string
  /** REA's own tool name, e.g. `analyze_javascript_application`. */
  tool: string
  /** The MCP server as the tool name spells it (`rea`, `plugin_rea-panel_rea`). */
  server: string
  /** One line naming what the call works on: a path, a procedure, an address. */
  target: string
  /** The call's arguments as JSON, capped. */
  input: string
  /** The subagent the call ran in; null on the main loop. */
  agentId: string | null
  status: ReaCallStatus
  startedAt: number
  endedAt: number | null
  /** One line saying what came back. */
  summary: string | null
  /** What the expanded row lists about the result. */
  facts: string[]
}

export type ReaServer =
  | { state: 'unknown' }
  | { state: 'connected'; name: string }
  | { state: 'unavailable'; message: string }

declare module 'claude-code' {
  interface PluginState {
    'rea-panel': {
      calls: ReaCall[]
      now: number
      expanded: string | null
      server: ReaServer
      isDismissed: boolean
    }
  }
}
