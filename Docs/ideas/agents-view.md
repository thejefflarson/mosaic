# Agents View — a glanceable, click-to-navigate roster of running agents

**Status:** brief (not yet ticketed)
**Date:** 2026-11-20
**Related:** ADR-007 (agent attention routing), ADR-009 (vendor herdr manifests), ADR-003 (minimap), ADR-004 (concurrency), ADR-005 (SwiftUI/AppKit hybrid)

## Idea

A live, glanceable roster of the recognized agents running across all canvas
terminals — identity + state — as a toggleable panel in the bottom-right overlay
stack. Clicking a row pans the canvas to that terminal. It is a list, and it is
also the navigator: on a large canvas agents sit at far-apart world coordinates,
often off-viewport, so a flat list answers "which agents are running, which need
me" at any zoom, and the click restores spatiality.

Inspired by tuios's "agents view / inbox," adapted to a spatial, single-machine
app. The roster transfers; tuios's inbox *verbs* do not (see Non-goals).

## Problem

On a canvas running many agents, the shipped surfaces answer adjacent questions
but not this one:

- The **attention pill** (`waitingCount` / `oldestWaitingTerminal`, ADR-007)
  answers *how many terminals need you* and jumps to the oldest. It covers **all**
  terminals including non-agent ones, but only the needs-attention state.
- The **minimap** (ADR-003) answers *where windows are* — dots, no identity.

Neither answers **which agents are running, what each is doing (working / idle /
needs-you), and let me jump to a specific one.** The identity + per-state signal
already exists in-process (ADR-009 herdr engine) but is discarded each tick.

## Recommended approach

A **flat, state-grouped list that doubles as a spatial navigator**: a SwiftUI view
hosted in an AppKit overlay (`NSHostingView`, the `ToolPaletteView` pattern,
ADR-005), docked bottom-right, grouped **Needs you / Working / Idle**, each row
click calling the existing `TerminalController.snapViewportToTerminal(_:)`
(resolving the live terminal by id, like `oldestWaitingTerminal`).

This is the smallest thing that works: the panel is pure rendering over state the
existing ~1 Hz drive path already computes — the same relationship the minimap
dots have to the reducer. No new polling, no new concurrency domain, no new timer
to tear down.

### Overlay layout (settled with the user)

Top → bottom in the bottom-right stack: **attention pill → agents list → minimap**.
The pill sits *above* the agents window. The pill stays: it is the compact,
always-visible interrupt that also covers **non-agent** terminals the agents list
deliberately omits. Collapsed, the agents panel reduces to nothing extra; the pill
is unaffected either way.

## The load-bearing change

"Fully drivable from today's signals" is true **only after a small retention fix.**
The herdr engine computes the identified `agentID` and `working/idle/blocked` on
every tick inside `driveAgentActivity` (`TerminalWindowView.swift` ~1209-1243) and
**throws them away**, collapsing into the 3-state `ActivityState {quiet, busy,
needsAttention(exitCode:)}`. `needsAttention` conflates blocked / turn-finished /
bell / nonzero-exit.

To render identity and a Working vs Idle split, retain on `TerminalWindowView`:

- `agentID: String?`
- `lastAgentActivity: AgentActivity?`
- `stateSince: Date` (for rough duration)

Set from the existing `@MainActor driveAgentActivity`. The engine stays pure /
off-main (ADR-004); only these derived values become retained `@MainActor`
properties. The reducer and `ActivityState` are untouched. This retention slice is
the bulk of the real work; the view is cheap on top of it.

## Approaches considered

- **A — flat grouped list / navigator (RECOMMENDED).** SwiftUI-in-`NSHostingView`
  overlay, grouped by state, click-to-pan. Cost: the retention slice + one overlay
  + menu/keybind + snapshot plumbing. Risk: small, mostly UI. Forecloses nothing —
  inbox verbs would be a clean additive layer over the same snapshots later.
- **B — minimap-integrated navigator** (the path ADR-007 decision 2 preferred).
  Loses: a 180×120 pt CoreGraphics minimap (ADR-003 forbids per-frame work on it)
  can't legibly carry identity + state + duration past a few terminals. It answers
  "where are windows," a different question.
- **C — spatial highlight / focus mode** (dim canvas, ring + label agent terminals,
  cycle). Loses: no persistent glanceable roster, and it **can't show off-viewport
  agents** without zoom-to-fit — the whole point on a large canvas. Its one good
  idea (click/jump restores position) is folded into A.

## Key decisions (ADR candidates flagged)

1. **List-that-navigates**, not spatial rearrangement or minimap labels. [ADR]
2. **Retain `agentID` + `lastAgentActivity` + `stateSince`** on
   `TerminalWindowView`, set from `driveAgentActivity`. [ADR — the load-bearing one]
3. **Three groups: Needs you / Working / Idle.** "Done-unseen" folds into Needs you
   — that is what `needsAttention` already means (persist-until-attended). Blocked
   vs finished vs exit-N is a best-effort per-row sublabel (from retained
   `AgentActivity == .blocked` and the `needsAttention(exitCode:)` payload), not
   separate groups. No Settled/Snoozed.
4. **SwiftUI via `NSHostingView`**, like `ToolPaletteView` (ADR-005). Model is
   `@Observable`, holds only value-type snapshots.
5. **No-retain snapshot pattern.** `TerminalController.agentSnapshots() ->
   [AgentSnapshot]` — a `Sendable` value type (`id`, `title`, `cwd`, `agentID`,
   `agentActivity`, `activityState`, `stateSince`), filtered to `agentID != nil`.
   The panel holds snapshots, never a `TerminalWindowView`; click resolves the live
   terminal by `id`; a closed terminal's row → nil → no-op. Mirrors
   `WaitingCandidate`. [ADR-004]
6. **No new timer.** Refresh on the existing `onAttentionChange`/`onActivityChange`
   fire. `terminate()`'s retention fix (f7fecc5) untouched.
7. **Amend ADR-007 decision 2**, which deferred a roster "until window count
   outgrows the minimap." An *agents* roster is a distinct question the minimap
   can't render, so it is built now — scoped to the roster, verbs still deferred.
8. **Toggle:** Window-menu "Agents" item + keybind (propose `⌥⌘A`, verify no
   collision), matching the `⌥⌘J` convention.

## Rough shape & sequence

1. **Data:** retain `agentID` + `lastAgentActivity` + `stateSince`; expose
   read-only. Unit-test the state→group mapping purely (no PTY), SnapEngine style.
2. **Plumbing:** `TerminalController.agentSnapshots()`; refresh on the existing
   change path.
3. **View:** `AgentsPanelView` (SwiftUI) + `@Observable` model in an `NSHostingView`
   overlay; row = identity + state glyph/color + duration + title/cwd-basename.
4. **Wiring:** Window-menu item + keybind; dock above the minimap, below the pill;
   click → `snapViewportToTerminal`.
5. **Optional cheap win:** a debug "Explain agent detection" menu item printing the
   focused terminal's `agentID` + `matchedRuleID` (already on `AgentEngineMatch`).

Lands as one tagged merge to `main`; runtime-only state, no migration.

## Non-goals (deliberately deferred)

Per the user: **list of agents + statuses only.** No inbox verbs (approve / snooze
/ dismiss / settle), no inline-answer, no held-approvals — the big lift, likely its
own future idea, since they need per-harness hooks or reliable prompt-menu parsing
Mosaic deliberately forgoes. Also out: per-harness report hooks / OSC 7501 /
transcript reading; OSC 9;4 progress ingestion; the wrapper-peeling detector
upgrade (orthogonal — its hard part is tuios's package-path discrimination in
`harness/proc.go`, "a directory named after an agent is never counted"); confidence
scoring (the engine match is boolean, not scored); cross-machine daemon; listing
non-agent terminals (the minimap's job).

## Identification note

tuios's identification tricks are largely already in-tree: installed
Claude/Codex/opencode resolve via `argv0` basename (commit #18, ADR-009). The only
real gap is agents launched as `npx x` / `node script.js` where argv0 is the
interpreter — closing that safely means porting tuios's package-path
discrimination, a detector expansion orthogonal to this view. Deferred.

## HANDOFF TO PLAN-SPRINT

**Theme:** Agents View — a glanceable, click-to-navigate roster of recognized
agents grouped by state. Plan against: *retain the agent identity + herdr state
Mosaic already computes-and-discards, then render it as a SwiftUI overlay docked
below the attention pill and above the minimap, whose rows navigate via the
existing `snapViewportToTerminal` routing — no new hooks, no new timers, no inbox
verbs.* Panel: product (UI/overlay + a thin data-retention slice on
`TerminalWindowView`/`TerminalController`). Expect two ADR actions: one new ADR
(list-navigator choice, retained `agentID` + `AgentActivity`, no-retain snapshot
pattern) and an amendment to ADR-007 decision 2.
