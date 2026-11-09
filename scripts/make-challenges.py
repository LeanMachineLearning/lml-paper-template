#!/usr/bin/env python3
r"""Generate the comparator challenge files and configs for the headline results.

For each declaration listed in `comparator/targets.txt` this runs challenge-gen
(https://github.com/LeanTrustBuilders/challenge-gen) with `--import` for each of LMLExplore, LML,
Tau Ceti and Mathlib that the project uses, which writes

1. the statement with `sorry`, and the project's definitions it rests on, copied verbatim from
   their sources; the file imports the modules of those libraries it needs, whose definitions are
   not copied;
2. comparator's config for it, listing the theorems to check: the headline theorem, the lemmas
   the definitions use (left `sorry` in the challenge, proved by the solution), and the theorems
   Lean makes of the proofs inside definitions (`foo._proof_1`).

It writes them as `comparator/Challenge_<name>.lean` and `comparator/<name>.json`, the config
naming the challenge module `Challenge_<name>` and the solution module `Solution`. When
challenge-gen says comparator cannot check a statement (it reaches a private declaration, or an
auxiliary theorem Lean would share between two modules in one file), it writes no config, and
this script stops with its reason.

Usage (from the repository root, after `lake build`):

    scripts/make-challenges.py [--challenge-gen PATH] [--out DIR]

challenge-gen is taken from `--challenge-gen` or `$CHALLENGE_GEN_BIN`, or else cloned and built
at its tag `v<toolchain>` (`lean-toolchain`'s version) into `~/.cache/<library>/challenge-gen`.
`--out DIR` writes there instead of `comparator/`. Check the result with `lake build Comparator`
(every challenge must compile) and `scripts/comparator-verify.sh` (comparator itself).
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = re.search(r'^name = "([^"]+)"', open(os.path.join(ROOT, "lakefile.toml")).read(), re.M).group(1)
CACHE = os.path.expanduser(f"~/.cache/{LIB}")
CHALLENGE_GEN_REPO = "https://github.com/LeanTrustBuilders/challenge-gen"
#: The libraries a challenge imports instead of copying their definitions, when the project uses
#: them.
IMPORTED = ["LMLExplore", "LeanMachineLearning", "TauCeti", "Mathlib"]


def build_challenge_gen():
    """challenge-gen at the tag of the project's toolchain, cloned and built into the cache."""
    version = open(os.path.join(ROOT, "lean-toolchain")).read().strip().split(":v")[-1]
    tag = f"v{version}"
    src = os.path.join(CACHE, "challenge-gen")
    if not os.path.isdir(src):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["git", "clone", "--quiet", CHALLENGE_GEN_REPO, src], check=True)
    # The tag moves with each release for a toolchain: fetch it again.
    subprocess.run(["git", "-C", src, "fetch", "--quiet", "--force", "--tags", "origin"], check=True)
    if subprocess.run(["git", "-C", src, "checkout", "--quiet", tag]).returncode != 0:
        sys.exit(f"challenge-gen has no release {tag} for this project's toolchain: see "
                 f"{CHALLENGE_GEN_REPO}/tags")
    subprocess.run(["lake", "build", "challenge-gen"], cwd=src, check=True)
    return os.path.join(src, ".lake", "build", "bin", "challenge-gen")


def main():
    args = sys.argv[1:]
    binary = os.environ.get("CHALLENGE_GEN_BIN")
    out_dir = os.path.join(ROOT, "comparator")
    while args:
        a = args.pop(0)
        if a == "--challenge-gen" and args:
            binary = args.pop(0)
        elif a == "--out" and args:
            out_dir = os.path.abspath(args.pop(0))
        else:
            sys.exit(__doc__)
    binary = binary or build_challenge_gen()
    targets = [t.strip() for t in open(os.path.join(ROOT, "comparator", "targets.txt")) if t.strip()]

    work = tempfile.mkdtemp(prefix="challenge-gen-")
    decls = os.path.join(work, "targets.txt")
    open(decls, "w").write("".join(f"{LIB}.{t}\n" for t in targets))
    generated = os.path.join(work, "out")
    # The libraries whose definitions the challenges import rather than copy: those of IMPORTED
    # that the library uses. challenge-gen refuses a prefix with no module in the environment (a
    # paper on LML that does not import LMLExplore yet), and the run is retried without it.
    imported = list(IMPORTED)
    while True:
        cmd = ["lake", "env", binary, "--root", LIB]
        for prefix in imported:
            cmd += ["--import", prefix]
        run = subprocess.run(cmd + ["--decls-file", decls, "--out", generated],
                             cwd=ROOT, capture_output=True, text=True)
        missing = re.search(r"no module under (\S+), given to --import", run.stderr + run.stdout)
        if run.returncode != 0 and missing and missing.group(1) in imported:
            imported.remove(missing.group(1))
            continue
        break
    sys.stderr.write(run.stderr)
    if run.returncode != 0:
        sys.exit(f"challenge-gen failed:\n{run.stdout}")
    print(f"the challenges import {', '.join(imported)}")

    os.makedirs(out_dir, exist_ok=True)
    unchecked = []
    for t in targets:
        # challenge-gen names a file after its declaration, dots written `___`.
        stem = os.path.join(generated, f"{LIB}.{t}".replace(".", "___"))
        text = open(stem + ".lean").read()
        open(os.path.join(out_dir, f"Challenge_{t}.lean"), "w").write(text)
        if not os.path.exists(stem + ".json"):
            unchecked.append(t)
            continue
        cfg = json.load(open(stem + ".json"))
        cfg["challenge_module"] = f"Challenge_{t}"
        open(os.path.join(out_dir, f"{t}.json"), "w").write(json.dumps(cfg, indent=4) + "\n")
        print(f"wrote Challenge_{t}.lean and {t}.json ({len(cfg['theorem_names'])} theorems to check)")
    if unchecked:
        sys.exit(f"comparator cannot check {', '.join(unchecked)}: see challenge-gen's message above")


if __name__ == "__main__":
    main()
