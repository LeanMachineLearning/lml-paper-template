#!/usr/bin/env bash
# Build the library and fail on any warning except `declaration uses 'sorry'`, which phase 1 and an
# unfinished phase 2 produce on purpose (so `lake build --wfail` would fail on them). Prints how
# many declarations still use sorry.
#
# Usage: scripts/check-build.sh [library]        (default: the package's main library)
#
# Like scripts/build.sh, it acts on the Git checkout of the current directory: CI runs
# lml-paper-template's copy from the paper project's root.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"
lib=${1:-$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -n 1)}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ! bash "$here/build.sh" "$lib" 2>&1 | tee "$log"; then
  echo "the build of $lib failed" >&2
  exit 1
fi

sorries=$(grep -c "declaration uses .sorry." "$log" || true)
others=$(grep "warning:" "$log" | grep -vc "declaration uses .sorry." || true)
echo "$lib: $sorries declarations use sorry, $others other warnings"
if [ "$others" != 0 ]; then
  echo "fix the warnings above: only 'declaration uses sorry' is allowed" >&2
  exit 1
fi
