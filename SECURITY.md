# Security Policy

## Supported Versions

Only the latest release receives security fixes. Older versions are not patched.

| Version | Supported |
|---------|-----------|
| Latest  | ✓         |
| Older   | ✗         |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's private [Report a Vulnerability](https://github.com/thejefflarson/mosaic/security/advisories/new) feature. Include:

- A description of the vulnerability and its potential impact
- Steps to reproduce
- Any relevant logs, screenshots, or proof-of-concept code

You can expect an acknowledgment within a few days and a fix or mitigation plan once the issue is confirmed.

## Threat Model

Mosaic is a local macOS desktop application with no network-facing components. The primary attack surfaces are:

**Terminal escape sequence injection** — Malicious output written to a PTY (e.g., from a remote shell session) could attempt to exploit the terminal emulator. Mosaic strips title-setting and other potentially dangerous OSC/DCS sequences before forwarding to SwiftTerm (`TerminalWindowView.stripEscapeSequences`). If you find a sequence that bypasses this filter, please report it.

**OSC 8 link clicks** — Clickable links from terminal output (OSC 8 hyperlinks, implicitly detected paths) reach `NSWorkspace.open()` via a user-facing confirmation dialog that shows the full resolved URL. Custom URL schemes (e.g. `vscode://`, `slack://`) are passed through; a small deny-list blocks categorically dangerous schemes (`javascript:`, `data:`, `vbscript:`, `jar`, `ms-its`). File paths are canonicalised but not contained to a directory subtree. See `Docs/ADR/006-link-handling.md` for the full rationale.

**Auto-update (Sparkle)** — Updates are delivered over HTTPS and verified with an Ed25519 signature before installation. The signing key is stored offline. If you find a way to bypass signature verification or intercept the update channel, please report it.

**Workspace file parsing** — On launch, Mosaic loads `~/Library/Application Support/Mosaic/workspace.json`. Maliciously crafted JSON could potentially cause unexpected behavior. Mosaic uses Swift's `Codable` with no `eval` or dynamic dispatch on persisted data.

**AppleScript interface** — Mosaic exposes `spawn`, `navigate`, `count`, and `cwd` commands via the Scripting Bridge. These run with the same privileges as the app itself (no elevated permissions). If you find a way to use the AppleScript interface to escape the app sandbox or access unintended resources, please report it.

## Out of Scope

- Vulnerabilities requiring physical access to the machine
- Social engineering attacks
- Issues in third-party dependencies (report those upstream: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [Sparkle](https://github.com/sparkle-project/Sparkle))
