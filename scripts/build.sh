#!/usr/bin/env bash
# Build the paper project, reusing Mathlib's and Tau Ceti's prebuilt files instead of compiling them.
#
# Usage: scripts/build.sh [lake build arguments]      e.g. scripts/build.sh PaperLib --wfail
#
# Run it anywhere inside the repository; CI runs the copy of lml-paper-template from the project's
# root, so the script acts on the Git checkout of the current directory, not on its own folder.
# Adapted from LMLExplore's scripts/build.sh. Mathlib's files come from `lake exe cache get`. Tau
# Ceti publishes its build outputs in a public Lake artifact cache; the script fetches the index
# for the pinned Tau Ceti revision, and Lake downloads the modules the build needs. They match only
# when Mathlib and the Lean toolchain are exactly Tau Ceti's, which taking LMLExplore's pins
# guarantees (scripts/check-pins.sh). On any cache problem, the needed Tau Ceti modules are
# compiled from source. LMLExplore publishes no cache: the LMLExplore modules the paper imports
# are compiled.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"

lake exe cache get

config="$root/.lake/tauceti-cache.toml"
mkdir -p "$root/.lake"
cat > "$config" <<'TOML'
cache.defaultService = "tauceti-public"
[[cache.service]]
name = "tauceti-public"
kind = "s3"
artifactEndpoint = "https://cache.taucetiproject.org/artifacts"
revisionEndpoint = "https://cache.taucetiproject.org/revisions"
TOML

export LAKE_CONFIG="$config"
export LAKE_CACHE_DIR="$root/.lake/cache"
export LAKE_ARTIFACT_CACHE=true
export LAKE_RESTORE_ARTIFACTS=true

if ! lake cache get --service tauceti-public --repo TauCetiProject/TauCeti \
    --package TauCeti --max-revs=1 --mappings-only; then
  echo "warning: no Tau Ceti cache for the pinned revision; compiling the Tau Ceti modules needed" >&2
  unset LAKE_CONFIG LAKE_CACHE_DIR
  export LAKE_ARTIFACT_CACHE=false LAKE_RESTORE_ARTIFACTS=false
fi

lake build "$@"
