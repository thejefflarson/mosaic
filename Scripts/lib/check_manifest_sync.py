#!/usr/bin/env python3
"""CI gate: assert the committed herdr manifests are valid and in sync.

Checks two things about the *committed* tree (no network, no fetch):
  1. Every Vendor/herdr/manifests/*.toml passes validate_manifests.py's schema/cap
     checks — hard-fail on any violation.
  2. Every schema-valid TOML's re-derived JSON is byte-identical to its committed
     Mosaic/Resources/AgentManifests/*.json — hard-fail on a hand-edited JSON or a
     forgotten re-vendor (Scripts/update-herdr-manifests.sh).

Reuses validate_manifests.py's own load/validate/convert functions directly (not a
reimplementation) so the comparison matches exactly what the vendor script produces.

A manifest whose min_engine_version exceeds what this engine implements
(EngineTooNewError) is deliberately NOT a failure here: the vendor script vendors that
TOML verbatim but drops its JSON with a warning (Docs/ADR/009-vendor-herdr-detection-
manifests.md decision #3), and a routine future re-vendor that lands one of those
shouldn't be blocked by this gate. See the "Drop-vs-fail split" note in
Scripts/update-herdr-manifests.sh.

Usage:
    check_manifest_sync.py <manifests-dir> <resources-dir>

Exits 0 on a clean sync. Exits 1 and prints one or more `error:` lines otherwise.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_manifests import (  # noqa: E402
    EngineTooNewError,
    ValidationError,
    load_toml,
    to_json_bytes,
    validate_manifest,
)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_manifest_sync.py <manifests-dir> <resources-dir>", file=sys.stderr)
        return 2
    manifests_dir, resources_dir = Path(argv[0]), Path(argv[1])

    errors: list[str] = []
    seen_ids: set[str] = set()

    for toml_path in sorted(manifests_dir.glob("*.toml")):
        agent_id = toml_path.stem
        seen_ids.add(agent_id)
        json_path = resources_dir / f"{agent_id}.json"

        try:
            manifest = load_toml(toml_path)
            validate_manifest(manifest)
        except EngineTooNewError as exc:
            # A manifest above our implemented engine is dropped by the vendor
            # script (Docs/ADR/009 decision #3), so a *committed* JSON for it is
            # itself a desync: it means someone hand-edited or forgot to drop the
            # JSON, and AgentManifest.swift's loader gates on min_engine_version at
            # load, not on JSON presence — a v3-declaring JSON would still load.
            # Hard-fail here rather than skipping the sync check entirely; only the
            # absence of a JSON is the "expected" state for a too-new manifest.
            if json_path.exists():
                errors.append(
                    f"{json_path} exists but {toml_path} exceeds the implemented engine "
                    f"({exc}) — the vendor script drops the JSON for a too-new manifest; "
                    "run Scripts/update-herdr-manifests.sh and commit the removal"
                )
            else:
                print(f"note: {toml_path} dropped (expected) — {exc}", file=sys.stderr)
            continue
        except ValidationError as exc:
            errors.append(f"{toml_path}: {exc}")
            continue

        if not json_path.exists():
            errors.append(
                f"{json_path} missing — run Scripts/update-herdr-manifests.sh and commit the result"
            )
        elif json_path.read_bytes() != to_json_bytes(manifest):
            errors.append(
                f"{json_path} out of sync with {toml_path} — "
                "run Scripts/update-herdr-manifests.sh and commit the result"
            )

    for json_path in sorted(resources_dir.glob("*.json")):
        if json_path.stem not in seen_ids:
            errors.append(f"{json_path} has no backing {manifests_dir / (json_path.stem + '.toml')}")

    if errors:
        for err in errors:
            print(f"error: {err}", file=sys.stderr)
        return 1

    print(f"ok: {len(seen_ids)} manifests validated and in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
