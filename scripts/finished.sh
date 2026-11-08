#!/usr/bin/env bash
# Exit 0 when the paper project is finished: no `sorry` left in the library, no item of
# PAPER_ROADMAP.md waiting for LMLExplore (a `target` or `refactor` item whose pull request is not
# merged), no open pull request of the paper on LMLExplore, and comparator verifies every headline
# result. Comparator runs last: it takes 10 to 15 minutes. Run by scripts/formalize.sh.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
lib=$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -1)
mkdir -p .tauceti

if grep -rlw --include='*.lean' "sorry" "$lib" "$lib.lean" >/dev/null 2>&1; then
  echo "not finished: $lib still has sorry"
  exit 1
fi
waiting=$(python3 scripts/workers-toml.py --pending | paste -sd ' ' -)
if [ -n "$waiting" ]; then
  echo "not finished: items waiting for LMLExplore: $waiting"
  exit 1
fi
# The paper's identity, from the header of PAPER_ROADMAP.md (set by init.sh): the GitHub
# repository, or for a repository kept local, the GitHub login and the folder's name.
repo=$(sed -n 's/^Paper: \([^ ]*\).*/\1/p' PAPER_ROADMAP.md | head -n 1)
[ -n "$repo" ] || { echo "PAPER_ROADMAP.md has no 'Paper: <owner>/<repo>' header line" >&2; exit 1; }
open=$(gh pr list -R LeanMachineLearning/LMLExplore --state open \
         --search "\"Paper: $repo\" in:body" --json number -q length)
if [ "$open" != 0 ]; then
  echo "not finished: $open open pull requests on LMLExplore"
  exit 1
fi
if ! scripts/comparator-verify.sh --insecure > .tauceti/comparator.log 2>&1; then
  echo "not finished: comparator fails, see .tauceti/comparator.log"
  exit 1
fi
echo "finished"
