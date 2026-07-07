# Attribution

The design system and the procedures under `references/` are adapted from:

**claude-design-system-prompt** by Trystan-SA
<https://github.com/Trystan-SA/claude-design-system-prompt> — MIT License.

- `references/design-system-prompt.md` is the upstream `claude/system-prompt.md` (the 20-chapter design system).
- The 14 procedure files under `references/` are the upstream `claude/skills/*.md`, bundled verbatim so this skill is self-contained.
- The upstream MIT license text is retained at `references/LICENSE`.

`SKILL.md` is original orchestration written for this repo; it adapts the upstream two chains (greenfield: discovery → aesthetic-direction → wireframe → prototype → polish; brand-aware: extract → variations → tweakable → polish) into a single adaptive command.

## Harness mapping

The upstream procedures were written for a hosted design agent and reference its tool names. Map them to your environment as you apply each one:

| Upstream reference | Use instead |
| --- | --- |
| `questions_v2` | Your structured question tool (e.g. `AskUserQuestion`) |
| `${AGENT_TOOL_NAME}` | Your subagent / Task tool, for parallel review agents |
| "verifier subagent" | A subagent that screenshots or probes the rendered output |
