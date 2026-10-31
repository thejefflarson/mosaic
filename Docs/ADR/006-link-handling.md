# ADR 006 — OSC 8 link handling: click-to-open, deny-list, no path containment

**Status:** Accepted
**Date:** 2026-05 (revised 2026-10: confirmation dialog removed — see Decision 1)

## Context

`InterceptingTerminalView.requestOpenLink` is called when the user clicks a
hyperlink rendered by SwiftTerm — typically an OSC 8 escape from terminal output,
sometimes a path implicitly detected by SwiftTerm's link recogniser
(`Mosaic/App/AppDelegate.swift:42`, `~/foo.log`, etc.). The handler ends up
calling `NSWorkspace.shared.open(url)` against an attacker-influenced string:
terminal output is untrusted, and the user has no way to verify a link's
destination before clicking it.

Three design questions:

1. **Which URL schemes do we hand to `NSWorkspace.open`?**
2. **Are file paths constrained to a directory subtree?**
3. **Does the user get a chance to refuse before the URL is opened?**

Each has plausible answers. Automated security scanners (e.g. Soundcheck) have
repeatedly proposed the most restrictive answer for #1 and #2 — allow-list of
schemes, contain paths to `$HOME`. This ADR records why we chose less
restrictive answers and how the threat is mitigated.

## Decisions

### 1. No confirmation dialog — the deliberate click is the gate

Clicking a link opens it directly (through `openResolvedLink`), with no
per-click Open/Cancel dialog. The gate is that the user chose to click a link
the hand cursor already marked, the same model as iTerm/Ghostty/Terminal. The
scheme deny-list (Decision 2) still refuses categorically-dangerous schemes,
and a resolved file opens in its registered viewer (Preview, an editor) rather
than executing.

This reverses the original decision, which made an `NSAlert` the "load-bearing"
defence. Two reasons:

- **A per-click modal is friction no other terminal imposes**, and it trained
  the user to click "Open" reflexively — alert fatigue erodes the very defence
  it was meant to provide.
- **That dialog never actually ran.** `requestOpenLink` is a `TerminalViewDelegate`
  requirement *with an extension default*; `LocalProcessTerminalView` conforms to
  the protocol using that default and makes itself its own delegate, so for our
  `InterceptingTerminalView` subclass the dispatched witness is the default
  (`URL(string:)` + `NSWorkspace.open`), never our method — a Swift protocol-witness
  rule, not a bug we could fix by adding `override`. So in practice every link
  opened with no dialog at all, *and* plain file paths became scheme-less URLs that
  Launch Services rejected with OSStatus -50. Restoring a working dialog would mean
  intercepting the click ourselves regardless; given the friction argument above we
  intercept and open without one.

Clicks are opened by a shared `mouseUp` monitor
(`TerminalWindowView.installSharedMonitors`) that resolves the link under the
click and calls `openResolvedLink`; it exists because SwiftTerm's `mouseUp` is
`public`, not `open`, so the delegate hook can't be overridden.

**Residual risk accepted:** an OSC 8 hyperlink can show one text while pointing
elsewhere, so a single click can open a non-denied-but-unwanted target. The
deny-list blocks the dangerous schemes; the rest is the same trust the user
extends to any terminal's clickable links.

### 2. URL schemes are filtered by a deny-list, not an allow-list

```swift
static let deniedLinkSchemes: Set<String> = [
    "javascript", "data", "vbscript",   // script injection
    "jar", "ms-its",                     // historic code-execution vectors
]
```

**Rejected alternative: allow-list.** An allow-list of "known safe" schemes
(`https`, `http`, `mailto`, `ssh`, `git`, …) silently no-ops legitimate clicks
on custom app schemes that terminal users routinely click:

- `vscode://file/path/to/file:line` — open in VS Code
- `cursor://anysphere/file/…` — open in Cursor
- `slack://team/x` — open Slack channel
- `zoom://us02web.zoom.us/…` — join a meeting
- `obsidian://open?vault=…` — open Obsidian note
- `x-callback-url://…` — inter-app integration

The cost of a silent no-op is high (users hit "click does nothing" with no
diagnostic) and the security benefit is low: the user-confirmation dialog
already gates every scheme. An allow-list would also need maintenance as new
app schemes appear in the ecosystem.

The deny-list keeps the categorically-dangerous schemes (`javascript:`,
`data:`) blocked even if the user clicks Open by mistake.

This decision has been re-flipped multiple times by automated scanners. Keep
the deny-list and the explanatory inline comment intact.

### 3. File paths are not contained to a directory subtree

After `file://` schemes and bare paths are canonicalised
(`resolvingSymlinksInPath().standardizedFileURL`), they are passed straight to
`fileExists` and `NSWorkspace.open`. No `hasPrefix($HOME)` check, no
constraint to the terminal's cwd.

**Rejected alternative: contain to cwd or `$HOME`.** Containment silently
no-ops legitimate clicks on system paths that terminal users routinely click:

- `/etc/hosts` from grep output
- `/var/log/system.log` from `tail -f`
- `/private/tmp/build-output/foo` from build logs
- `/etc/nginx/conf.d/site.conf` from config-editing workflows

The PTY-controlled-cwd threat (a malicious process emits OSC 7 to repoint cwd
at `/`, then OSC 8 with a relative link like `etc/passwd`) is real but bounded:
the link only opens if the user clicks it, it resolves to an existing file, and
opening it views the file rather than executing it.

### 4. Path canonicalisation defangs `..` segments

Even without containment, paths are run through
`URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`
before `fileExists` and before the open. A link like `sub/../hello.txt`
resolves to `<cwd>/hello.txt`; a link with `..` segments that escape upward
resolves to its final canonical form, so the open targets exactly that
canonical path and nothing is smuggled through unresolved `..`.

## Threat model summary

| Threat | Mitigation |
|--------|------------|
| OSC 8 with `javascript:` / `data:` payload | Deny-list at `resolveOpenableURL` |
| OSC 8 with unknown app scheme | Opens only on a deliberate click; deny-list blocks the dangerous schemes |
| OSC 8 with `file:///etc/secrets` after social engineering | Opens only on a deliberate click; a file opens in its viewer, not executed |
| OSC 7 cwd repoint + OSC 8 relative link | Canonicalisation + must resolve to an existing file + click-gated |
| `..`-laden link hiding the real target | `standardizedFileURL` folds segments, so the open targets the canonical path |
| Symlink in resolved path pointing elsewhere | `resolvingSymlinksInPath` + a re-check at open time (a swap between resolve and open aborts) |
| OSC 8 text that differs from its target | **Accepted residual risk** (Decision 1) — as in other terminals |

## Consequences

- Custom URL schemes registered by other apps work as expected. Adding a new
  scheme handler does not require touching Mosaic.
- Clicking system paths (`/etc/hosts`, `/var/log/…`) opens them in the default
  handler, no dialog.
- Link clicks open without interruption. The deny-list and the deliberate-click
  gesture are the gate; the accepted residual risk is in Decision 1.
- Automated security scanners will likely propose flipping #2 or #3, or
  re-adding the confirmation dialog. Reviewers should weigh those against this
  ADR (the dialog removal is deliberate, not an oversight).

## Related code

- `TerminalWindowView.installSharedMonitors` — the shared `mouseUp` monitor that
  opens a clicked link (the dispatch path that actually runs; see Decision 1)
- `InterceptingTerminalView.openResolvedLink` — resolve + rate-limit + open, no dialog
- `InterceptingTerminalView.requestOpenLink` — SwiftTerm delegate hook, not the
  dispatched witness for our subclass (Decision 1); forwards to `openResolvedLink`
- `InterceptingTerminalView.resolveOpenableURL` — scheme deny-list, path canonicalisation
- `InterceptingTerminalView.deniedLinkSchemes` — the deny-list
- `Tests/LinkResolutionTests.swift` — `customSchemesPassThrough`,
  `dangerousSchemesBlocked`, `fileURLResolves`, `absolutePathResolves`,
  `parentTraversalCanonicalises`
