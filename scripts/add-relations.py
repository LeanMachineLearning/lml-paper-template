#!/usr/bin/env python3
"""Add the relations of the headline results to the Literature Links annotations.

    add-relations.py ANNOTATIONS.jsonl [--formalization formalization.yaml]

LMLExplore's scripts/literature/annotations.py writes annotations with no `relation`: they say
that a result of the literature and a declaration correspond. For the paper's headline results,
the phase-1 statement check also says how, in the `relation` key of each entry of
`alignment.statements` in formalization.yaml (`exactMatch`, `closeMatch`, `broadMatch`,
`narrowMatch` or `hasPart`, read "paper relation Lean"). This script copies it to the annotations
whose object is one of the entry's declarations (the `lean` key, comma-separated) and whose subject
is the entry's result: the one that its `source` names after the dash, as the paper numbers it
(`thm:lower — Theorem 1, the lower bound` names Theorem 1). A declaration whose docstring also
cites another result, or the proof of its own, keeps no relation for that one. The file is
rewritten in place. See https://github.com/mathlib-initiative/literature-links (docs/companion.md).
"""
import argparse
import json
import re
import sys

import yaml

RELATIONS = {"exactMatch", "closeMatch", "broadMatch", "narrowMatch", "relatedMatch", "hasPart"}

#: The result that an entry's `source` names after the dash: `Theorem 1`, `Lemma 3.2`.
RESULT = re.compile(r"—\s*([A-Z][A-Za-z]* [0-9][0-9A-Za-z.]*)")


def relations(path: str) -> dict[str, list[tuple[str | None, str]]]:
    """For each declaration, its headline results (None when the entry names none) and relations."""
    data = yaml.safe_load(open(path, encoding="utf-8")) or {}
    out: dict[str, list[tuple[str | None, str]]] = {}
    for entry in (data.get("alignment") or {}).get("statements") or []:
        relation = entry.get("relation")
        if not relation:
            continue
        if relation not in RELATIONS:
            sys.exit(f"formalization.yaml: unknown relation {relation!r} for {entry.get('lean')}")
        match = RESULT.search(str(entry.get("source", "")))
        result = match.group(1).rstrip(".") if match else None
        for name in str(entry.get("lean", "")).split(","):
            if name.strip():
                out.setdefault(name.strip(), []).append((result, relation))
    return out


def relation_of(annotation: dict, entries: list[tuple[str | None, str]]) -> str | None:
    """The relation of the entry whose result is the annotation's subject, if any."""
    if annotation.get("kind") == "proof":
        return None
    labels = {(end.get("location") or {}).get("label") for end in annotation.get("subject") or []}
    for result, relation in entries:
        if result is None or result in labels:
            return relation
    return None


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
            if end.get("type") != "lean" or name not in table:
                continue
            relation = relation_of(annotation, table[name])
            if relation:
                annotation["relation"] = relation
                added += 1
                break
        out.append(json.dumps(annotation, ensure_ascii=False))
    open(args.annotations, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"added {added} relations from {args.formalization}")


if __name__ == "__main__":
    main()
