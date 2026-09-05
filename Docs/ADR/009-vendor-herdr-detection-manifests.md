# ADR 009 — Vendor herdr's Detection Manifests; Evaluate In-Process

**Status:** Accepted
**Date:** 2026-08
**Brief:** [Adopt herdr's Detection Manifests](../ideas/herdr-manifest-engine.md)
**Supersedes (in part):** [ADR 007](007-agent-attention-routing.md) — its "patterns are constants in `AgentActivityDetector.swift`" note.

## Context

Attention routing (ADR 007) detects an agent's turn state by screen-scraping the terminal's visible
buffer, because agents emit no reliable machine signal on turn completion. That logic shipped as a
small hand-ported `AgentActivityDetector` — a few regexes for Claude Code and opencode — and has
already needed two fixes (`ec472dd`, `cb427f8`) as agent TUIs drifted. herdr (`herdrdev/herdr`,
Apache-2.0) maintains detection **manifests for ~20 agents** (including `pi`, a stated future
target) and updates them continuously. Their manifest schema is small and their engine
(`src/detect/manifest.rs`) is a compact, inspectable spec: a rule is a `priority + region + a
boolean gate over contains/regex/line_regex/any/all/not`.

## Decision

**Adopt herdr's manifests wholesale and evaluate them in a faithful in-process Swift engine, behind
the existing `classify` seam.** The `AgentActivity` enum, the `TerminalActivityModel` reducer, and
all attention UI are unchanged.

1. **Vendor, pinned — do not fetch at runtime.** `Vendor/herdr/{LICENSE,NOTICE,UPSTREAM,manifests/*.toml}`
   in-repo; `UPSTREAM` records the herdr commit + date. `Scripts/update-herdr-manifests.sh <ref>`
   fetches, rewrites `Vendor/`, converts TOML→JSON into `Mosaic/Resources/AgentManifests/`, validates
   (mirroring herdr's `agent_detection_manifest_check.py`), and regenerates the project. Rules are
   code-reviewed in the PR diff; there is no runtime network, and no third-party rule text is fetched
   and executed against user screens unreviewed (which is why runtime-fetch was rejected).

2. **TOML→JSON at vendor time; no runtime TOML dependency.** The rule *schema* is load-bearing, not
   the file format. `tomllib` (Python stdlib) converts at vendor time; the app decodes JSON. Pristine
   TOML stays in `Vendor/` for provenance and diffing.

3. **Implement engine v3; gate at the manifest level.** A manifest whose `min_engine_version` exceeds
   what we implement is skipped entirely at load, and that terminal falls back to ADR-007's generic
   output-idle tier. v3 is required regardless (codex declares it). Implement the full v3 region set
   — including the "structural" regions `prompt_box_body` / `after_last_horizontal_rule` /
   `last_non_empty_above_prompt_box`, which are trivial string-slicing (a horizontal rule is a line
   whose trimmed text starts with ≥3 `─`), not TUI-layout modeling. A lean "skip structural regions"
   v1 was rejected: Claude Code's idle and blocked rules depend on them, so skipping would break the
   done edge for the most important agent. `osc_progress` returns "" for now (not captured from
   SwiftTerm; the one low-priority claude rule it backs is already covered by `prompt_box_body`).

4. **Identify the agent first, then evaluate only that manifest.** Via the PTY foreground process
   (`tcgetpgrp(childfd)` → pgid → the group leader's **`argv0` basename**, `sysctl(KERN_PROCARGS2)`,
   falling back to `proc_name`) matched against manifest `id` + `aliases` (plus a small local alias
   table for binary-name mismatches). `argv0` — not `proc_name` — because agents ship as versioned
   self-contained binaries: Claude Code execs `~/.local/share/claude/versions/<ver>`, so `proc_name`
   returns the version string, never `claude`, while `argv0`'s basename is the stable launcher name
   `claude`. This is the same signal herdr's own identifier prefers. This is required for
   **correctness**, not just cost: codex's `osc_title_idle` matches any non-empty title, so
   cross-evaluating all manifests would report a plain shell as "idle" forever. It also makes
   bundling all ~20 manifests **free** — only the identified agent's manifest ever runs.

5. **Mirror herdr's evaluation semantics exactly.** Gate match: every `contains` a substring
   (lowercased region), every `regex`/`line_regex` matches, every `all` child matches, ≥1 `any` child
   matches when present, no `not` child matches. Highest `priority` wins; file order breaks ties
   (earlier rule wins — herdr keeps the previous match on `>=`). `NSRegularExpression` (ICU) covers
   Rust's `regex` feature set (RE2, no lookaround) but is **not escape-for-escape compatible**: Rust
   spells a code-point escape `\u{HHHH}`, which ICU rejects at compile time (it wants `\x{HHHH}`) —
   `hermes.json` uses exactly this (`^⚠[\u{fe0e}\u{fe0f}]?…`). The loader normalizes `\u{…}`→`\x{…}`
   at compile time (`CompiledRegex.normalizedForICU`); any *other* escape ICU can't parse throws at
   load and is caught by the manifest-load compile-all test, so a future divergence fails CI rather
   than silently dropping a manifest in the field. `skip_state_update`
   rules (transient overlays) hold the last non-skip state per terminal — this also fixes a latent
   bug where the current detector reads Claude's transcript viewer as `unknown`.

## Consequences

- Detection drift becomes herdr's problem, pulled in by one script; new agents (pi, codex, gemini,
  cursor, copilot, …) come for free. The vendored rules are auditable in each update PR.
- The realistic bug source is ICU-vs-Rust-regex divergence. It is contained by porting herdr's own
  fixture corpus (inline screen→state tests, Apache-2.0) as our regressions, checked at re-vendor
  time — not in the field.
- The empirical unknown (Claude Code's foreground name) is **settled**: its `argv0` basename is
  `claude` (verified against live processes), matching the manifest `id` directly — the earlier
  `node` guess was wrong both ways (real Claude is `claude`; real `node` is an unrelated CLI). The
  remaining gap, deferred: a runtime-wrapped agent (a `node`/`bun` script whose `argv0` is the
  interpreter) needs herdr's full job-scan / argv-unwrap, which we did not port — such a terminal
  falls to the generic tier.
- Apache-2.0 obligations are met by shipping herdr's LICENSE + a NOTICE stating our changes; the
  engine is an independent Swift implementation of the published semantics.

## Alternatives rejected

- **Vendor-and-transpile** herdr's rules into generated Swift — you write the engine anyway (as a
  code generator), review generated-code diffs on every update, and inevitably simplify rules during
  transpilation, recreating the exact drift this ADR removes.
- **Runtime fetch-and-cache** — executes unreviewed third-party rule text over the network against
  user screens, needs a bundled offline fallback regardless, and buys freshness a frequently-released
  desktop app doesn't need. Deferrable atop the vendored engine if ever justified.
- **Keep hand-porting** the constants — the status quo; two fixes in one release already showed it
  doesn't scale to agent drift or agent count.
