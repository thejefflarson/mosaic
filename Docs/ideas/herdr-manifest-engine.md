# Idea Brief — Adopt herdr's Detection Manifests (vendor + in-process engine)

**Status:** Scoped (→ sprint)
**Date:** 2026-08-26
**Related ADRs:** [007 — Agent attention routing](../ADR/007-agent-attention-routing.md), [009 — Vendor herdr manifests](../ADR/009-vendor-herdr-detection-manifests.md)

## Idea

Replace the hand-ported `AgentActivityDetector` regexes with a Swift engine that evaluates
**herdr's per-agent detection manifests** (vendored at a pinned commit), so Mosaic inherits herdr's
maintained working/idle/blocked rules for ~20 agents — Claude Code, opencode, **pi** (a stated
future target), codex, cursor, gemini, copilot, … — instead of hand-patching two.

## Problem & context

Mosaic's v0.10.0 attention routing classifies an agent's turn state from its visible screen
([ADR-007 update](../ADR/007-agent-attention-routing.md): no reliable protocol signal exists —
Claude Code's native ping is a ~60 s-delayed, terminal-sniffing OSC). The classifier is ~40 lines
of constants hand-ported from herdr's rules; it has already needed **two fixes** (`ec472dd`,
`cb427f8`) because agent TUIs drift, and it covers only Claude Code and opencode. herdr maintains 20
manifests and updates them continuously. The manifest *schema* is small and fully inspectable — a
rule is a `priority + region + a boolean gate over contains/regex/line_regex/any/all/not`, and
herdr's "structural" regions are ~150 lines of plain string slicing, not TUI-layout modeling.

## Goals / non-goals

**Goals:** correct turn/blocked/idle detection for Claude Code, opencode, pi (codex nearly free); a
mechanical re-vendor workflow so tracking herdr = running one script; the `driveAgentActivity` call
site, the `AgentActivity` enum, the reducer, and all attention UI **unchanged**.

**Non-goals:** runtime manifest updates; user-editable overrides; herdr's roster/orchestration
features; the `visible_*` evidence UI; surfacing agent identity anywhere in the UI (ADR-007 decision
1 — "this terminal wants you," not agent identity — stands).

## Assumptions challenged (the valuable part)

- **"Evaluate the TOML directly at runtime"** → shaky. The load-bearing thing is the rule *schema*,
  not the file format at runtime. Herdr's rules use TOML literal strings, inline tables, and nested
  arrays-of-tables; a hand parser is real work and a Swift TOML dependency is runtime weight for a
  build-time problem. **Convert TOML→JSON in the vendor script** (Python stdlib `tomllib`), ship
  JSON, decode with `JSONDecoder`; keep pristine TOML in-repo for provenance/diffing.
- **"A lean v1 could skip the structural regions"** → **false**, and worth stating since the idea
  suggested it. Claude's *idle* rule (`live_prompt_box`, priority 950) matches `prompt_box_body`,
  and its *blocked* rules use `after_last_horizontal_rule`. Skipping structural regions would break
  the done edge — the feature's core — for the most important agent. But those regions are trivial
  (a horizontal rule = a line whose trimmed text starts with a run of `─` ≥3; `prompt_box_body` =
  lines between the second-from-bottom rule and the next). **Implement the full engine-v3 region
  set**; the "which regions in v1" question evaporates.
- **"Evaluate all 20 manifests and take the global max"** → **false for accuracy**, not just cost.
  codex's `osc_title_idle` matches *any non-empty title* (`regex = '\S'`) — run against a plain
  shell it reports "idle" forever. **Identify the agent first**, then evaluate only that manifest.
- **"herdr's 4 states = our 4 states"** → validated (`working|idle|blocked|unknown`). herdr's
  idle-vs-done distinction lives in its tracker; ours in `TerminalActivityModel` (persist-until-
  attended). The engine needs only the 4 states.
- **"Apache-2.0 permits bundling"** → validated. Obligations: ship the license text, retain notices,
  state changes.

## Approaches considered

**A. Faithful manifest engine (engine-v3 semantics) + vendored manifests → recommended.** A pure
Swift module: `AgentManifest` model (Codable, from vendor-time JSON), gate evaluator, region
extractor, per-terminal agent identifier — behind the existing `classify` seam. ~600–900 lines of
pure, fixture-testable Swift; herdr's `manifest.rs` (1,545 lines incl. remote-update machinery we
skip) is the executable spec. Risk: ICU-vs-Rust regex divergence (mitigated by a ported fixture
corpus). Forecloses nothing — the vendor script makes tracking upstream mechanical.

**B. Vendor-and-transpile** herdr's top rules into generated Swift constants. Lower day-one cost, but
the generator must understand gates/regions/priorities to transpile them — you write the engine
anyway, as a code generator, plus you review generated-Swift diffs on every re-vendor and inevitably
"simplify" rules during transpilation — exactly the drift that caused both prior patches. Same work,
worse fidelity, noisier updates.

**C. Runtime fetch-and-cache** from herdr's repo. Executes third-party rule text (regexes over user
screens) fetched over the network without review, needs an offline/first-run fallback to bundled
files anyway, and buys freshness Mosaic doesn't need (it releases often; stale detection degrades to
the generic tier). Deferrable atop A if ever justified.

**Recommended: A.** It's the smallest thing that actually solves the drift problem, because the
drift-proofness *is* the fidelity — any local simplification of herdr's rules recreates the
maintenance burden. The engine's semantics are compact and now fully known: a bounded port.

## Key decisions (→ ADR-009)

1. **Distribution — vendor, pinned.** `Vendor/herdr/{LICENSE,NOTICE,UPSTREAM,manifests/*.toml}`;
   `UPSTREAM` records the herdr commit SHA + date (start `d79fd746`, 2026-08-25).
   `Scripts/update-herdr-manifests.sh <ref>` fetches via `gh api`, rewrites `Vendor/`, converts to
   `Mosaic/Resources/AgentManifests/*.json` with `tomllib`, validates (schema keys, region names ⊆
   the engine-v3 set, `min_engine_version ≤ 3` — mirroring herdr's `agent_detection_manifest_check.py`;
   a violating manifest is dropped with a loud warning, never shipped broken), then
   `xcodegen generate`. No runtime network; rules are code-reviewed in the PR diff.
2. **Engine version — implement v3, gate at the manifest level.** If `min_engine_version >
   ENGINE_VERSION` the whole manifest is skipped at load and that terminal falls through to ADR-007's
   generic output-idle tier. v3 is required anyway (codex declares it).
3. **Regions — all of engine v3, except `osc_progress` returns "" for now.** Port herdr's `region()`
   string-slicing exactly (including codex's `›` prompt marker and `•■✗✓` block markers). Inputs: the
   full visible screen text (extend `bottomVisibleLines` → `visibleScreenText()`, same
   `getLine`/`translateToString` path) and `currentTitle` for `osc_title`. `osc_progress`
   (ConEmu OSC 9;4) isn't captured from SwiftTerm yet; it backs one priority-250 claude idle rule
   that `prompt_box_body` (950) already covers — feed it "" (herdr's own absent-behavior) and defer
   capture. Unrecognized region → "" like herdr (but vendor-time validation means one can't ship
   unnoticed).
4. **TOML — none at runtime.** Vendor-time TOML→JSON; app uses `JSONDecoder`. Add a TOML dep only if
   we ever want user-supplied manifests.
5. **Agent selection — identify first, then evaluate that one manifest.** Via the PTY:
   `tcgetpgrp(childfd)` → foreground pgid → `proc_name`/`proc_pidpath` (libproc) → match against
   manifest `id` + `aliases` (plus a small local alias table for binary-name mismatches). Refresh on
   the same throttled ~1 Hz drive (a syscall + name lookup is negligible). Unidentified → generic
   heuristic tier (today's `unknown` path). Required for correctness (codex's catch-all title rule);
   and it makes bundling **all 20 manifests free** — only the identified agent's manifest evaluates.
6. **Engine semantics — mirror herdr exactly.** A gate matches iff every `contains` needle is a
   substring of the lowercased region text, every `regex` matches the raw text, every `line_regex`
   matches ≥1 line each, every `all` child matches, ≥1 `any` child matches (when `any` is
   non-empty), and no `not` child matches. Evaluate *all* rules (priority order ≠ file order);
   highest priority wins; **file order breaks ties, earlier rule wins** (herdr keeps the previous
   match on `>=`). Regex: `NSRegularExpression` (ICU) — a superset of Rust's `regex` (RE2-family, no
   lookaround), so every current pattern compiles; the fixture corpus guards semantic divergence.
   Compile once at load. `skip_state_update` (transient overlays like Claude's transcript viewer):
   the wrapper holds the last non-skip state per terminal and returns it — keeps the outward
   `AgentActivity` contract unchanged and fixes a latent bug (today's detector reads the transcript
   viewer as `unknown` and can false-fire the generic tier). `visible_*` flags: parsed, ignored.
7. **Attribution — Apache-2.0.** `Vendor/herdr/LICENSE` (upstream's) + `NOTICE` crediting
   `herdrdev/herdr` and stating our modification ("manifests converted TOML→JSON, otherwise
   unmodified; engine independently implemented in Swift against the published semantics"); both
   bundled into app Resources; a README acknowledgment. New **ADR-009**; ADR-007's screen-scrape
   decision is reaffirmed, and its "patterns are constants in `AgentActivityDetector.swift`" line is
   superseded.
8. **Migration & testing.** Delete `AgentActivityDetector`; the engine wrapper exposes the same shape
   (`classify(screen:title:agent:) -> AgentActivity`), so `driveAgentActivity` changes by a handful
   of lines (screen capture widened, identifier passed in). Tests: (i) **manifest-load** — every
   bundled JSON decodes, every regex compiles under ICU, regions validate (the re-vendor gate);
   (ii) **fixture corpus** — port herdr's own engine tests (`src/detect/manifest/tests.rs`, inline
   screen→state, Apache-2.0) as fixtures, plus Mosaic's existing `AgentActivityDetectorTests` cases
   retargeted (they encode the herdr-bug-#352 stale-interrupt lesson — keep as our regressions);
   (iii) reducer-integration unchanged. Tests run in CI (sandbox hangs `xcodebuild test` locally).

## Risks & unknowns

- **ICU vs Rust-regex divergence** — the realistic bug source. Invariant: for every bundled pattern
  and fixture, Swift's match decision equals herdr's. The ported fixtures enforce it at re-vendor
  time, not in the field.
- **Foreground-process identification** — API-validated (`childfd` public); the open empirical
  question is binary naming (is Claude Code's process `claude` or `node` under a given install?).
  Settle by a 10-minute dogfood check; fallback is a one-line alias-table entry or OSC-title hinting.
  Worst case for a misidentified terminal is today's behavior (generic tier).
- **Upstream schema drift** (herdr adds engine v4): the vendor script fails loudly; Mosaic keeps
  shipping the last-good vendored set until the engine is extended. No runtime exposure.
- **Trust surface**: rule text is data (regex + strings) over screen content, vendored and reviewed
  in PRs — no execution, no network, no user input crossing a boundary. ICU pathological-regex cost
  is bounded by herdr's own complexity caps (≤512 chars/matcher, ≤1024 matchers), re-checked at
  vendor time.

## Rough shape & sequence (each lands green independently; 1–3 are pure, CI-testable without a PTY)

1. **Vendor plumbing:** `Scripts/update-herdr-manifests.sh`, `Vendor/herdr/` (LICENSE/NOTICE/UPSTREAM/TOML), JSON resources, `project.yml` wiring.
2. **Model + loader:** Codable manifest types, load/validate, manifest-load test.
3. **Engine:** gate evaluator + priority resolution + region extractor (port from `manifest.rs`), fixture corpus (herdr's tests + ours).
4. **Identification:** PTY foreground-process name → manifest lookup, alias table, ~1 Hz refresh.
5. **Integration:** widen screen capture, swap the call site, `skip_state_update` hold, delete old detector; ADR-009; dogfood Claude Code + opencode + pi live.

**MVP:** steps 1–5 with the full engine-v3 region set (minus `osc_progress` capture) — that *is* the
minimum for Claude Code, and it makes opencode, pi, gemini, and codex free riders. Bundle all 20
manifests (identification-first makes breadth costless).

**Deferred:** `osc_progress` capture from SwiftTerm; runtime manifest updates (approach C); user
overrides; surfacing agent identity or `visible_*` evidence; differential CI against the herdr
binary; the roster panel (still deferred per ADR-007).

## Handoff to plan-sprint

**Theme:** *Adopt herdr's detection manifests — vendor pipeline + in-process rule engine behind the
existing classify seam.* A fidelity port with a mechanical update path: the engine mirrors
`manifest.rs` semantics exactly, the attention reducer and UI are untouched, and it ships as one
tagged merge to `main`. Panel: **infra** (build/vendor tooling + a pure-logic engine; no
product-surface changes).

Key files: `Mosaic/Terminal/AgentActivityDetector.swift` (replaced), `Mosaic/Terminal/TerminalWindowView.swift`
(screen capture + call site), `Docs/ADR/007-agent-attention-routing.md` (reaffirmed / superseded in
part by ADR-009).
