#!/usr/bin/env bash
# Check the library's ForLMLExplore/ folder against the rules of LMLExplore's AGENTS.md that a
# text search can check: each file starts with the copyright header and has a `module` line, and
# no file uses set_option, native_decide, axioms, code-running commands, elaborators, custom
# syntax, nonlocal macros, or meta or unsafe code. Mathlib's linters (through lakefile.toml) check
# the style; LMLExplore's own CI audits the axioms of every port. `sorry` is allowed here while
# the formalization goes on.
#
# Usage: scripts/check-forlmlexplore.sh
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"
lib=$(sed -n 's/^name = "\(.*\)"$/\1/p' lakefile.toml | head -1)
dir="$lib/ForLMLExplore"
[ -d "$dir" ] || exit 0

status=0
check() {  # an extended regular expression, and what it forbids
  local hits
  if hits=$(grep -rnE --include='*.lean' "$1" "$dir"); then
    echo "$2:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    status=1
  fi
}
s='[[:space:]]'
check "(^|$s)set_option$s" "set_option is not allowed"
check "(^|[^[:alnum:]_])native_decide([^[:alnum:]_]|$)" "native_decide is not allowed"
check "^$s*((private|protected|noncomputable)$s+)*axiom$s" "axioms are not allowed"
check "^$s*(run_cmd|run_tac|run_elab|run_meta|#eval|#exit|initialize|builtin_initialize)($s|$)" \
  "commands that run code are not allowed"
check "^$s*(@\[[^]]*\]$s*)?((scoped|local)$s+)?(elab|elab_rules|macro_rules|syntax|declare_syntax_cat|notation|infix|infixl|infixr|prefix|postfix)($s|:|$)" \
  "elaborators and custom syntax are not allowed (prefer named definitions)"
check "^$s*(@\[[^]]*\]$s*)?macro$s" "nonlocal macros are not allowed (a local tactic macro is fine)"
check "(^|$s)(unsafe|meta$s+(def|import))$s" "meta and unsafe code is not allowed"

while IFS= read -r -d '' f; do
  head -n 1 "$f" | grep -q '^/-' || { echo "$f: does not start with the copyright header"; status=1; }
  grep -q '^module' "$f" || { echo "$f: has no module line"; status=1; }
done < <(find "$dir" -name '*.lean' -print0)

[ "$status" = 0 ] && echo "$dir follows LMLExplore's rules"
exit "$status"
