#!/usr/bin/env bash
# Usage: scripts/formalize.sh         run the rest of the formalization, once phase 1 is done;
#                                     run again after it, to contribute what is left to LMLExplore
#        scripts/formalize.sh --agents N
#                                     the same, with up to N rounds at once (kept for later runs)
#        scripts/formalize.sh stop    stop it, and its workers
#        scripts/formalize.sh status  show the workers' state
#        scripts/formalize.sh logs ID show a worker's log
#
# Run it in a terminal or tmux, outside any agent session, and leave it running. On your
# subscription, it drives:
#
# - the paper loop: `claude -p "/lml:formalize-paper round"` sessions; the formalize-paper skill of
#   the lml plugin says what a round does. One round at a time, unless the end of phase 1 chose
#   several agents (.tauceti/agents, which --agents N changes): then, until the paper is
#   formalized, up to that many rounds run at once, each on its own area of the blueprint and in
#   its own worktree, .tauceti/slots/<k>, and each puts its commit on the main checkout with
#   scripts/land.sh. A round starts only once the previous one has claimed its job, and when no
#   other area can be worked on, only the running rounds go on;
# - Tau Ceti workers (https://github.com/TauCetiProject/TauCetiWorker), as managed workers: one per
#   LMLRoadmaps area with `target` items in PAPER_ROADMAP.md, porting to LMLExplore the items the
#   paper loop has proved. A worker runs only while an item is ready to port: proved, and with no
#   pull request yet. The script checks that every 30 seconds. LMLExplore's side reviews the
#   pull requests and makes the changes they need; the paper runs no worker for them.
#
# It stops, with its workers, once the paper is formalized: no `sorry` is left and comparator verifies
# every headline result. It then commits the paper's literature links (scripts/literature-links.sh)
# and says what is still to contribute to LMLExplore. Run it again to contribute that: the workers
# run, rounds run when the paper's pull requests or LMLRoadmaps change, until one finds nothing to
# do, and once everything is merged one final bump moves the paper to the current LMLExplore, and
# the links are committed again.
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

# How many rounds may run at once while the paper is formalized: .tauceti/agents, which the end of
# phase 1 writes and `--agents N` changes; 1 without it.
if [ "${1:-}" = --agents ]; then
  [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "usage: scripts/formalize.sh --agents N, with N ≥ 1" >&2; exit 2; }
  echo "$2" > "$state/agents"
  shift 2
fi
agents=$(cat "$state/agents" 2> /dev/null || echo 1)
[[ "$agents" =~ ^[1-9][0-9]*$ ]] || agents=1

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

# Write the workers' configuration from the committed PAPER_ROADMAP.md, which the workers port from
# (arguments: `--ported LIST`, or `--off`), and reconcile it when it changed, or on the
# first call of a run (the manager may be gone, after a reboot or a failed reconcile). The manager
# also reloads the file on each of its cycles. It stops a worker at once when its block changes, so
# a worker in the middle of a run keeps its block until it is between runs (workers-toml.py).
applied=""
workers() {
  local new
  new=$(mktemp "$cfg.XXXXXX")
  git show HEAD:PAPER_ROADMAP.md | python3 scripts/workers-toml.py --roadmap - --conf "$TAUCETI_CONF" \
    --source "$root" --current "$cfg" --state-dir "$TAUCETI_WORKERS_STATE_DIR" "$@" > "$new" \
    || { rm -f "$new"; return 1; }
  if cmp -s "$new" "$cfg" && { [ -n "$applied" ] || [ "${1:-}" = --off ]; }; then
    rm -f "$new"
  else
    mv "$new" "$cfg"
    tauceti workers --config "$cfg" apply || { rm -f "$cfg"; return 1; }
    applied=1
  fi
}

# The background loop that keeps the workers' configuration current (workers_watch, below). It
# stops before any other change to the configuration, and with the script.
watch_pid=""
watch_stop() {
  [ -n "$watch_pid" ] || return 0
  kill "$watch_pid" 2> /dev/null || true
  wait "$watch_pid" 2> /dev/null || true
  watch_pid=""
}

# The claude process of each parallel round while it runs, by slot (see "Several agents" below).
# The script stops them when it stops.
rpid=()
rounds_stop() {
  local p
  for p in ${rpid[@]+"${rpid[@]}"}; do
    [ -z "$p" ] || kill -TERM "$p" 2> /dev/null || true
  done
}

# Turn the workers off and stop their manager, which would otherwise outlive the script, idle.
workers_stop() {
  watch_stop
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
trap 'rounds_stop; watch_stop; rm -f "$state/loop.pid"' EXIT
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
# The items that an open or merged pull request of the paper names in its `Item:` line: they are
# ported, or being ported. A pull request closed without merging makes its item ready again.
ported_items() {
  gh pr list -R LeanMachineLearning/LMLExplore --state all --limit 200 \
    --search "\"Paper: $repo\" in:body" --json state,body -q '.[] | select(.state != "CLOSED") | .body' \
    | tr -d '\r' | sed -n 's/^Item: *\(R[0-9][0-9]*\).*$/\1/p' | sort -u | paste -s -d , -
}

# Bring the workers' configuration up to date now, then keep it so every 30 seconds in the
# background, until the next call: a porting worker opens its pull request in the middle of a
# round, and should stop once it is between runs, instead of starting runs that find nothing to
# port. Its output goes to .tauceti/workers-watch.log.
workers_watch() {
  watch_stop
  workers --ported "$(ported_items)"
  ( while sleep 30; do
      workers --ported "$(ported_items)" || true
    done >> "$state/workers-watch.log" 2>&1 ) &
  watch_pid=$!
}

# Stop rather than spend rounds on a setup the rounds cannot fix. The workers keep running;
# `scripts/formalize.sh stop` stops them too.
stuck() {
  echo "$(date '+%F %T') stopped: $1" >&2
  echo "Fix it, then run scripts/formalize.sh again. The round logs are in $state/." >&2
  exit 1
}

# Whether the round of $log found nothing to do, even if it set the line in Markdown.
nothing_to_do() {
  grep -qE '^[[:space:]>*_`-]*Nothing to do' "$log"
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
  slots_remove
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

# Contributing, after the milestone: when the paper's pull requests, LMLRoadmaps or the items
# waiting for LMLExplore change, rounds until one finds nothing to do. A round does one job, and
# every such change calls for a refresh first: waiting for the next change after each round would
# leave the later jobs, such as a refactor pull request, to no round at all. LMLExplore's side
# reviews the pull requests.
if [ -f "$state/formalized" ] && ! sorry_left; then
  echo "The paper is formalized; contributing what is left to LMLExplore."
  last=""
  idle=0   # rounds in a row that committed nothing
  while true; do
    workers_watch
    if scripts/finished.sh contributions > /dev/null; then finish; fi
    now=$( { gh pr list -R LeanMachineLearning/LMLExplore --state all \
               --search "\"Paper: $repo\" in:body" --json number,state -q '.[] | "\(.number) \(.state)"'
             git ls-remote https://github.com/LeanMachineLearning/LMLRoadmaps main
             python3 scripts/workers-toml.py --pending; } | sha256sum)
    if [ "$now" != "$last" ]; then
      before=$(git rev-parse HEAD)
      round || continue
      if nothing_to_do; then
        idle=0
        last=$now
      else
        # The round did a job, and the next one may have another: run it now.
        if [ "$(git rev-parse HEAD)" = "$before" ]; then
          idle=$((idle + 1))
          [ "$idle" -lt 3 ] || stuck "three rounds in a row committed nothing."
        else
          idle=0
        fi
        continue
      fi
    fi
    sleep 1800
  done
fi

# Several agents: until the milestone, rounds run in parallel. Slot k is a worktree,
# .tauceti/slots/<k>, on the branch round/<k>, with the main checkout's Lake packages and cache. Its
# round finds in .tauceti/claims/ of the worktree the jobs that the rounds beside it have claimed,
# claims another job, writing it to .tauceti/claim of the worktree, or prints `No free area`. Rounds
# start one at a time, each once the previous one has claimed its job; no round starts beside one
# that tags the roadmap, and after a `No free area`, none starts until another round lands. A
# round lands its commit on the main checkout with scripts/land.sh, which the loop runs again after
# the round, for a round that did not. A slot whose round left work behind (changes, or a commit
# that did not land) keeps its claim, and its next round takes the work up.
slots="$state/slots"
slog=()    # each slot's round log
sbase=()   # the slot's commit when its round started
shead=()   # the main checkout's commit then

# Whether the round of log $1 found no job to do, or no area free beside the other rounds.
nothing_in() {
  grep -qE '^[[:space:]>*_`-]*(Nothing to do|No free area)' "$1"
}

# Whether slot k still holds a round's work: changes, or commits that are not on the branch.
slot_busy() {
  [ -n "$(git -C "$slots/$1" status --porcelain)" ] || ! git merge-base --is-ancestor "round/$1" HEAD
}

# Create slot k's worktree, or update its plugin.
slot_setup() {
  local k=$1 dir="$slots/$1" op=update
  if [ ! -e "$dir/.git" ]; then
    git worktree prune
    git worktree add -q -B "round/$k" "$dir" HEAD
    mkdir -p "$dir/.lake" "$root/.lake/cache"
    ln -s "$root/.lake/packages" "$dir/.lake/packages"
    ln -s "$root/.lake/cache" "$dir/.lake/cache"
    # The main checkout's build, so that the slot's first build only redoes what changed since.
    if [ -d "$root/.lake/build" ]; then cp -R "$root/.lake/build" "$dir/.lake/build"; fi
    op=install
  fi
  # The rounds' plugin, for the slot's folder as for the main checkout. Installing it rewrites
  # .claude/settings.json, to the same settings.
  ( cd "$dir" && claude plugin "$op" lml@lml-claude --scope project > /dev/null 2>&1 ) \
    || echo "could not $op the lml plugin in $dir" >&2
  git -C "$dir" checkout -q -- .claude/settings.json
}

# Remove the slots that hold no work, once the paper is formalized: later rounds run in the main
# checkout.
slots_remove() {
  local dir k
  for dir in "$slots"/*; do
    [ -e "$dir/.git" ] || continue
    k=$(basename "$dir")
    if ! slot_busy "$k"; then
      git worktree remove "$dir" && git branch -q -D "round/$k" || true
    fi
  done
}

# The free slots, those holding an earlier round's work first: their rounds take it up.
slot_order() {
  local k
  for k in $(seq "$agents"); do
    if [ -z "${rpid[$k]:-}" ] && slot_busy "$k"; then echo "$k"; fi
  done
  for k in $(seq "$agents"); do
    if [ -z "${rpid[$k]:-}" ] && ! slot_busy "$k"; then echo "$k"; fi
  done
}

# Whether a running round tags the roadmap, a job that runs alone.
tagging() {
  local k
  for k in $(seq "$agents"); do
    if [ -n "${rpid[$k]:-}" ] && head -n 1 "$slots/$k/.tauceti/claim" 2> /dev/null | grep -q '^Tag'; then
      return 0
    fi
  done
  return 1
}

# Start a round in slot k, and return once it has claimed its job, or ended.
start_round() {
  local k=$1 dir="$slots/$1" j
  # A slot with no work left starts from the branch.
  slot_busy "$k" || git -C "$dir" merge -q --ff-only "$(git rev-parse HEAD)"
  rm -rf "$dir/.tauceti/claim" "$dir/.tauceti/claims"
  mkdir -p "$dir/.tauceti/claims" "$state/LMLExplore"
  for j in $(seq "$agents"); do
    if [ "$j" != "$k" ] && [ -s "$slots/$j/.tauceti/claim" ]; then
      cp "$slots/$j/.tauceti/claim" "$dir/.tauceti/claims/$j"
    fi
  done
  sbase[$k]=$(git -C "$dir" rev-parse HEAD)
  shead[$k]=$(git rev-parse HEAD)
  slog[$k]="$state/round-$(date +%Y%m%d-%H%M%S)-$k.log"
  echo "$(date '+%F %T') round in slot $k, log in ${slog[$k]}"
  # The refactor pull requests' clone of LMLExplore is the main checkout's.
  ( cd "$dir" && exec claude -p "/lml:formalize-paper round $k" --add-dir "$state/LMLExplore" ) \
    > "${slog[$k]}" 2>&1 &
  rpid[$k]=$!
  while kill -0 "${rpid[$k]}" 2> /dev/null && [ ! -s "$dir/.tauceti/claim" ]; do sleep 10; done
}

# Slot k's round has ended: report it, land its commit if it did not, and set `outcome` (failed,
# nothing, landed or idle), `pause` (no round starts before), `rest` (no round starts before the
# next 30-minute check) and `halt` (no round starts, and the loop stops once the others end).
end_round() {
  local k=$1 dir="$slots/$1" log=${slog[$1]} status=0 j others=0
  wait "${rpid[$k]}" || status=$?
  rpid[$k]=""
  for j in $(seq "$agents"); do
    if [ -n "${rpid[$j]:-}" ]; then others=$((others + 1)); fi
  done
  if [ "$status" != 0 ]; then
    echo "  slot $k: the round failed (a usage limit?); no round starts for 15 minutes"
    pause=$(( $(date +%s) + 900 ))
    outcome=failed
    slot_busy "$k" || rm -f "$dir/.tauceti/claim"
    return 0
  fi
  tail -n 3 "$log" | grep -v "^Blocked:" | sed "s/^/  slot $k: /"
  if grep -q "has not been trusted" "$log"; then
    halt="Claude Code does not trust $dir, so the rounds cannot build, edit or commit.
Run claude once in $dir and accept the trust dialog."
  fi
  if grep -q "^Setup problem:" "$log"; then
    halt="$(grep "^Setup problem:" "$log" | tail -n 1 | sed 's/^Setup problem: *//')"
  fi
  if grep -q "^Blocked:" "$log"; then
    grep "^Blocked:" "$log" | sed "s/^/  slot $k: /"
    echo "  The rounds skip it until you decide. In another terminal: cd $root, run claude,"
    echo "  and type /lml:formalize-paper decide. This loop can keep running meanwhile."
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "  slot $k: the round left changes it did not commit; the slot's next round takes them up"
  elif ! ( cd "$dir" && scripts/land.sh ) >> "$log" 2>&1; then
    echo "  slot $k: its commit did not land (see the end of $log); the slot's next round lands it"
  fi
  slot_busy "$k" || rm -f "$dir/.tauceti/claim"
  if nothing_in "$log"; then
    outcome=nothing
    # It ran alone, and nothing landed meanwhile: rest, as one round does after `Nothing to do`.
    if [ "$others" = 0 ] && [ "$(git rev-parse HEAD)" = "${shead[$k]}" ]; then rest=1; fi
  elif [ "$(git -C "$dir" rev-parse HEAD)" != "${sbase[$k]}" ] && ! slot_busy "$k"; then
    outcome=landed
  else
    outcome=idle
  fi
  case "$outcome" in
    landed|nothing) idle=0 ;;
    idle)
      idle=$((idle + 1))
      if [ "$idle" -ge 3 ]; then halt="three rounds in a row committed nothing."; fi
      ;;
  esac
}

parallel() {
  local k running head
  [ -d "$root/.lake/packages" ] || stuck "the project has no build yet: run scripts/build.sh once."
  # No round runs yet: only a slot that holds an earlier round's work keeps its claim.
  for k in $(seq "$agents"); do
    slot_setup "$k"
    slot_busy "$k" || rm -f "$slots/$k/.tauceti/claim"
  done
  echo "$(date '+%F %T') up to $agents rounds at once, in $slots/"
  idle=0 free=1 pause=0 halt="" rest=""
  head=$(git rev-parse HEAD)
  workers_watch
  while true; do
    running=0
    for k in $(seq "$agents"); do
      [ -n "${rpid[$k]:-}" ] || continue
      if kill -0 "${rpid[$k]}" 2> /dev/null; then running=$((running + 1)); else end_round "$k"; fi
    done
    # A landing may free areas, and it changes PAPER_ROADMAP.md, which the workers port from.
    if [ "$(git rev-parse HEAD)" != "$head" ]; then
      head=$(git rev-parse HEAD)
      free=1
      workers_watch
    fi
    if [ "$running" = 0 ]; then
      [ -z "$halt" ] || stuck "$halt"
      if ! sorry_left; then
        echo "$(date '+%F %T') no sorry left: comparator checks the headline results (10 to 15 minutes)"
        if scripts/finished.sh paper; then milestone; fi
        stuck "no sorry is left, but comparator does not verify the headline results: see
$state/comparator.log. A statement may differ from its challenge."
      fi
      if [ -n "$rest" ]; then
        if grep -q 'status: "blocked"' formalization.yaml; then
          echo "  Headline results are still blocked: run claude in $root and type /lml:formalize-paper decide."
        fi
        sleep 1800
        rest=""
      fi
      free=1
    fi
    if [ "$(date +%s)" -ge "$pause" ]; then
      for k in $(slot_order); do
        if [ -z "$free" ] || [ -n "$halt" ] || tagging || ! sorry_left; then break; fi
        start_round "$k"
        if kill -0 "${rpid[$k]}" 2> /dev/null; then
          running=$((running + 1))
        else
          end_round "$k"
          case "$outcome" in
            failed) break ;;
            nothing) free=""; break ;;
          esac
        fi
      done
    fi
    sleep 30
  done
}

if [ "$agents" -gt 1 ]; then parallel; fi

# Formalizing, until the milestone.
idle=0   # rounds in a row that committed nothing
while true; do
  workers_watch
  before=$(git rev-parse HEAD)
  round || continue
  if ! sorry_left; then
    echo "$(date '+%F %T') no sorry left: comparator checks the headline results (10 to 15 minutes)"
    if scripts/finished.sh paper; then milestone; fi
    stuck "no sorry is left, but comparator does not verify the headline results: see
$state/comparator.log. A statement may differ from its challenge."
  fi
  if nothing_to_do; then
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
