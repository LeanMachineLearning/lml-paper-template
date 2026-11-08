# Working in this repository

This repository formalizes a paper in Lean on top of LMLExplore. The workflow is the
`lml:formalize-paper` skill of the `lml` plugin (https://github.com/LeanMachineLearning/lml-claude):
load it before working here.

- If `scripts/init.sh` exists, the repository is not set up yet: follow the skill's `bootstrap.md`,
  which starts with `scripts/init.sh`.
- Phase 1 (outline, blueprint, statements of the main results) is done with the user. Its last
  step is the user's check of the statements against the paper.
- After phase 1, the user runs `scripts/formalize.sh` in a terminal; it calls
  `/lml:formalize-paper round` and `/lml:formalize-paper bump` itself. Phase 2 work in a session
  follows the same rules as those rounds.
- `PAPER_ROADMAP.md` belongs to the `lml:paper-roadmap` skill: keep its format exactly, since
  scripts parse it.
- Library-shaped code goes to the library's `ForLMLExplore/` folder, under LMLExplore's rules; the
  paper's own results go to the paper's folder, one file per result.
- Errors found in the paper go to `notes/paper-errata.md`.
- Build with `scripts/build.sh`, and check with `scripts/check-build.sh`, which fails on every
  warning except `declaration uses 'sorry'` (`lake build --wfail` would fail on those too). Never
  require Mathlib, Tau Ceti or LML directly: they come from LMLExplore, at its pins.
