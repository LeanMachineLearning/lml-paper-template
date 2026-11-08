#!/usr/bin/env bash
# Usage: scripts/init.sh <Lib> <Paper> <KEY>        e.g. scripts/init.sh Maiti2026Power MXJ2026 MXJ26
#
# Turn a fresh repository made from lml-paper-template into a paper project: <Lib> is the Lean
# library (first author, year, first word of the title), <Paper> the folder of the paper's own
# results, <KEY> the paper's citation key. The script fills in the template's placeholders (and
# the GitHub owner, repository and author it finds), renames the library's folders, drops the
# template's part of the README, and deletes itself. Run it once, before anything else, from a
# clean checkout.
set -euo pipefail

if [ $# -ne 3 ]; then
  sed -n '2p' "$0" | sed 's/^# //' >&2
  exit 2
fi
lib=$1 paper=$2 key=$3
for name in "$lib" "$paper"; do
  [[ $name =~ ^[A-Z][A-Za-z0-9]*$ ]] || { echo "$name: use letters and digits, starting with a capital letter" >&2; exit 2; }
done
[[ $key =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || { echo "$key: use letters and digits" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root"
[ -d PaperLib ] || { echo "this repository is already initialized" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }

nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [ -z "$nwo" ]; then
  nwo=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)
fi
[ -n "$nwo" ] || { echo "cannot tell the GitHub repository: create it first (gh repo create)" >&2; exit 1; }
author=$(git config user.name || true)
[ -n "$author" ] || author="<Author>"

LIB="$lib" PAPER="$paper" KEY="$key" NWO="$nwo" AUTHOR="$author" python3 - <<'EOF'
import os, re, subprocess
env = os.environ
owner, repo = env["NWO"].split("/", 1)
replacements = [
    ("PaperLib", env["LIB"]), ("PaperResults", env["PAPER"]), ("PAPERKEY", env["KEY"]),
    ("PAPER_OWNER", owner), ("PAPER_REPO", repo), ("PAPER_AUTHOR", env["AUTHOR"]),
]
files = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True, check=True).stdout
for path in filter(None, files.split("\0")):
    if path in ("scripts/init.sh", "LICENSE") or not os.path.isfile(path):
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except UnicodeDecodeError:
        continue
    new = text
    for old, value in replacements:
        new = new.replace(old, value)
    if path == "README.md":
        new = re.sub(r"<!-- template -->.*?<!-- /template -->\n*", "", new, flags=re.S)
    if new != text:
        open(path, "w", encoding="utf-8").write(new)
EOF

git mv PaperLib/PaperResults "PaperLib/$paper"
git mv PaperLib "$lib"
git mv PaperLib.lean "$lib.lean"
git rm -q scripts/init.sh

cat <<EOF
Initialized $lib ($nwo). Next:
  lake update LMLExplore
  cp .lake/packages/LMLExplore/lean-toolchain .
  scripts/build.sh && scripts/check-pins.sh
then commit, and follow bootstrap.md of the formalize-paper skill from step 3.
EOF
