---
name: ultradesign
description: Adaptive design workflow that inspects the project's current state and either audits-and-improves the existing UI or creates a new design from scratch, chaining discovery, aesthetic direction, wireframing, prototyping, token/component extraction, and a parallel polish pass (accessibility, AI-slop, hierarchy, interaction states). Governed by a strong design system that avoids generic AI aesthetics. Use when the user runs /ultradesign, or asks to design, redesign, review, polish, or improve a UI, frontend, page, deck, prototype, or component — whether or not a design already exists.
---

# Ultradesign

One command that either **improves the design you already have** or **creates one from scratch** — it detects which, then runs the matching chain. Every pass is governed by the bundled design system: content discipline, accessibility, system thinking, and no AI slop.

> The procedures under `references/` come from the upstream design agent and mention its own tool names. Map them to your harness: `questions_v2` → your structured question tool (AskUserQuestion), `${AGENT_TOOL_NAME}` and "verifier subagent" → spawn subagents. See [NOTICE.md](NOTICE.md).

## Step 1 — Load the design system

Read [references/design-system-prompt.md](references/design-system-prompt.md) and adopt it for the whole session: **you are a designer who happens to use code, not a code generator who happens to make designs.** Its non-negotiables — prefer flat color over gradients; subtly-toned whites/blacks (`#FAFAFA`/`#1A1A1A`, never `#FFF` on `#000`); a 4/8px spacing scale; 1–2 intentional fonts (not Inter/Roboto/Arial by default); WCAG contrast; semantic HTML; visible focus rings; one clear CTA. Avoid the AI-slop tells: decorative gradients, emoji sprinkles, rounded + left-border cards, hand-drawn SVG, the cream-serif-terracotta house style used without a brand reason.

## Step 2 — Detect the current design state

Scan the project to pick a branch. Look for existing UI:

- **Frontend files** — `.html`, `.css`, `.jsx`/`.tsx`, `.vue`, `.svelte`, styled-components
- **Design tokens / theme** — `tokens.*`, `theme.*`, `_variables.scss`, `tailwind.config.*`
- **Component libraries, screenshots, brand assets, a running app**

Then decide and **state the branch and why in one line** before proceeding:

- **Existing styled UI found** → **Branch A** (audit & improve)
- **Little or nothing** — empty repo, backend-only, unstyled scaffold → **Branch B** (create new)

If it's genuinely ambiguous and the user is reachable, ask which they want.

## Branch A — Improve the existing design

1. **Understand it.** [design-system-extract](references/design-system-extract.md) → pull the *real* tokens from the codebase (never invent). [component-extract](references/component-extract.md) → inventory components, variants, and states.
2. **Audit it.** Run [polish-pass](references/polish-pass.md): launch its four reviews **in parallel subagents** — [accessibility-audit](references/accessibility-audit.md), [ai-slop-check](references/ai-slop-check.md), [hierarchy-rhythm-review](references/hierarchy-rhythm-review.md), [interaction-states-pass](references/interaction-states-pass.md). Each reports every issue with severity + confidence.
3. **Fix.** Apply blockers (accessibility) and quality issues (slop, hierarchy, missing states) directly to the real files, then re-verify the high-risk areas. **Keep the existing visual vocabulary** — improve within it; don't reskin without a reason.
4. **Offer direction changes** only if wanted: [generate-variations](references/generate-variations.md) (hi-fi alternatives in one file) and [make-tweakable](references/make-tweakable.md) (live tweak panel).

## Branch B — Create a new design

1. **Discovery.** [discovery-questions](references/discovery-questions.md) — one consolidated round (audience, goal, brand/starting point, fidelity, variation count). Ask, then execute autonomously.
2. **Direction.** [frontend-aesthetic-direction](references/frontend-aesthetic-direction.md) — propose distinct visual directions, commit to one (type, color, density, mood, component style).
3. **Structure.** [wireframe](references/wireframe.md) — low-fi, greyscale, disposable options for the flow/layout before any hi-fi.
4. **Build.** The hi-fi artifact: [make-a-prototype](references/make-a-prototype.md) for clickable UI, or [make-a-deck](references/make-a-deck.md) for slides.
5. **Ship gate.** [polish-pass](references/polish-pass.md) as the final quality gate before delivery.
6. **Extract the system** (optional, if it'll be reused): [design-system-extract](references/design-system-extract.md) + [component-extract](references/component-extract.md).

## Step 3 — Wrap up

Summarize **caveats and next steps only** — verdict (ship / ship after sign-off / needs iteration), what you fixed, open decisions to sign off, anything left out of scope. Don't recap what the user just watched you do.
