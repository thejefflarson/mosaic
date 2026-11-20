# ADR 010 — Agents View Roster

**Status:** Accepted
**Date:** 2026-11
**Brief:** [Agents View](../ideas/agents-view.md)

## Context

ADR 007 collapsed "this terminal wants you" into `ActivityState { quiet, busy, needsAttention }`.
That state cannot say which agent runs in a terminal, or split Working from Idle: busy → working
sets `agentWasWorking` with no reducer call, so `ActivityState` stays `.busy`. A roster of agents
needs both. `driveAgentActivity` already computes the identified agent and the post-
`SkipStateUpdateHold` `AgentActivity` on every drive tick, then discards them.

## Decision

**1. A list navigator, not minimap labels or spatial rearrangement.** The roster is a list that
jumps to a terminal. Labeling minimap rects would crowd a view ADR 003 keeps cheap, and
rearranging terminals by status would destroy the spatial layout the user built.

**2. Retain the derived values on `TerminalWindowView`.** `agentID`, `lastAgentActivity` and
`stateSince` are `private(set)` `@MainActor` properties written only from `driveAgentActivity`.
The engine stays pure and off-main (ADR 004); only its derived output is kept. When the foreground
stops being a recognized agent, both identity and activity clear, so the terminal leaves the roster
on the next tick. `stateSince` moves only when `lastAgentActivity` changes value and is a
best-effort display duration, not a contract.

**3. Snapshots hold no views.** The roster consumes value-type `AgentSnapshot`s that carry a
terminal id, never a view or PTY reference. A consumer resolves the id back to the live terminal at
the moment of use, so a stale row cannot extend a terminal's lifetime or disturb the `terminate()`
teardown chain.

**4. Refresh on any retained-value change.** Every change to `agentID` or `lastAgentActivity`
fires `onActivityChange`. Keying refresh on `ActivityState` alone would miss busy → working, and
the roster would lag a tick or never show the working ↔ idle transition. Do not simplify this to
an `ActivityState` comparison.

## Consequences

- No visible change on its own; later tickets build the roster over these properties.
- `onActivityChange` fires somewhat more often; its consumers (minimap, pill) must stay cheap and
  idempotent.

## Group mapping

`AgentRoster.group` assigns each snapshot a group by precedence: `needsAttention` or
`agentActivity == .blocked` → Needs you; else `agentActivity == .working` or `busy` → Working;
else Idle. Blocked, finished and exit-N are row sublabels, not groups. Rows order by group, then
needs-you and working by `stateSince` ascending, idle by `stateSince` descending.
