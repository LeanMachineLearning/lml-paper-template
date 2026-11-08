#!/usr/bin/env bash
# Usage: scripts/formalize.sh         run the rest of the formalization, once phase 1 is done
#        scripts/formalize.sh stop    stop it, and its workers
#
# Run it in a terminal or tmux, outside any agent session, and leave it running. On your
# subscription, it drives:
#
# - the paper loop: one `claude -p "/lml:formalize-paper round"` session at a time; the
#   formalize-paper skill of the lml plugin says what a round does;
# - Tau Ceti workers (https://github.com/TauCetiProject/TauCetiWorker), as managed workers: one per
#   LMLRoadmaps area with `target` items in PAPER_ROADMAP.md, porting to LMLExplore the items the
#   paper loop has proved, and one for the review, fixes and rebases of the paper's pull requests.
#
# It stops once every main result is proved, comparator passes and nothing is left to port, after
# one final bump to the current LMLExplore. Logs go to .tauceti/.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
state="$root/.tauceti"
mkdir -p "$state"
cfg="$state/workers.toml"

export TAUCETI_CONF=https://raw.githubusercontent.com/LeanMachineLearning/LMLExplore/main/tauceti.toml
ref=$(curl -fsSL https://raw.githubusercontent.com/LeanMachineLearning/lml-claude/main/worker.ref)
tauceti() { uvx --from "git+https://github.com/TauCetiProject/TauCetiWorker@$ref" tauceti "$@"; }

# Write the workers' configuration from PAPER_ROADMAP.md (arguments: `--prs LIST` or `--off`),
# and reconcile it when it changed. The manager also reloads the file on each of its cycles.
workers() {
  python3 scripts/workers-toml.py --conf "$TAUCETI_CONF" --source "$root" "$@" > "$cfg.new"
  if cmp -s "$cfg.new" "$cfg"; then
    rm -f "$cfg.new"
  else
    mv "$cfg.new" "$cfg"
    tauceti workers --config "$cfg" apply
  fi
}

if [ "${1:-}" = stop ]; then
  if [ -f "$state/loop.pid" ]; then
    kill "$(cat "$state/loop.pid")" 2>/dev/null || true
    rm -f "$state/loop.pid"
  fi
  workers --off
  echo "Stopped the paper loop; the workers stop on the manager's next cycle."
  exit 0
fi

if [ -f "$state/loop.pid" ] && kill -0 "$(cat "$state/loop.pid")" 2>/dev/null; then
  echo "formalize.sh is already running (pid $(cat "$state/loop.pid"))" >&2
  exit 1
fi
echo $$ > "$state/loop.pid"
trap 'rm -f "$state/loop.pid"' EXIT

if ! tauceti doctor; then
  echo "tauceti doctor reported a problem: fix it, then run this script again." >&2
  exit 1
fi

# The paper's identity, from the header of PAPER_ROADMAP.md (set by init.sh): the GitHub
# repository, or for a repository kept local, the GitHub login and the folder's name.
repo=$(sed -n 's/^Paper: \([^ ]*\).*/\1/p' PAPER_ROADMAP.md | head -n 1)
[ -n "$repo" ] || { echo "PAPER_ROADMAP.md has no 'Paper: <owner>/<repo>' header line" >&2; exit 1; }
while true; do
  prs=$(gh pr list -R LeanMachineLearning/LMLExplore --state open \
          --search "\"Paper: $repo\" in:body" --json number -q 'map(.number) | join(",")')
  workers --prs "$prs"

  log="$state/round-$(date +%Y%m%d-%H%M%S).log"
  echo "$(date '+%F %T') round, log in $log"
  if ! claude -p "/lml:formalize-paper round" > "$log" 2>&1; then
    echo "  the round failed (a usage limit?); retrying in 15 minutes"
    sleep 900
    continue
  fi
  tail -n 3 "$log" | sed 's/^/  /'
  if grep -q "^Blocked:" "$log"; then
    echo "  a headline result is blocked: see notes/paper-errata.md and decide what to do"
  fi
  if grep -q "^Nothing to do" "$log"; then
    if scripts/finished.sh; then
      break
    fi
    sleep 1800
  fi
done

echo "$(date '+%F %T') everything is proved and merged: the final bump"
if ! claude -p "/lml:formalize-paper bump" > "$state/bump.log" 2>&1; then
  echo "the bump failed, see $state/bump.log" >&2
fi
workers --off
echo "Done: the paper is proved, comparator passes, and its contributions are in LMLExplore."
