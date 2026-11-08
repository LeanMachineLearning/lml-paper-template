#!/usr/bin/env bash
# Check that every package LMLExplore pins (Mathlib, Tau Ceti, LML and their dependencies) is at
# LMLExplore's revision here too. A project that requires LMLExplore must build against exactly
# those versions: Tau Ceti's prebuilt files, and LMLExplore itself, are only valid with them.
#
# Usage: scripts/check-pins.sh        (after `lake update` has fetched .lake/packages/LMLExplore)
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"

ours=lake-manifest.json
theirs=.lake/packages/LMLExplore/lake-manifest.json
[ -f "$ours" ] || { echo "no lake-manifest.json: run lake update first" >&2; exit 1; }
[ -f "$theirs" ] || { echo "no $theirs: run lake update first" >&2; exit 1; }

status=0
while IFS=$'\t' read -r name rev; do
  here=$(jq -r --arg n "$name" '.packages[] | select(.name == $n) | .rev' "$ours")
  if [ -z "$here" ]; then
    echo "$name: missing here, $rev in LMLExplore"
    status=1
  elif [ "$here" != "$rev" ]; then
    echo "$name: $here here, $rev in LMLExplore"
    status=1
  fi
done < <(jq -r '.packages[] | [.name, .rev] | @tsv' "$theirs")

if [ "$status" = 0 ]; then
  echo "every package LMLExplore pins is at LMLExplore's revision"
else
  echo "fix: require only LMLExplore in lakefile.toml, then run lake update LMLExplore" >&2
fi
exit "$status"
