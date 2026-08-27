#!/usr/bin/env bash
# update-herdr-manifests.sh — re-vendor herdr's Apache-2.0 agent-detection manifests.
#
# Usage:
#   ./Scripts/update-herdr-manifests.sh [<git-ref>]
#
# <git-ref> is any ref herdrdev/herdr's API accepts (branch, tag, short or full
# SHA). Defaults to d79fd746, the pin recorded in Docs/ADR/009. It is resolved
# to a full 40-char commit SHA before anything is fetched, and that SHA (plus
# the commit date) is recorded in Vendor/herdr/UPSTREAM.
#
# What it does (see Docs/ADR/009-vendor-herdr-detection-manifests.md):
#   1. Fetches src/detect/manifests/*.toml + the root LICENSE at <ref> via `gh api`.
#      No runtime network access — this all happens at vendor time, in this script.
#   2. Vendors them verbatim into Vendor/herdr/{LICENSE,manifests/*.toml} for
#      provenance/diffing, plus an authored NOTICE and UPSTREAM.
#   3. Validates each manifest with Scripts/lib/validate_manifests.py (mirrors
#      herdr's own agent_detection_manifest_check.py) and converts valid ones
#      TOML->JSON into Mosaic/Resources/AgentManifests/*.json. A manifest that
#      fails validation (or declares min_engine_version > 3) is dropped with a
#      loud warning and never written — the last-good JSON already on disk (if
#      any) is left in place, so that agent falls back to the generic tier
#      rather than shipping broken.
#   4. Regenerates the Xcode project and prints an added/changed/dropped/unchanged
#      summary.
#
# Re-running with the same <git-ref> against a clean tree is a true no-op.

set -euo pipefail

REPO="herdrdev/herdr"
MANIFEST_PATH="src/detect/manifests"
DEFAULT_REF="d79fd746"
REF="${1:-$DEFAULT_REF}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor/herdr"
VENDOR_MANIFESTS_DIR="$VENDOR_DIR/manifests"
RESOURCES_DIR="$REPO_ROOT/Mosaic/Resources/AgentManifests"
VALIDATE_PY="$REPO_ROOT/Scripts/lib/validate_manifests.py"

# ── Prerequisites ─────────────────────────────────────────────────────────────

for cmd in gh python3 xcodegen git; do
    command -v "$cmd" &>/dev/null || {
        echo "error: $cmd not found"
        exit 1
    }
done

if ! gh auth status &>/dev/null; then
    echo "error: gh is not authenticated — run 'gh auth login' and retry"
    echo "  (see: gh auth status)"
    exit 1
fi

# ── Resolve <git-ref> to a concrete 40-char SHA ──────────────────────────────

echo "→ resolving $REF"
COMMIT_INFO=$(gh api "repos/$REPO/commits/$REF" --jq '.sha + " " + .commit.author.date') || {
    echo "error: could not resolve ref '$REF' via gh api — check 'gh auth status'"
    exit 1
}
RESOLVED_SHA="${COMMIT_INFO%% *}"
RESOLVED_DATE="${COMMIT_INFO#* }"
if [[ ! "$RESOLVED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: resolved SHA is not a 40-char hex string: $RESOLVED_SHA"
    exit 1
fi
RESOLVED_DATE_ISO="${RESOLVED_DATE%%T*}"
echo "  -> $RESOLVED_SHA ($RESOLVED_DATE_ISO)"

# ── Fetch manifest list + LICENSE ────────────────────────────────────────────

echo "→ fetching manifest list"
MANIFEST_NAMES=$(gh api "repos/$REPO/contents/$MANIFEST_PATH?ref=$RESOLVED_SHA" --jq '.[].name' \
    | grep '\.toml$' | grep -v '^index\.toml$' || true)
if [[ -z "$MANIFEST_NAMES" ]]; then
    echo "error: no manifests found under $MANIFEST_PATH at $RESOLVED_SHA"
    exit 1
fi

mkdir -p "$VENDOR_MANIFESTS_DIR" "$RESOURCES_DIR"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/herdr-vendor.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ fetching LICENSE"
gh api "repos/$REPO/contents/LICENSE?ref=$RESOLVED_SHA" --jq .content | base64 -d > "$TMP_DIR/LICENSE"

# ── Fetch, vendor, validate, convert ─────────────────────────────────────────

ADDED=0
CHANGED=0
DROPPED=0
UNCHANGED=0

while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    # $name comes from the GitHub API's directory listing of a third-party
    # repo and is used below to build filesystem paths — reject anything but
    # a plain "<id>.toml" filename before it touches the filesystem, so a
    # compromised or adversarial upstream listing can't path-traverse out of
    # Vendor/herdr/manifests or Mosaic/Resources/AgentManifests.
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+\.toml$ ]]; then
        echo "warning: $name skipped — not a plain <id>.toml filename"
        DROPPED=$((DROPPED + 1))
        continue
    fi
    echo "→ $name"

    fetched_toml="$TMP_DIR/$name"
    gh api "repos/$REPO/contents/$MANIFEST_PATH/$name?ref=$RESOLVED_SHA" --jq .content \
        | base64 -d > "$fetched_toml"

    # Vendor the pristine TOML verbatim, regardless of validity — Vendor/ is
    # provenance/diffing of what upstream actually published, warts and all.
    dest_toml="$VENDOR_MANIFESTS_DIR/$name"
    if [[ ! -f "$dest_toml" ]] || ! cmp -s "$fetched_toml" "$dest_toml"; then
        cp "$fetched_toml" "$dest_toml"
    fi

    # The agent id is assumed to equal the TOML filename stem, which holds for
    # every manifest herdr ships; validate_manifests.py would still reject a
    # manifest whose declared id disagreed, just not under this filename.
    agent_id="${name%.toml}"
    out_json="$RESOURCES_DIR/$agent_id.json"
    tmp_json="$TMP_DIR/$agent_id.json"

    if WARNING=$(python3 "$VALIDATE_PY" "$fetched_toml" "$tmp_json" 2>&1); then
        if [[ ! -f "$out_json" ]]; then
            cp "$tmp_json" "$out_json"
            ADDED=$((ADDED + 1))
        elif ! cmp -s "$tmp_json" "$out_json"; then
            cp "$tmp_json" "$out_json"
            CHANGED=$((CHANGED + 1))
        else
            UNCHANGED=$((UNCHANGED + 1))
        fi
    else
        echo "$WARNING"
        if [[ -f "$out_json" ]]; then
            echo "warning: $agent_id dropped — keeping last-good $out_json (agent falls back to the generic tier if this persists)"
        else
            echo "warning: $agent_id dropped — no prior Resources file; that agent is unavailable until fixed upstream"
        fi
        DROPPED=$((DROPPED + 1))
    fi
done <<< "$MANIFEST_NAMES"

cp "$TMP_DIR/LICENSE" "$VENDOR_DIR/LICENSE"

cat > "$VENDOR_DIR/UPSTREAM" <<EOF
ref: $REF
sha: $RESOLVED_SHA
date: $RESOLVED_DATE_ISO
EOF

# NOTICE is static (an Apache-2.0 attribution notice, not upstream data) but
# rewritten every run so this script is the single source of truth for it.
cat > "$VENDOR_DIR/NOTICE" <<'EOF'
Mosaic vendors agent-detection manifests from herdrdev/herdr
(https://github.com/herdrdev/herdr), licensed under the Apache License,
Version 2.0. See LICENSE in this directory for the full license text.

Changes from the upstream source: the manifests under manifests/*.toml are
converted verbatim from TOML to JSON at vendor time
(Scripts/update-herdr-manifests.sh) — no rule content is altered. The engine
that evaluates these manifests is an independent Swift implementation written
against herdr's published manifest-engine semantics; no herdr source code is
vendored or reused.
EOF

echo "→ regenerating Xcode project"
(cd "$REPO_ROOT" && xcodegen generate --quiet)

echo "summary: added=$ADDED changed=$CHANGED dropped=$DROPPED unchanged=$UNCHANGED"
