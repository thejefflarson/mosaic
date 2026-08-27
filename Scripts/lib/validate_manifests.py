#!/usr/bin/env python3
"""Validate an herdr agent-detection manifest and (optionally) convert it to JSON.

Mirrors herdr's own `scripts/agent_detection_manifest_check.py` at the pinned
vendor ref (see Vendor/herdr/UPSTREAM) — the same closed schema key-sets, the
same state/region allow-sets, and the same complexity caps — so a manifest that
would fail herdr's own CI also fails here.

Used by Scripts/update-herdr-manifests.sh as the vendor-time validation gate: a
manifest that fails validation is reported with a `warning:` line and its
Resources JSON is left untouched (ship last-good; that agent falls back to the
generic detection tier — see Docs/ADR/009-vendor-herdr-detection-manifests.md).

Usage:
    validate_manifests.py <toml-path> [<json-out-path>]

Exits 0 and (if <json-out-path> given) writes the converted JSON on success.
Exits 1 and prints a `warning:` line to stderr, writing nothing, on failure.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path

# Engine version Mosaic implements (Docs/ADR/009). A manifest whose
# min_engine_version exceeds this is rejected here, at vendor time — never at
# runtime — and that agent falls back to the generic detection tier.
ENGINE_VERSION = 3

MANIFEST_KEYS = {"id", "version", "min_engine_version", "updated_at", "aliases", "rules"}
RULE_KEYS = {
    "id",
    "state",
    "priority",
    "region",
    "visible_idle",
    "visible_blocker",
    "visible_working",
    "skip_state_update",
    "all",
    "any",
    "not",
    "contains",
    "regex",
    "line_regex",
}
GATE_KEYS = {"all", "any", "not", "contains", "regex", "line_regex"}
STATES = {"idle", "working", "blocked", "unknown"}

# The engine-v3 region allow-set, copied from herdr's checker at the pinned ref.
REGION_RE = re.compile(
    r"^(whole_recent|whole_recent_without_current_prompt_marker|after_last_prompt_marker|"
    r"before_current_prompt_marker|current_prompt_block_marker|after_current_prompt_block_marker|"
    r"prompt_box_body|above_prompt_box|last_non_empty_above_prompt_box|after_last_horizontal_rule|"
    r"osc_title|osc_progress|"
    r"bottom_lines\([1-9][0-9]*\)|bottom_non_empty_lines\([1-9][0-9]*\)|"
    r"top_non_empty_lines\([1-9][0-9]*\))$"
)
REGION_COUNT_RE = re.compile(r"\(([1-9][0-9]*)\)$")
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")

MAX_TOP_REGION_LINE_COUNT = 65_535
MAX_RULES_PER_MANIFEST = 128
MAX_GATE_DEPTH = 8
MAX_TOTAL_GATES = 512
MAX_MATCHERS_PER_GATE = 32
MAX_TOTAL_MATCHERS = 1024
MAX_MATCHER_CHARS = 512


class ValidationError(Exception):
    """Raised with the first schema or complexity violation found."""


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as fh:
            value = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise ValidationError(f"invalid TOML: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError("manifest root must be a table")
    return value


def validate_manifest(manifest: dict) -> None:
    unknown = sorted(set(manifest) - MANIFEST_KEYS)
    if unknown:
        raise ValidationError(f"unknown manifest field(s): {', '.join(unknown)}")

    agent_id = manifest.get("id")
    if not isinstance(agent_id, str) or not agent_id.strip():
        raise ValidationError("id must be a non-empty string")

    _version_tuple(manifest.get("version"))

    min_engine = manifest.get("min_engine_version")
    if not isinstance(min_engine, int) or isinstance(min_engine, bool):
        raise ValidationError("min_engine_version must be an integer")
    if min_engine > ENGINE_VERSION:
        raise ValidationError(
            f"min_engine_version {min_engine} exceeds implemented engine {ENGINE_VERSION}"
        )

    aliases = manifest.get("aliases", [])
    if not isinstance(aliases, list) or not all(isinstance(item, str) for item in aliases):
        raise ValidationError("aliases must be an array of strings")

    rules = manifest.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValidationError("rules must be a non-empty array")
    if len(rules) > MAX_RULES_PER_MANIFEST:
        raise ValidationError(f"manifest exceeds max rule count {MAX_RULES_PER_MANIFEST}")

    complexity = {"gates": 0, "matchers": 0}
    for rule in rules:
        _validate_rule(rule, min_engine, complexity)


def _version_tuple(value: object) -> tuple[int, ...]:
    if not isinstance(value, str) or not VERSION_RE.fullmatch(value):
        raise ValidationError("version must be dotted numeric")
    return tuple(int(part) for part in value.split("."))


def _validate_rule(rule: object, min_engine: int, complexity: dict[str, int]) -> None:
    if not isinstance(rule, dict):
        raise ValidationError("rule must be a table")
    unknown = sorted(set(rule) - RULE_KEYS)
    if unknown:
        raise ValidationError(f"rule has unknown field(s): {', '.join(unknown)}")

    rule_id = rule.get("id")
    if not isinstance(rule_id, str) or not rule_id.strip():
        raise ValidationError("rule id must be a non-empty string")

    state = rule.get("state")
    if state is not None and state not in STATES:
        raise ValidationError(f"rule {rule_id} has invalid state {state!r}")

    region = rule.get("region", "whole_recent")
    if not isinstance(region, str) or not REGION_RE.fullmatch(region):
        raise ValidationError(f"rule {rule_id} has invalid region {region!r}")

    count_match = REGION_COUNT_RE.search(region)
    if (
        region.startswith("top_non_empty_lines(")
        and count_match
        and int(count_match.group(1)) > MAX_TOP_REGION_LINE_COUNT
    ):
        raise ValidationError(f"rule {rule_id} has invalid region {region!r}")
    if region.startswith("top_non_empty_lines(") and min_engine < 3:
        raise ValidationError(f"rule {rule_id} region {region!r} requires min_engine_version 3")

    if rule.get("skip_state_update"):
        if state != "unknown":
            raise ValidationError(f"rule {rule_id} skip_state_update requires state unknown")
        if rule.get("visible_idle") or rule.get("visible_blocker") or rule.get("visible_working"):
            raise ValidationError(f"rule {rule_id} skip_state_update cannot set visible flags")

    _validate_gate(
        f"rule {rule_id}", rule, require_positive=True, depth=0, complexity=complexity, is_rule=True
    )


def _validate_gate(
    label: str,
    gate: dict,
    require_positive: bool,
    depth: int,
    complexity: dict[str, int],
    is_rule: bool,
) -> None:
    if depth > MAX_GATE_DEPTH:
        raise ValidationError(f"{label} exceeds max gate depth {MAX_GATE_DEPTH}")
    complexity["gates"] += 1
    if complexity["gates"] > MAX_TOTAL_GATES:
        raise ValidationError(f"manifest exceeds max gate count {MAX_TOTAL_GATES}")

    # A top-level rule carries id/state/priority/region/visible_* alongside the
    # gate fields; a nested gate (any/all/not entry) carries only gate fields.
    # Selected from an explicit flag, not a label sniff: nested gates inherit
    # the parent's "rule <id>" label prefix, so sniffing validated them against
    # the RULE_KEYS superset and let rule-only keys smuggle through.
    allowed_keys = RULE_KEYS if is_rule else GATE_KEYS
    unknown = sorted(set(gate) - allowed_keys)
    if unknown:
        raise ValidationError(f"{label} has unknown gate field(s): {', '.join(unknown)}")

    matcher_count = 0
    for key in ("contains", "regex", "line_regex"):
        values = gate.get(key, [])
        if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
            raise ValidationError(f"{label} {key} must be an array of strings")
        matcher_count += len(values)
        for value in values:
            if len(value) > MAX_MATCHER_CHARS:
                raise ValidationError(f"{label} matcher exceeds max length {MAX_MATCHER_CHARS}")
    if matcher_count > MAX_MATCHERS_PER_GATE:
        raise ValidationError(f"{label} exceeds max direct matcher count {MAX_MATCHERS_PER_GATE}")
    complexity["matchers"] += matcher_count
    if complexity["matchers"] > MAX_TOTAL_MATCHERS:
        raise ValidationError(f"manifest exceeds max matcher count {MAX_TOTAL_MATCHERS}")

    nested_any = gate.get("any", [])
    nested_all = gate.get("all", [])
    nested_not = gate.get("not", [])
    for key, values in (("any", nested_any), ("all", nested_all), ("not", nested_not)):
        if not isinstance(values, list):
            raise ValidationError(f"{label} {key} must be an array")

    if require_positive and not _has_positive_matcher(gate):
        raise ValidationError(f"{label} must contain a positive matcher")

    for idx, nested in enumerate(nested_any):
        _validate_nested_gate(f"{label} any[{idx}]", nested, True, depth + 1, complexity)
    for idx, nested in enumerate(nested_all):
        _validate_nested_gate(f"{label} all[{idx}]", nested, True, depth + 1, complexity)
    for idx, nested in enumerate(nested_not):
        _validate_nested_gate(f"{label} not[{idx}]", nested, False, depth + 1, complexity)


def _validate_nested_gate(
    label: str,
    gate: object,
    require_positive: bool,
    depth: int,
    complexity: dict[str, int],
) -> None:
    if not isinstance(gate, dict):
        raise ValidationError(f"{label} must be a table")
    if not require_positive and not _has_any_matcher(gate):
        raise ValidationError(f"{label} must contain a matcher")
    _validate_gate(label, gate, require_positive, depth, complexity, is_rule=False)


def _has_positive_matcher(gate: dict) -> bool:
    return bool(
        gate.get("contains")
        or gate.get("regex")
        or gate.get("line_regex")
        or gate.get("any")
        or gate.get("all")
    )


def _has_any_matcher(gate: dict) -> bool:
    return bool(_has_positive_matcher(gate) or gate.get("not"))


def to_json_bytes(manifest: dict) -> bytes:
    """Byte-stable JSON: sorted keys, non-ASCII preserved, one trailing newline.

    Re-running the vendor script against the same upstream ref must be a true
    no-op — this is what makes that possible.
    """
    return (json.dumps(manifest, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("toml_path", type=Path)
    parser.add_argument("json_out", type=Path, nargs="?")
    args = parser.parse_args(argv)

    try:
        manifest = load_toml(args.toml_path)
        validate_manifest(manifest)
    except ValidationError as exc:
        print(f"warning: {args.toml_path}: {exc}", file=sys.stderr)
        return 1

    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_bytes(to_json_bytes(manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
