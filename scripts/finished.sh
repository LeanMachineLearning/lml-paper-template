#!/usr/bin/env bash
# Usage: scripts/finished.sh [paper|contributions]
#
#   paper          the paper is formalized: no `sorry` is left in the library, and comparator
#                  verifies every headline result (10 to 15 minutes; log in .tauceti/comparator.log).
#   contributions  nothing is left to contribute: no item of PAPER_ROADMAP.md waits for LMLExplore
#                  (a `target` or `refactor` item whose pull request is not merged), and no pull
#                  request of the paper on LMLExplore is open. Otherwise it prints what is left.
#   (none)         both.
#
# Exits 0 when it holds. Run by scripts/formalize.sh.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
lib=$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -1)
mkdir -p .tauceti
mode=${1:-all}

# A sorry in the library. Only paths that exist go to grep: some greps (ugrep) fail on a missing
# path even when another one matches.
sorry_left() {
  local paths=() p
  for p in "$lib" "$lib.lean"; do [ -e "$p" ] && paths+=("$p"); done
  [ ${#paths[@]} -gt 0 ] && grep -rqw --include='*.lean' "sorry" "${paths[@]}" 2> /dev/null
}

paper() {
  if sorry_left; then
    echo "not formalized: $lib still has sorry"
    return 1
  fi
  if ! scripts/comparator-verify.sh --insecure > .tauceti/comparator.log 2>&1; then
    echo "not formalized: comparator fails, see .tauceti/comparator.log"
    return 1
  fi
}

contributions() {
  local left=0 waiting repo open
  waiting=$(python3 scripts/workers-toml.py --pending | paste -sd ' ' -)
  if [ -n "$waiting" ]; then
    echo "items of PAPER_ROADMAP.md waiting for LMLExplore: $waiting"
    left=1
  fi
  # The paper's identity, from the header of PAPER_ROADMAP.md (set by init.sh).
  repo=$(sed -n 's/^Paper: \([^ ]*\).*/\1/p' PAPER_ROADMAP.md | head -n 1)
  [ -n "$repo" ] || { echo "PAPER_ROADMAP.md has no 'Paper: <owner>/<repo>' header line" >&2; exit 2; }
  open=$(gh pr list -R LeanMachineLearning/LMLExplore --state open \
           --search "\"Paper: $repo\" in:body" --json number -q 'map("#\(.number)") | join(" ")')
  if [ -n "$open" ]; then
    echo "open pull requests on LMLExplore: $open"
    left=1
  fi
  return "$left"
}

case "$mode" in
  paper) paper ;;
  contributions) contributions ;;
  all) contributions && paper && echo "finished" ;;
  *) echo "usage: scripts/finished.sh [paper|contributions]" >&2; exit 2 ;;
esac
