# Idea Brief — Agent Attention Routing ("who needs me?")

**Status:** Scoped (→ sprint)
**Date:** 2026-08-26
**Related ADRs:** [007 — Agent attention routing](../ADR/007-agent-attention-routing.md), [008 — OSC 9 notification override](../ADR/008-osc9-notification-override.md)

## Idea

Surface the live state of the agents/processes running in Mosaic's terminals so the user can
see at a glance **which windows need attention** — a Claude Code session that finished its turn
and is waiting on input, or a long-running command that just completed — without hunting across
a large canvas. Proposed as a second "Claude overlay" beside the minimap; **recommended instead
as an extension of the existing minimap plus a persistent per-terminal attention state and a
"jump to next waiting terminal" command.**

## Problem & context

On a large canvas, an attention-worthy event announces itself only **transiently**: today Mosaic
flashes the window border and minimap rect for 1.6 s on BEL/OSC 777 (`CanvasViewController`
`notifyAttention`) and shows a title-bar dot on OSC 133 D that **fades after 5 s**
(`TitleBarView.setStatus`). If you were heads-down in another window, the signal is gone and you
hunt. The signal-*capture* pipeline already exists and is hardened (rate limits, sanitizers,
payload caps). **What's missing is persistent state and a glanceable, clickable routing
surface.** herdr.dev validates the shape: a per-agent state list (working/done/blocked/idle) with
jump-to-the-blocked-one.

## Goals / non-goals

**Goals:** (1) a persistent per-terminal "needs attention" state that survives until the user
actually attends to it; (2) a glanceable surface showing which terminals need attention and which
are busy; (3) one-action jump to the next waiting terminal; (4) works for Claude Code today and
opencode/pi later with no overlay changes.

**Non-goals:** token/cost dashboards; agent-transcript parsing; controlling agents from the
overlay; persisting status across launches (PTYs are always fresh — status without a session is
meaningless); identifying *which* agent is running (cosmetic, deferred).

## Assumptions challenged

- **"Claude Code emits a notification on turn end."** True, with a twist: the channel depends on
  `TERM_PROGRAM`, which Mosaic does not set, so Claude Code's `auto` channel falls back to
  **terminal bell (BEL)** — which Mosaic already catches, rate-limits (≤10/min), and routes
  through `onBell`. The primary signal is already arriving; it's just rendered as a transient
  flash. So this is a *persistence* feature, not a *detection* feature.
- **"This needs a second overlay."** Shaky. The minimap already is a spatial map of every terminal
  with click-to-pan and a throttled snapshot pipeline. A second panel duplicates that, competes
  for corner space, and adds its own sizing/persistence/hover-cursor plumbing. Extending the
  minimap is strictly less machinery.
- **"Agent-agnostic needs a detector-plugin registry."** Over-engineered. The reliable signals are
  *terminal-protocol* signals (BEL, OSC 777, OSC 9, OSC 133) — not agent-specific parsing. The
  real extension seam is a typed event enum feeding one pure reducer; a plugin registry is
  speculative generality.
- **"OSC 133 is the clean busy/idle signal."** Shaky: it needs shell integration installed, and
  TUIs (claude, vim) never emit D until exit, so B/C busy-tracking pulses forever. Use 133 D as a
  bonus tier (exit-code coloring), never the foundation.
- **"Generalizing to any process complicates it."** False — it simplifies it. "Agent waiting for
  input," "long command finished," and "bell rang" are one concept: *this terminal wants you.* One
  state machine, one dot; the agent layer is just event sources.

## Approaches considered

**A. Extend the minimap: persistent status dots + attention pill + jump command (recommended).**
Add an `ActivityState` per terminal; render it as a dot on each minimap rect; keep the window's own
indicator persistent until attended; add a "N waiting" pill and a `Jump to Next Waiting Terminal`
command. Small cost — the minimap's per-window tuple grows one field; refresh rides the existing
`onChange` path. Risk: minimap rects shrink with many windows — mitigated by the pill + jump
command, which don't require reading the map. Forecloses nothing: a roster panel later is pure
additional rendering over the same state model.

**B. Dedicated roster panel (herdr-style sidebar).** A list sorted attention-first with
click-to-focus. Cost: a whole new overlay (layout/resize/persistence/`HoverCursorProviding`, plus
the hover-leak monitor interplay from `3d32ab5`), plus ordering/labeling decisions for
weakly-identified terminals. Wins only once window count outgrows minimap legibility — which the
jump command already covers. Deferred as a purely additive escalation.

**C. Per-window status only (no overlay work).** Cheapest, but fails the core case: attention-
needing windows are usually off-viewport (culled, `isHidden`) — a border you can't see routes
nothing.

**Recommended: A.** Smallest new surface, reuses the hardened signal pipeline and the throttled
minimap renderer, respects [ADR 003](../ADR/003-minimap-rendering.md) (dots are vector drawing, no
`layer.render`), and leaves B as a later additive view. The **state model, not the overlay, is the
load-bearing artifact** — build it once and both surfaces are cheap.

## Detection design

**State model** (runtime-only, `@MainActor`, owned by `TerminalWindowView`):

```
enum ActivityState { case quiet, busy, needsAttention(exitCode: Int?) }
```

Derived by a **pure reducer** (`TerminalActivityModel`, a value type — unit-testable with no PTY)
over typed events:

```
enum ActivityEvent {
  case bell                              // existing onBell (rate-limited)
  case notification                      // OSC 777 (existing) + OSC 9 (new — see ADR 008)
  case commandFinished(exitCode: Int?)   // OSC 133 D (existing parser)
  case outputActivity(at: TimeInterval)  // new: timestamp in dataReceived override
  case userKeystroke                     // keyDown / send path
  case becameActiveAndVisible            // active terminal + !isHidden + NSApp.isActive
  case quietElapsed(at: TimeInterval)    // fired by the trailing debounce (see below)
}
```

**Signal tiers.** BEL / OSC 777 / **new OSC 9** (high reliability, already-hardened pipeline);
OSC 133 D for exit-code coloring (bonus tier, not foundation); an **output-idle heuristic** as the
graceful fallback for agents that emit nothing.

**Heuristic tier (graceful degradation).** A *busy period* is sustained PTY output with **no user
keystrokes** for ≥ 15 s; the quiet transition (no output for ~4 s) after a qualifying busy period
raises `needsAttention`. The no-keystrokes guard kills the false positives — vim/less produce
output only *in response* to typing, so they never qualify; a streaming agent or a compile does.
Thresholds are constants, marked tunable; this is the one area real use will adjust.

**Attention lifecycle.** `needsAttention` is *suppressed* when the triggering event arrives while
the terminal is the active terminal, on-viewport (`!isHidden`), and the app is active — you're
watching it. It is *cleared* on `becameActiveAndVisible` or a keystroke. It is idempotent, so BEL
spam (capped upstream) is harmless.

**Detecting silence — per-terminal trailing debounce, NOT a global poll.** The `busy → quiet` and
`idle → needsAttention` transitions are defined by the *absence* of output, which the event stream
can't report on its own. Rather than a global always-on 1 Hz timer polling every terminal, each
terminal keeps a **cancellable `DispatchSourceTimer`** (the `redrawWatchdog` idiom) rescheduled on
every output burst. While a terminal is actively producing output the timer keeps getting pushed
forward; when output stops it fires once at the deadline, feeds `quietElapsed` into the reducer, and
calls the existing `onChange` → minimap refresh. **When a terminal is quiet, no timer is pending —
zero cost at rest.** A cancellable source (not a bare `asyncAfter`, which returns no handle) is what
lets the timer be invalidated on close, exactly like `redrawWatchdog`'s `deinit`, honoring the
terminal-teardown memory fix (`f7fecc5`). This is the repo's established debounce pattern (5 s save
debounce, minimap trailing render, the 1.6 s flash reset).

## Rendering & interaction

- **Minimap dots:** one dot per terminal rect, top-right (close dot owns top-left). **Fixed
  semantic palette** (`Theme.swift` has no accent token): **amber** (`systemOrange`) for
  `needsAttention`, **red** (`systemRed`) when OSC 133 D reported a nonzero exit, dim
  foreground-alpha for `busy`, absent for `quiet`. The waiting dot carries a static **contrast
  halo** (not a pulse) — ADR 003 forbids per-frame minimap work, so motion lives on the pill and
  title bar, not the map. Vector shapes in the existing `NSImage` composition — no new render path,
  ADR 003 intact. Ordering for "jump to next": **FIFO, oldest-waiting first** (drains as a queue).
- **Attention pill:** a small "● 2 waiting" capsule docked above the minimap, hidden at zero.
  Click = jump to the next attention-needing terminal (pan via existing viewport-to-terminal +
  focus, which clears its state and decrements the pill). This is what stays legible at any window
  count.
- **Menu command:** `Window ▸ Jump to Waiting Terminal` (suggest ⌥⌘J), beside the existing focus
  commands.
- **Per-window:** the title-bar/status indicator learns the attention state and stops auto-fading
  while attention is unattended; the existing 1.6 s flash and UN notification are unchanged (they
  are the *interrupt*; this feature is the *queue*).

## Agent-agnostic extensibility

opencode/pi arrive as **event sources, not code changes**: if they emit BEL/OSC 777/OSC 9 the
reducer already handles them; if they emit nothing the heuristic tier covers them. If a future
agent genuinely needs out-of-band detection (herdr reads Claude's transcript JSONL under
`~/.claude/projects/`; the PTY foreground pgid is the other option), that is a new `ActivityEvent`
case plus one reducer clause — the enum + reducer is the seam, deliberately not a plugin protocol.

## Key decisions (see ADRs)

1. Generalize to "terminal wants you," keyed on terminal-protocol signals, not agent identity.
2. Extend the minimap instead of adding a second overlay; roster panel deferred.
3. Attention is persistent until attended; clearing = focus-while-visible or keystroke;
   suppression = already watching. (The semantic heart.)
4. Override OSC 9 to capture `9;<text>` notifications, sacrificing SwiftTerm's unused native 9;4
   progress path. — [ADR 008](../ADR/008-osc9-notification-override.md)
5. Heuristic tier requires a keystroke-free busy period ≥ 15 s.
6. Detect silence with a per-terminal trailing debounce (nothing at rest), not a global poll.
7. Do **not** set `TERM_PROGRAM` to impersonate iTerm2 to coax richer OSC out of agents — BEL
   already arrives, and lying about the emulator invites escape sequences Mosaic can't support.
8. No persistence, no new settings for the MVP.

## Risks & unknowns

- **Heuristic thresholds** are guesses until dogfooded — shipped behind constants; a week of real
  use settles them. This is why the heuristic tier is in the MVP, not deferred: it's also the
  safety net if Claude Code's BEL channel ever goes quiet.
- **Hostile PTY** raising attention is bounded: idempotent state, rate-limited sources, capped
  payloads — worst case one misleading dot, cleared by a click.
- **Minimap legibility at 30+ windows:** the pill + jump command are the hedge; the roster panel is
  the pre-decided escalation.

## Rough shape & sequence (each step lands green on `main`)

1. `TerminalActivityModel` (pure reducer + thresholds) + unit tests — no UI.
2. Wire events in `TerminalWindowView`: output timestamps in `dataReceived`, keystroke/focus
   clearing, the OSC 9 handler, route existing bell/777/133-D into the reducer; add the per-terminal
   trailing debounce.
3. Minimap dots: extend the per-window tuple, draw dots, refresh via `onChange`.
4. Attention pill + jump command + menu item.
5. Title-bar indicator: persist attention state (drop the 5 s fade while unattended).

Steps 1–2 are mergeable with zero visible change.

**Deferred:** roster/list panel; agent identification and per-agent labels/icons; OSC 133 A/B busy
tracking (TUI hazard); token/cost telemetry; shell-integration auto-injection; settings UI for
thresholds.

## Handoff to plan-sprint

**Theme:** *Attention routing — persistent per-terminal activity state, minimap status dots, and
jump-to-waiting.* Extend the existing signal pipeline (bell/OSC/output) into a tested pure state
model, then render it through the minimap and a jump command — no new overlay surface. Contested
ground is the UX semantics of attention/suppression (product); infra footprint is trivial.

Key files: `Mosaic/Minimap/MinimapView.swift`, `Mosaic/Terminal/TerminalWindowView.swift` (OSC
handlers, `dataReceived`), `Mosaic/Terminal/TitleBarView.swift`,
`Mosaic/Canvas/CanvasViewController.swift` (`notifyAttention`), `Docs/ADR/003-minimap-rendering.md`.
