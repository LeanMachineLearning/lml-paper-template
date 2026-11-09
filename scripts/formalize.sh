#!/usr/bin/env bash
# Usage: scripts/formalize.sh         run the rest of the formalization, once phase 1 is done;
#                                     run again after it, to contribute what is left to LMLExplore
#        scripts/formalize.sh stop    stop it, and its workers
#        scripts/formalize.sh status  show the workers' state
#        scripts/formalize.sh logs ID show a worker's log
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
# It stops, with its workers, once the paper is formalized: no `sorry` is left and comparator verifies
# every headline result. It then commits the paper's literature links (scripts/literature-links.sh)
# and says what is still to contribute to LMLExplore. Run it again to contribute that: the workers
# run, a round runs when the paper's pull requests or LMLRoadmaps change, and once everything is
# merged one final bump moves the paper to the current LMLExplore, and the links are committed again.
#
# It also stops, saying why, when the rounds cannot work: Claude Code does not trust the folder (run
# `claude` in it once), a round ends with `Setup problem: …`, or three rounds in a row commit
# nothing. Logs go to .tauceti/.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
state="$root/.tauceti"
mkdir -p "$state"
cfg="$state/workers.toml"

# After a round's last turn, `claude -p` waits 10 minutes for the agents the round started, then
# stops them, and the round ends with nothing done: allow them two hours.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=7200000

export TAUCETI_CONF=https://raw.githubusercontent.com/LeanMachineLearning/LMLExplore/main/tauceti.toml
ref=$(curl -fsSL https://raw.githubusercontent.com/LeanMachineLearning/lml-claude/main/worker.ref)
tauceti() { uvx --from "git+https://github.com/TauCetiProject/TauCetiWorker@$ref" tauceti "$@"; }

# The paper's own workers manager: a manager serves one configuration, so papers formalized at the
# same time on one machine each need theirs. Its state and logs go to .tauceti/workers/, its sockets
# to a short path (a socket path has at most 107 bytes).
export TAUCETI_WORKERS_STATE_DIR="$state/workers"
export TAUCETI_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/tauceti-$(id -u)-$(printf %s "$root" | sha256sum | cut -c1-8)"

# Write the workers' configuration from PAPER_ROADMAP.md (arguments: `--prs LIST` or `--off`),
# and reconcile it when it changed, or on the first call of a run (the manager may be gone, after a
# reboot or a failed reconcile). The manager also reloads the file on each of its cycles.
applied=""
workers() {
  python3 scripts/workers-toml.py --conf "$TAUCETI_CONF" --source "$root" "$@" > "$cfg.new"
  if cmp -s "$cfg.new" "$cfg" && { [ -n "$applied" ] || [ "${1:-}" = --off ]; }; then
    rm -f "$cfg.new"
  else
    mv "$cfg.new" "$cfg"
    tauceti workers --config "$cfg" apply || { rm -f "$cfg"; return 1; }
    applied=1
  fi
}

# Turn the workers off and stop their manager, which would otherwise outlive the script, idle.
workers_stop() {
  workers --off
  tauceti workers --config "$cfg" manager-stop > /dev/null 2>&1 || true
}

if [ "${1:-}" = stop ]; then
  if [ -f "$state/loop.pid" ]; then
    pid=$(cat "$state/loop.pid")
    # The loop and its current round: the whole process group when the loop leads its own (a job
    # of a terminal or of tmux), else the loop's children, then the loop.
    if [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    else
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$state/loop.pid"
  fi
  workers_stop
  echo "Stopped the paper loop, its round, the workers and their manager."
  exit 0
fi

# The workers' state, and one worker's log.
if [ "${1:-}" = status ]; then tauceti workers --config "$cfg" status; exit; fi
if [ "${1:-}" = logs ]; then tauceti workers --config "$cfg" logs "${2:?usage: formalize.sh logs <worker id>}"; exit; fi

if [ -f "$state/loop.pid" ] && kill -0 "$(cat "$state/loop.pid")" 2>/dev/null; then
  echo "formalize.sh is already running (pid $(cat "$state/loop.pid"))" >&2
  exit 1
fi
echo $$ > "$state/loop.pid"
trap 'rm -f "$state/loop.pid"' EXIT
# One Ctrl-C stops the script. claude and the Tau Ceti tools catch it and exit normally, and bash
# goes on with the script after such a child unless the script traps the signal itself.
trap 'echo; echo "$(date "+%F %T") interrupted"; exit 130' INT TERM

# What the paper loop needs. The workers report their own problems in their logs
# (`scripts/formalize.sh logs <id>`). `tauceti doctor` is not run: it checks LMLExplore's own setup,
# which only its maintainers can change.
command -v claude > /dev/null || { echo "claude (Claude Code) is not on the PATH" >&2; exit 1; }
gh auth status > /dev/null 2>&1 || { echo "gh is not logged in: run gh auth login" >&2; exit 1; }

# The rounds use the lml plugin installed for this folder, which Claude Code updates only when an
# interactive session starts here: bring it to the plugin's current version.
claude plugin marketplace update lml-claude > /dev/null 2>&1 || true
claude plugin update lml@lml-claude --scope project > /dev/null 2>&1 \
  || echo "could not update the lml plugin; the rounds use the installed version" >&2

# The paper's identity, from the header of PAPER_ROADMAP.md (set by init.sh): the GitHub
# repository, or for a repository kept local, the GitHub login and the folder's name.
repo=$(sed -n 's/^Paper: \([^ ]*\).*/\1/p' PAPER_ROADMAP.md | head -n 1)
[ -n "$repo" ] || { echo "PAPER_ROADMAP.md has no 'Paper: <owner>/<repo>' header line" >&2; exit 1; }
lib=$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -1)
open_prs() {
  gh pr list -R LeanMachineLearning/LMLExplore --state open \
    --search "\"Paper: $repo\" in:body" --json number -q 'map(.number) | join(",")'
}

# Stop rather than spend rounds on a setup the rounds cannot fix. The workers keep running;
# `scripts/formalize.sh stop` stops them too.
stuck() {
  echo "$(date '+%F %T') stopped: $1" >&2
  echo "Fix it, then run scripts/formalize.sh again. The round logs are in $state/." >&2
  exit 1
}

# One round; its log is $log. Returns 1 when claude failed (a usage limit?) and it waited.
round() {
  log="$state/round-$(date +%Y%m%d-%H%M%S).log"
  echo "$(date '+%F %T') round, log in $log"
  if ! claude -p "/lml:formalize-paper round" > "$log" 2>&1; then
    echo "  the round failed (a usage limit?); retrying in 15 minutes"
    sleep 900
    return 1
  fi
  tail -n 3 "$log" | grep -v "^Blocked:" | sed 's/^/  /'
  # Claude Code applies the permission list of .claude/settings.json only in a trusted folder.
  if grep -q "has not been trusted" "$log"; then
    stuck "Claude Code does not trust $root, so the rounds cannot build, edit or commit.
Run claude once in $root and accept the trust dialog."
  fi
  if grep -q "^Setup problem:" "$log"; then
    stuck "$(grep "^Setup problem:" "$log" | tail -n 1 | sed 's/^Setup problem: *//')"
  fi
  if grep -q "^Blocked:" "$log"; then
    grep "^Blocked:" "$log" | sed 's/^/  /'
    echo "  The rounds skip it until you decide. In another terminal: cd $root, run claude,"
    echo "  and type /lml:formalize-paper decide. This loop can keep running meanwhile."
  fi
  return 0
}

# The paper's website, when GitHub Pages serves one: the blueprint, the referee site and the
# literature links, which CI builds on each push.
site() {
  local url
  url=$(gh api "repos/$repo/pages" -q .html_url 2>/dev/null) || return 0
  echo "The website, with the blueprint, the referee site and the literature links (once CI has run"
  echo "on the last push): $url"
}

# Everything is merged: the final bump, then stop.
finish() {
  echo "$(date '+%F %T') everything is contributed: the final bump"
  if ! claude -p "/lml:formalize-paper bump" > "$state/bump.log" 2>&1; then
    echo "the bump failed, see $state/bump.log" >&2
  fi
  scripts/literature-links.sh || echo "the literature links were not recorded" >&2
  workers_stop
  echo "Done: the paper is formalized, and its contributions are in LMLExplore."
  site
  exit 0
}

# The paper is formalized: stop, with the workers, and say what is left to contribute.
milestone() {
  git rev-parse HEAD > "$state/formalized"
  # The links of the formalized paper, in literature/annotations.jsonl, once CI has published them.
  scripts/literature-links.sh || echo "the literature links were not recorded" >&2
  local left
  if left=$(scripts/finished.sh contributions); then finish; fi
  workers_stop
  echo
  echo "The paper is formalized: every headline result is proved, and comparator verifies them."
  site
  echo "Still to contribute to LMLExplore:"
  echo "$left" | sed 's/^/  /'
  echo "The workers are stopped. Run scripts/formalize.sh again to contribute these: it runs the"
  echo "workers and the rounds that follow the pull requests, and once everything is merged it moves"
  echo "the paper to the current LMLExplore."
  exit 0
}

# A sorry in the library. Only paths that exist go to grep: some greps (ugrep) fail on a missing
# path even when another one matches.
sorry_left() {
  local paths=() p
  for p in "$lib" "$lib.lean"; do [ -e "$p" ] && paths+=("$p"); done
  [ ${#paths[@]} -gt 0 ] && grep -rqw --include='*.lean' "sorry" "${paths[@]}" 2> /dev/null
}

# Contributing, after the milestone: a round only when the paper's pull requests, LMLRoadmaps or
# the items waiting for LMLExplore change; the workers answer the reviews.
if [ -f "$state/formalized" ] && ! sorry_left; then
  echo "The paper is formalized; contributing what is left to LMLExplore."
  last=""
  while true; do
    workers --prs "$(open_prs)"
    if scripts/finished.sh contributions > /dev/null; then finish; fi
    now=$( { gh pr list -R LeanMachineLearning/LMLExplore --state all \
               --search "\"Paper: $repo\" in:body" --json number,state -q '.[] | "\(.number) \(.state)"'
             git ls-remote https://github.com/LeanMachineLearning/LMLRoadmaps main
             python3 scripts/workers-toml.py --pending; } | sha256sum)
    if [ "$now" != "$last" ]; then
      round || continue
      last=$now
    fi
    sleep 1800
  done
fi

# Formalizing, until the milestone.
idle=0   # rounds in a row that committed nothing
while true; do
  workers --prs "$(open_prs)"
  before=$(git rev-parse HEAD)
  round || continue
  if ! sorry_left; then
    echo "$(date '+%F %T') no sorry left: comparator checks the headline results (10 to 15 minutes)"
    if scripts/finished.sh paper; then milestone; fi
    stuck "no sorry is left, but comparator does not verify the headline results: see
$state/comparator.log. A statement may differ from its challenge."
  fi
  if grep -q "^Nothing to do" "$log"; then
    idle=0
    if grep -q 'status: "blocked"' formalization.yaml; then
      echo "  Headline results are still blocked: run claude in $root and type /lml:formalize-paper decide."
    fi
    sleep 1800
    continue
  fi
  # Every other round commits its job; three rounds without a commit are a problem to look at.
  if [ "$(git rev-parse HEAD)" = "$before" ]; then
    idle=$((idle + 1))
    [ "$idle" -lt 3 ] || stuck "three rounds in a row committed nothing."
  else
    idle=0
  fi
done
