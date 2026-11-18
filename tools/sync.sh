#!/bin/bash
# Usage: tools/sync.sh REF
# Moves the tiny-breakout submodule to Tiny Breakout's REF (a tag, a branch of its origin, or a
# commit), fetching from its origin first, and regenerates info.yaml and LICENSE from it
# (tools/generate.sh).
# If the commit changes, the layout in layout/ no longer matches the design, so its files and
# README.txt are removed: run tools/harden.sh next, then commit. Everything it changes is
# staged. Refuses to run with uncommitted changes, which it could overwrite.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 1 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
REF=$1
cd "$ROOT"
TB=tiny-breakout
[ -z "$(git status --porcelain)" ] || { echo "sync.sh: uncommitted changes; commit or stash them first" >&2; exit 1; }
[ -e "$TB/.git" ] || { echo "sync.sh: no $TB checkout; run git submodule update --init" >&2; exit 1; }

git -C "$TB" fetch -q --tags origin
NEW_SHA=
for r in "refs/tags/$REF" "refs/remotes/origin/$REF" "$REF"; do
  if NEW_SHA=$(git -C "$TB" rev-parse -q --verify "$r^{commit}" 2>/dev/null); then break; fi
done
[ -n "$NEW_SHA" ] || { echo "sync.sh: Tiny Breakout has no tag, branch or commit $REF" >&2; exit 1; }
OLD_SHA=$(git ls-files -s "$TB" | awk '{print $2}')

git -C "$TB" checkout -q --detach "$NEW_SHA"
git add "$TB"
tools/generate.sh . info.yaml LICENSE
git add info.yaml LICENSE
if [ "$NEW_SHA" != "$OLD_SHA" ]; then
  TOP=$(sed -n 's/^ *top_module: *"\([A-Za-z0-9_]*\)".*/\1/p' info.yaml)
  for f in "layout/$TOP.gds" "layout/$TOP.lef" "layout/$TOP.pnl.v" layout/README.txt; do
    git rm -q --cached --ignore-unmatch -- "$f"
    rm -f -- "$f"
  done
  echo "sync.sh: tiny-breakout ${OLD_SHA:0:7} -> ${NEW_SHA:0:7} ($REF); the old layout is removed:"
  echo "  run tools/harden.sh, then commit"
else
  echo "sync.sh: tiny-breakout stays at ${NEW_SHA:0:7} ($REF)"
fi
