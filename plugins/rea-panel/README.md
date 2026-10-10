# rea-panel

[REA (Reverse Engineer Anything)](https://github.com/morluto/rea) inside Claude Code, with a live side panel that shows what REA is doing while it works.

Installing the plugin gives Claude Code:

- **REA's tools.** The plugin starts REA's MCP server (`npx -y rea-agents@6.3.0 mcp`, 139 tools covering native binaries, JavaScript/Electron apps, .NET, Android, firmware, websites and captures). The tools are named `mcp__plugin_rea-panel_rea__<tool>`.
- **REA's workflow skill.** `reverse-engineer-anything`, copied unchanged from the `rea-agents@6.3.0` package (MIT, see `skills/reverse-engineer-anything/LICENSE`).
- **The REA panel.** A side pane that opens when REA starts working. It lists each REA tool call, newest first:
  - a spinner and a live elapsed time while the call runs, and the same in the status line
  - what the call works on (a path, a procedure, an address)
  - what came back: the subject and REA's key counts for evidence, or the error code and message for a failure
  - a click on a row expands it to the provider, evidence confidence, counts, limitations and the call's full input

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install rea-panel --marketplace Parthee-Vijaya/skills
```

Answer `y` to add the marketplace, then pick a scope. REA needs Node.js 22.19+, 24.11+ or 26+ with npm. The first start downloads `rea-agents` through `npx`.

Deep native analysis also needs Hopper, Ghidra or IDA (see REA's [installation guide](https://github.com/morluto/rea/blob/main/docs/installation.md)). Static JavaScript, .NET and artifact inspection work without them.

## Use

Ask Claude about a target, for example *"Understand how search works in /Applications/Notes.app and show me the evidence"*. The panel opens by itself on REA's first call.

| Command      | What it does                                    |
| ------------ | ----------------------------------------------- |
| `/rea`       | Opens the panel (also after you closed it)      |
| `/rea clear` | Empties the panel's list                        |

If you close the panel, it stays closed until you run `/rea`. The panel keeps the last 50 calls of the session.

If you already registered REA yourself (`npx rea-agents setup`), the panel follows that server's calls too (`mcp__rea__*`). In that case, disable one of the two servers in `/mcp` so the tools are not listed twice.

## Update REA

Change the version in `.mcp.json`. Then copy `skills/reverse-engineer-anything/` again from the same version of the package (`npm pack rea-agents@<version>`), so the skill matches the server.

## Develop

```
claude plugin validate plugins/rea-panel
claude plugin test plugins/rea-panel
```

`hooks/register.tsx` holds the hooks: `tool.call` records each REA call, and a `ui.render` hook draws the `Pane`. `hooks/activity.ts` reads tool names, arguments and REA's results. `types/index.d.ts` is the contract for the panel's session state.
