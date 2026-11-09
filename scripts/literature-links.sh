#!/usr/bin/env bash
# Usage: scripts/literature-links.sh
#
# Commits literature/annotations.jsonl: the Literature Links annotations of the current commit,
# which say which declarations formalize which results of the paper
# (https://github.com/mathlib-initiative/literature-links). CI writes them on each push to main
# and publishes them on the website, from a dataset that only CI extracts; this script waits for
# CI to finish on the current commit, takes the copy the website then serves, and commits it.
#
# scripts/formalize.sh runs it when the paper is formalized and after the final bump, so that the
# repository records its links at those two moments. It needs the current commit pushed, and a
# repository on GitHub with its website; otherwise it says why and does nothing. It exits 0 unless
# something unexpected fails.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
out=literature/annotations.jsonl

skip() { echo "literature links not recorded: $1"; exit 0; }

repo=$(sed -n 's/^Paper: \([^ ]*\).*/\1/p' PAPER_ROADMAP.md | head -n 1)
[ -n "$repo" ] || skip "PAPER_ROADMAP.md has no 'Paper: <owner>/<repo>' header line"
gh api "repos/$repo" > /dev/null 2>&1 || skip "$repo is not a GitHub repository (a paper kept local has no CI)"
site=$(gh api "repos/$repo/pages" -q .html_url 2>/dev/null) || skip "$repo has no website (GitHub Pages)"

git fetch -q origin
sha=$(git rev-parse HEAD)
[ "$sha" = "$(git rev-parse '@{u}' 2>/dev/null)" ] || skip "the current commit ${sha:0:12} is not pushed"

# CI on this commit: wait for it to finish, up to an hour.
echo "waiting for CI on ${sha:0:12} to publish the literature links"
for _ in $(seq 60); do
  state=$(gh run list -R "$repo" --commit "$sha" --workflow ci.yml --json status,conclusion \
            -q 'map(select(.status == "completed")) | .[0].conclusion // ""')
  [ -n "$state" ] && break
  sleep 60
done
[ "$state" = success ] || skip "CI on ${sha:0:12} did not succeed (${state:-still running after an hour})"

# The website's copy, once it is the one of this commit: GitHub Pages may serve the previous one
# for a few minutes after the deployment.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for _ in $(seq 10); do
  if curl -fsSL "${site%/}/literature/annotations.jsonl?commit=$sha" -o "$tmp" 2> /dev/null &&
     python3 - "$tmp" "$sha" <<'EOF'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
lines = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
versions = {end.get("version") for a in lines for end in a.get("object") or [] if end.get("type") == "lean"}
sys.exit(0 if versions == {sha} else 1)
EOF
  then
    break
  fi
  rm -f "$tmp"
  sleep 30
done
[ -s "$tmp" ] || skip "the website does not serve the annotations of ${sha:0:12} (did CI's literature step fail?)"

# The same links as the committed ones, up to the commit they were read at: nothing to record.
if [ -f "$out" ] && python3 - "$out" "$tmp" <<'EOF'
import json, sys

def links(path):
    out = set()
    for line in open(path, encoding="utf-8"):
        if line.strip():
            a = json.loads(line)
            for end in a.get("object") or []:
                end.pop("version", None)
            out.add(json.dumps(a, sort_keys=True))
    return out

sys.exit(0 if links(sys.argv[1]) == links(sys.argv[2]) else 1)
EOF
then
  echo "literature links: $out has the same links already"
  exit 0
fi
mkdir -p literature
cp "$tmp" "$out"
git add "$out"
git commit -q -m "Literature links: the annotations of ${sha:0:12}" -- "$out"
git push -q
echo "literature links: committed $out ($(grep -c . "$out") annotations of ${sha:0:12})"
