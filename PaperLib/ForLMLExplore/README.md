# Library-shaped code, for LMLExplore

Everything the paper needs that is not specific to it, written so that a Tau Ceti worker can port
it to [LMLExplore](https://github.com/LeanMachineLearning/LMLExplore) almost as a copy:

- the layout and namespaces LMLExplore would use: `ForLMLExplore/Identification/Foo.lean`
  declares `LMLExplore.Identification.…`, as `LMLExplore/Identification/Foo.lean` would;
- LMLExplore's rules (its `AGENTS.md`): the copyright header, then `module`; Mathlib's linters with
  warnings as errors; no `set_option`, `native_decide`, axioms or meta code; docstrings, and the
  basic API of every definition, at the generality of the literature;
- citations of numbered results in docstrings, `[LS, Theorem 11.2]`, with a `## References`
  section in the module docstring.

`PAPER_ROADMAP.md`, at the root of the repository, tags each item here. `scripts/check-forlmlexplore.sh`
checks the rules that a text search can check; LMLExplore's own CI checks the rest on each port.
