<!-- template -->
# lml-paper-template

The template of a paper project: a Lean formalization of one machine learning paper on top of
[LMLExplore](https://github.com/LeanMachineLearning/LMLExplore), whose library-shaped part is
ported to LMLExplore by [Tau Ceti workers](https://github.com/TauCetiProject/TauCetiWorker) while
the formalization goes on. It goes with the `lml` Claude Code plugin of
[lml-claude](https://github.com/LeanMachineLearning/lml-claude), whose `formalize-paper` skill is
the workflow.

To start a paper, tell your AI agent:

> Read https://raw.githubusercontent.com/LeanMachineLearning/lml-claude/main/START.md with curl and follow it.

or create a repository from this template and run `scripts/init.sh <Lib> <Paper> <KEY>` in it
(for example `scripts/init.sh Maiti2026Power MXJ2026 MXJ26`); then follow `bootstrap.md` of the
formalize-paper skill.

The library here, PaperLib, builds as it is: this repository's CI checks the template against
LMLExplore's current `main`. Everything between the `template` markers of this README is removed
by `scripts/init.sh`.
<!-- /template -->
# PAPERREPO

A Lean 4 formalization of *<title of the paper>* (<authors>, <venue, year>), on top of
[LMLExplore](https://github.com/LeanMachineLearning/LMLExplore), and so of
[LML](https://github.com/LeanMachineLearning/LML), [Tau Ceti](https://github.com/TauCetiProject/TauCeti)
and [Mathlib](https://github.com/leanprover-community/mathlib4). Made from
[lml-paper-template](https://github.com/LeanMachineLearning/lml-paper-template).

- Website: https://PAPEROWNER.github.io/PAPERREPO/, with the blueprint, the referee site and the
  literature links (which declarations formalize which results of the paper). CI builds it on each
  push to `main`. `scripts/formalize.sh` also commits the literature links, as
  `literature/annotations.jsonl`, when the paper is formalized and after the final bump.
- The paper: `source/`. Errors found in it, with their corrections: `notes/paper-errata.md`.
- The paper's results: `PaperLib/PaperResults/`, one file per result, listed with their status in
  `formalization.yaml`; comparator challenges in `comparator/`.
- Library-shaped material: `PaperLib/ForLMLExplore/`, which Tau Ceti workers port to LMLExplore;
  `PAPER_ROADMAP.md` says where each item goes.

## Building

```bash
scripts/build.sh
```

The script fetches Mathlib's and Tau Ceti's prebuilt files, then runs `lake build`; its arguments go
to `lake build`.

## Working on it

The workflow is the `formalize-paper` skill of the `lml` Claude Code plugin
([lml-claude](https://github.com/LeanMachineLearning/lml-claude)). Phase 1 (outline, blueprint,
statements) is done in a Claude Code session. After it, `scripts/formalize.sh`, in a terminal or
tmux, proves the rest and sends the reusable parts to LMLExplore, with one agent or, as the end of
phase 1 chose (`--agents N` changes it), several agents on independent areas of the blueprint, each
in its own worktree under `.tauceti/slots/`.
