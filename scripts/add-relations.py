#!/usr/bin/env python3
"""Add the relations of the headline results to the Literature Links annotations.

    add-relations.py ANNOTATIONS.jsonl [--formalization formalization.yaml]

LMLExplore's scripts/literature/annotations.py writes annotations with no `relation`: they say
that a result of the literature and a declaration correspond. For the paper's headline results,
the phase-1 statement check also says how, in the `relation` key of each entry of
`alignment.statements` in formalization.yaml (`exactMatch`, `closeMatch`, `broadMatch`,
`narrowMatch` or `hasPart`, read "paper relation Lean"). This script copies it to every annotation
whose object is one of the entry's declarations (the `lean` key, comma-separated), rewriting the
file in place. See https://github.com/mathlib-initiative/literature-links (docs/companion.md).
"""
import argparse
import json
import sys

import yaml

RELATIONS = {"exactMatch", "closeMatch", "broadMatch", "narrowMatch", "relatedMatch", "hasPart"}


def relations(path: str) -> dict[str, str]:
    data = yaml.safe_load(open(path, encoding="utf-8")) or {}
    out = {}
    for entry in (data.get("alignment") or {}).get("statements") or []:
        relation = entry.get("relation")
        if not relation:
            continue
        if relation not in RELATIONS:
            sys.exit(f"formalization.yaml: unknown relation {relation!r} for {entry.get('lean')}")
        for name in str(entry.get("lean", "")).split(","):
            if name.strip():
                out[name.strip()] = relation
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("annotations")
    parser.add_argument("--formalization", default="formalization.yaml")
    args = parser.parse_args()
    table = relations(args.formalization)
    lines = open(args.annotations, encoding="utf-8").read().splitlines()
    out, added = [], 0
    for line in lines:
        if not line.strip():
            continue
        annotation = json.loads(line)
        for end in annotation.get("object") or []:
            name = (end.get("location") or {}).get("declaration")
            if end.get("type") == "lean" and name in table:
                annotation["relation"] = table[name]
                added += 1
                break
        out.append(json.dumps(annotation, ensure_ascii=False))
    open(args.annotations, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"added {added} relations from {args.formalization}")


if __name__ == "__main__":
    main()
