# ADR 007 — Agent Attention Routing

**Status:** Accepted
**Date:** 2026-08
**Brief:** [Agent Attention Routing](../ideas/agent-attention-routing.md)

## Context

On a large canvas with many terminals, an attention-worthy moment — a Claude Code session finishing
its turn and waiting on input, or a long command completing — is announced only transiently (a
1.6 s border/minimap flash on BEL/OSC 777; a title-bar dot that fades after 5 s on OSC 133 D). If
the user is heads-down elsewhere, the signal is gone and they hunt for the window. The signal-
capture pipeline already exists and is hardened (rate limits, sanitizers, payload caps); what is
missing is persistent state and a glanceable, clickable routing surface.

Several shapes were on the table: a dedicated herdr-style roster panel (a second overlay), a
per-agent detector-plugin registry, and OSC 133 prompt-marker tracking as the primary busy/idle
signal.

## Decision

**1. Model one concept — "this terminal wants you" — not agent identity.** A single per-terminal
runtime state `ActivityState { quiet, busy, needsAttention(exitCode:) }`, derived by a pure,
unit-testable reducer (`TerminalActivityModel`) over a typed `ActivityEvent` enum. "Agent waiting
for input," "long command finished," and "bell rang" collapse into one state machine; agents are
just event sources.

**2. Extend the minimap; do not add a second overlay.** The minimap is already a spatial map of
every terminal with click-to-pan and a throttled snapshot pipeline. Status renders as a dot per
minimap rect, plus an "N waiting" pill and a `Window ▸ Jump to Waiting Terminal` command. A roster
panel is deferred as a purely additive view over the same state model, to be built only if window
count outgrows minimap legibility.

*Design refinements (settled at ticketing):* `Theme.swift` exposes no accent token, so the states
use a **fixed semantic palette** — amber (`systemOrange`) = waiting, red (`systemRed`) =
nonzero-exit error, dim foreground-alpha = busy, absent = quiet — rather than the "theme-accent"
wording above. Minimap dots are **static with a contrast halo** (ADR 003 forbids per-frame minimap
work); the "pulse" motion channel lives only on the pill and title-bar indicator. "Jump to next"
drains the waiting set **FIFO, oldest-first**.

**3. Attention is persistent until attended.** `needsAttention` survives until the user focuses the
terminal while it is visible or sends it a keystroke. It is *suppressed* when the triggering event
arrives while the terminal is already the active, on-viewport terminal in the active app. The state
is idempotent, so rate-limited signal spam is harmless. **This persistence is the feature** — the
transient flash is retained as the interrupt; this is the queue.

**4. Detection is tiered on terminal-protocol signals, with an output-idle fallback — no plugin
registry.** BEL / OSC 777 / OSC 9 (see [ADR 008](008-osc9-notification-override.md)) are the
reliable primary signals; OSC 133 D supplies exit-code coloring as a bonus tier (never the
foundation — TUIs never emit D until exit). For agents that emit nothing, a heuristic tier fires:
a busy period is sustained output with **no user keystrokes** for ≥ 15 s, and the quiet transition
(~4 s of no output) after such a period raises attention. The no-keystrokes guard is what keeps
editors/pagers from false-firing. The extension seam for future agents is one new `ActivityEvent`
case plus one reducer clause, not a plugin protocol.

**5. Detect silence with a per-terminal trailing debounce, not a global poll.** The busy→quiet and
idle→attention transitions depend on the *absence* of output. Each terminal keeps a **cancellable
`DispatchSourceTimer`** (the `redrawWatchdog` idiom) rescheduled on every output burst; when output
stops it fires once, advances the reducer, and refreshes via the existing `onChange` path. A quiet
terminal has no pending timer — zero cost at rest. A cancellable source is required, not a bare
`asyncAfter` (which returns no handle and cannot be invalidated): the timer weak-captures the
terminal and is torn down on close, honoring the terminal-teardown memory fix (`f7fecc5`).

**6. Do not impersonate iTerm2 via `TERM_PROGRAM`.** It would coax richer native OSC out of Claude
Code, but BEL already arrives, and advertising a false emulator invites emulator-specific escape
sequences Mosaic does not implement.

## Consequences

- The load-bearing artifact is the reducer + event model, not any view. Both the minimap dots and a
  future roster panel are cheap rendering over it, and the reducer is testable without a PTY.
- Attention semantics (persist / suppress / clear) are the contested surface and will get the most
  design scrutiny — a naive reviewer asks "why not just flash?"; the persistence *is* the answer.
- The heuristic thresholds (15 s / 4 s) are guesses until dogfooded; they ship behind constants.
- Runtime-only: state dies with the session, like the PTY. No new persisted fields or settings for
  the MVP.

## Alternatives rejected

- **Dedicated roster panel now** — duplicates the minimap's job, competes for corner space, and
  adds overlay plumbing (sizing, persistence, `HoverCursorProviding`, hover-monitor interplay) for
  no benefit the pill + jump command don't already provide. Deferred, not discarded.
- **Detector-plugin registry** — speculative generality; the reliable signals are protocol-level,
  not agent-level.
- **OSC 133 as the primary signal** — requires shell integration and mis-tracks TUIs (documented in
  the OSC-133 handler comment). Retained only as an exit-code bonus tier.
- **Global 1 Hz decay poll** — an always-on timer diffing all terminals forever, against the grain
  of the app's event-driven design and the memory/CPU cleanup; replaced by the per-terminal
  debounce.

## Update (2026-08) — turn-completion is detected by screen-scraping, not a signal

**Status:** Accepted. Shipped with the feature.

Dogfooding surfaced that the assumed primary signal doesn't fire reliably. Claude Code does **not**
ring the terminal bell on turn end by default; its notification is a **~60-second-delayed idle
ping** whose channel depends on the terminal it detects (ghostty → OSC 777, iTerm2 → OSC 9), so
in a terminal it doesn't recognize it stays silent. The output-idle heuristic can't stand in for it
either: a TUI that pauses mid-turn (thinking, running a tool) would false-fire "done."

**Decision:** detect an agent's turn state by **screen-scraping the bottom of the terminal's visible
buffer** — the approach herdr uses (its "screen manifest"). Mosaic owns the SwiftTerm cell buffer
directly, so it reads it precisely rather than snapshotting a rendered pane. The load-bearing,
cross-agent signal is the **interrupt affordance**: both Claude Code and opencode render an
"esc to interrupt" hint while a turn runs, so its presence means *working* and its disappearance
(after having been working) means *turn done*. A permission/confirmation prompt ("Do you want to
proceed?", "esc to cancel") means *blocked*. This lives in the pure, unit-tested
`AgentActivityDetector` (patterns derived from herdr's published rules) and is driven from the
per-terminal silence debounce; it takes priority over the generic output-idle heuristic and falls
back to it for non-agent terminals.

This is the concrete realization of decision 4's extension seam (one classifier, driven by one new
call site) — **not** a plugin registry. It's a heuristic, not a contract: ~seconds of lag, and the
patterns track the agents' UIs, so they may need updating when those change (herdr ships them as
updatable rules; ours are constants in `AgentActivityDetector.swift`).

**Decision 6 stands, reaffirmed.** Advertising `TERM_PROGRAM=iTerm.app` (+ `LC_TERMINAL`) to coax
Claude Code into emitting OSC 9 was tried and **dropped**: the screen-scrape detector makes it
unnecessary, and impersonating a terminal we aren't is dishonest and invites emulator-specific
escape sequences we don't fully support. A `Stop` hook in `~/.claude/settings.json` (emitting
OSC 777) remains available to a user who wants instant, exact, config-based detection instead of
the heuristic.
