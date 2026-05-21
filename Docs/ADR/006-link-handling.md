# ADR 006 — OSC 8 link handling: confirmation dialog, deny-list, no path containment

**Status:** Accepted
**Date:** 2026-05

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

### 1. Confirmation dialog is the primary mitigation

`requestOpenLink` shows an `NSAlert` displaying the full resolved URL with
Open/Cancel buttons before any call to `NSWorkspace.open()`. This is the
load-bearing defence against social-engineering via crafted OSC 8 payloads —
the user sees `file:///etc/passwd` (or `vscode://command/exec?arg=…`) in the
dialog and can refuse.

The full URL is shown — not truncated — so a long URL cannot hide a malicious
suffix behind an ellipsis. This is enforced by
`InterceptingTerminalView.requestOpenLink`.

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
at `/`, then OSC 8 with a relative link like `etc/passwd`) is real but is
mitigated by the same confirmation dialog as scheme handling — the user sees
the fully-resolved path before opening.

### 4. Path canonicalisation defangs `..` segments

Even without containment, paths are run through
`URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`
before `fileExists` and before being shown to the user in the confirmation
dialog. A link like `sub/../hello.txt` resolves to `<cwd>/hello.txt` and is
displayed plainly; a link with `..` segments that escape upward is shown in
its final canonical form. The user sees what they're about to open.

## Threat model summary

| Threat | Mitigation |
|--------|------------|
| OSC 8 with `javascript:` / `data:` payload | Deny-list at `resolveOpenableURL` |
| OSC 8 with unknown app scheme tricking user to confirm | User-confirmation dialog shows the full URL |
| OSC 8 with `file:///etc/secrets` after social engineering | User-confirmation dialog shows the path |
| OSC 7 cwd repoint + OSC 8 relative link | Canonicalisation + confirmation dialog |
| `..`-laden link hiding the real target | `standardizedFileURL` folds segments before display |
| Symlink in resolved path pointing elsewhere | `resolvingSymlinksInPath` follows before display |

## Consequences

- Custom URL schemes registered by other apps work as expected. Adding a new
  scheme handler does not require touching Mosaic.
- Clicking system paths (`/etc/hosts`, `/var/log/…`) opens them in the default
  handler after user confirmation.
- The user is interrupted by a dialog on every link click. This is intentional;
  terminal output cannot be trusted not to lie about what a link does.
- Automated security scanners will likely propose flipping #2 or #3 again.
  Reviewers should reject those changes citing this ADR.

## Related code

- `InterceptingTerminalView.requestOpenLink` — the confirmation dialog
- `InterceptingTerminalView.resolveOpenableURL` — scheme deny-list, path canonicalisation
- `InterceptingTerminalView.deniedLinkSchemes` — the deny-list
- `Tests/LinkResolutionTests.swift` — `customSchemesPassThrough`,
  `dangerousSchemesBlocked`, `fileURLResolves`, `absolutePathResolves`,
  `parentTraversalCanonicalises`
