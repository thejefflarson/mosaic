# ADR 008 — Override OSC 9 to Capture Desktop-Notification Payloads

**Status:** Accepted
**Date:** 2026-08
**Brief:** [Agent Attention Routing](../ideas/agent-attention-routing.md) · **Supports:** [ADR 007](007-agent-attention-routing.md)

## Context

Agent attention routing (ADR 007) wants every reliable "notify the user" signal an agent might
emit. OSC 9 is one of them: the iTerm2/Growl convention `OSC 9 ; <message> BEL` is what several
opencode notifier plugins emit, and it's a common desktop-notification escape generally.

SwiftTerm's built-in OSC 9 handling is **only** the ConEmu / Windows-Terminal *progress* protocol.
In `EscapeSequenceParser.dispatchOsc`:

```swift
// Check user-registered handlers first (allows override)
if let handler = oscHandlers[code] { handler(data); return }
...
case 9:
    if !terminal.oscProgressReport(data) { oscHandlerFallback(code, data) }
```

`oscProgressReport` → `parseProgressReport` requires the payload to begin with `4` (i.e.
`9;4;state;percent`) and, on success, calls the `progressReport(source:report:)` delegate.
**Mosaic does not implement that delegate method, so the native path is already a no-op** — parsed
and dropped. A `9;<text>` notification (no leading `4`) fails the progress parse, falls to
`oscHandlerFallback(9,…)`, finds no default handler, and is **ignored**.

Two facts matter for the decision: (a) a user-registered `oscHandlers[9]` is consulted *first* and
`return`s, so it **replaces the entire `case 9` branch**, including the progress path; (b) OSC 777
(`OSC 777 ; notify ; title ; body`) is already natively handled → `notify(...)` delegate, which
Mosaic already consumes and hardens.

## Decision

**Register an `oscHandlers[9]` handler** (via `registerOscHandler(code: 9, …)`) that parses
`9;<text>` as a desktop notification and feeds it into the attention reducer as an
`ActivityEvent.notification`, reusing the exact posture already applied to OSC 777: an 8 KB payload
cap, the `sanitizeForClipboard` + `sanitizeNotificationText` chain (strips bidi overrides, C0/C1,
zero-width), and the ≤10/min rate limit.

The handler **ignores `9;4;…` progress payloads** (early-return on a leading `4;`), preserving
today's observable behavior — Mosaic never surfaced progress bars.

## Consequences

- Registering `oscHandlers[9]` **clobbers SwiftTerm's native OSC 9;4 progress path.** This is the
  trade a reviewer or scanner will flag ("why override a built-in handler?"). The loss is
  theoretical: Mosaic does not implement `progressReport`, so nothing user-visible changes. If a
  progress→busy mapping is ever wanted, it can be added inside the same handler rather than by
  restoring the native path.
- opencode's most popular notifier plugins (which emit OSC 9) light up with no per-agent code.
- The security posture is unchanged from OSC 777: same cap, same sanitizers, same rate limit — OSC
  9 is not a new untrusted-input surface, just another route into the existing one.

## Alternatives rejected

- **Leave OSC 9 unhandled** — loses the opencode plugin ecosystem's primary signal for no gain.
- **Set `TERM_PROGRAM` to impersonate iTerm2** so agents emit richer native OSC instead — rejected
  in ADR 007: BEL already arrives, and advertising a false emulator invites unsupported escape
  sequences.
- **Fork SwiftTerm to make `case 9` dispatch both progress and a notification callback** — more
  maintenance surface than a one-line handler registration, for a progress feature Mosaic doesn't
  use.
