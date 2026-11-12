#!/usr/bin/env bash
# Usage: scripts/land.sh
#
# When several agents formalize the paper, each round of scripts/formalize.sh works in its own
# worktree, .tauceti/slots/<k> of the main checkout, on the branch round/<k>. Run in such a
# worktree, this script puts the slot's commits on the branch of the main checkout: it rebases them
# onto that branch, regenerates the root module <Lib>.lean, checks the build when the branch has
# moved since the round started, fast-forwards the main checkout and pushes it to origin, when the
# repository has one. One landing runs at a time.
#
# Exit status:
#   0  landed, or nothing to land;
#   1  the rebase stops on conflicts, which it lists: it is aborted, the slot is unchanged;
#   2  the build fails after the rebase: the slot is left rebased, with the errors printed;
#   3  the main checkout has local changes in files that the commits change (a session there):
#      try again later;
#   4  not in a slot, or the slot has uncommitted changes.
set -euo pipefail

slot="$(git rev-parse --show-toplevel)"
cd "$slot"
root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
if [ "$slot" = "$root" ]; then
  echo "land.sh runs in a slot worktree (.tauceti/slots/<k>), not in the main checkout" >&2
  exit 4
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "the slot has uncommitted changes: commit them, or revert them, first" >&2
  exit 4
fi
branch="$(git -C "$root" symbolic-ref --short HEAD)"
lib=$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -n 1)

# The lock: a directory holding the pid of the landing that owns it (mkdir is atomic, and flock is
# not on every system). A lock whose owner is gone is stale.
lock="$root/.tauceti/land.lock"
mkdir -p "$root/.tauceti"
until mkdir "$lock" 2> /dev/null; do
  owner=$(cat "$lock/pid" 2> /dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2> /dev/null; then
    rm -rf "$lock"
    continue
  fi
  sleep 5
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 1' INT TERM HUP

rebasing() {
  [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# Rebase onto the branch. Conflicts in the generated root module alone are resolved by generating it
# again; any other conflict aborts the rebase.
rebase() {
  local conflicts
  git rebase -q "$branch" > /dev/null 2>&1 || true
  while rebasing; do
    conflicts=$(git diff --name-only --diff-filter=U)
    if [ "$conflicts" != "$lib.lean" ]; then
      git rebase --abort
      echo "the rebase onto $branch stops on conflicts in:"
      echo "$conflicts" | sed 's/^/  /'
      echo "Resolve them: git rebase $branch, keep both sides' changes, git add, git rebase --continue."
      echo "Then run scripts/check-build.sh, and scripts/land.sh again."
      exit 1
    fi
    lake exe mk_all --lib "$lib" > /dev/null
    git add "$lib.lean"
    GIT_EDITOR=true git rebase --continue > /dev/null 2>&1 || true
  done
}

for _ in 1 2 3; do
  if git merge-base --is-ancestor HEAD "$branch"; then
    echo "nothing to land: the slot's commits are on $branch"
    exit 0
  fi
  if ! git merge-base --is-ancestor "$branch" HEAD; then
    rebase
    if ! git merge-base --is-ancestor "$branch" HEAD; then
      echo "the rebase onto $branch failed" >&2
      exit 1
    fi
    # A root module merged without conflict may still miss a module, or list a deleted one.
    lake exe mk_all --lib "$lib" > /dev/null
    if [ -n "$(git status --porcelain -- "$lib.lean")" ]; then
      git commit -q --amend --no-edit -- "$lib.lean"
    fi
    # The other rounds' changes and this one's may not build together.
    build_log="$(git rev-parse --git-path land-build.log)"
    if ! scripts/check-build.sh > "$build_log" 2>&1; then
      echo "the build fails after the rebase onto $branch:"
      grep -E "error|warning" "$build_log" | grep -v "declaration uses .sorry." | head -n 40 || true
      echo "Fix it, amend the round's commit (git commit --amend), and run scripts/land.sh again."
      exit 2
    fi
  fi
  if out=$(git -C "$root" merge -q --ff-only "$(git rev-parse HEAD)" 2>&1); then
    if git -C "$root" remote get-url origin > /dev/null 2>&1; then
      git -C "$root" push -q origin "$branch" \
        || echo "warning: the push to origin failed; the next landing pushes again" >&2
    fi
    echo "landed on $branch: $(git log -1 --format='%h %s')"
    exit 0
  fi
  # A commit in the main checkout (a session there) moved the branch: rebase again. Otherwise its
  # local changes are in the way.
  if git merge-base --is-ancestor "$branch" HEAD; then
    echo "the main checkout refuses the fast-forward:"
    echo "$out" | sed 's/^/  /'
    exit 3
  fi
done
echo "the branch $branch keeps moving; try again later"
exit 3
