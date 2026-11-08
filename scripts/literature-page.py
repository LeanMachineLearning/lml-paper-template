#!/usr/bin/env python3
"""The literature page of the paper's website, from its Literature Links annotations.

    literature-page.py ANNOTATIONS.jsonl --out home_page/literature/index.md
                       [--formalization formalization.yaml]

Writes a page of the website (Markdown, rendered by Jekyll in the theme of the home page) that
lists, for each work cited and each of its results, the declarations of the project whose
docstrings cite it: each with a link to the declaration on the referee site and to its file at
the commit of the build. For the headline results it adds the relation that the phase-1
statement check recorded (add-relations.py has copied it into the annotations), and the erratum
when the paper had to be corrected. LMLExplore's annotations.py writes a page of its own, made for
leanmachinelearning.org; CI replaces it with this one.
"""
import argparse
import json
import re
import urllib.parse
from pathlib import Path

import yaml

LEGEND = [
    ("exactMatch", "the same claim, up to notation and junk values"),
    ("closeMatch", "nearly the same claim, with a difference that a reader should know, such as a "
                   "convention or a corrected constant"),
    ("broadMatch", "the Lean statement is more general"),
    ("narrowMatch", "the paper's statement is more general, for instance when a correction adds a "
                    "hypothesis"),
    ("hasPart", "the Lean statement is one claim of the result"),
]


def cell(text: str) -> str:
    """Text for a cell of a Markdown table."""
    return text.replace("|", "\\|")


def number_key(label: str) -> tuple:
    """Results in the order of the paper: by their numbers, then by name."""
    return tuple(int(n) for n in re.findall(r"\d+", label)) or (10**9,), label


def work_heading(citation: dict, end: dict) -> tuple[str, str]:
    """The title of a work, and a line with its authors, venue, year and link."""
    title = citation.get("title") or citation.get("id") or end.get("uri", "")
    authors = [" ".join(p for p in (a.get("given"), a.get("family")) if p) or a.get("literal", "")
               for a in citation.get("author") or []]
    names = "".join(authors)
    if len(authors) > 1:
        names = ", ".join(authors[:-1]) + " and " + authors[-1]
    year = ((citation.get("issued") or {}).get("date-parts") or [[None]])[0][0]
    arxiv = (end.get("identifiers") or {}).get("arxiv")
    version = end.get("version") or ""
    if arxiv:
        link = f"[arXiv:{arxiv}{version}](https://arxiv.org/abs/{arxiv}{version})"
    else:
        link = f"[link]({end['uri']})" if end.get("uri") else ""
    parts = [names, citation.get("container-title"), str(year) if year else None, link]
    parts = [p for p in parts if p]
    return title, ". ".join(parts) + "."


def errata(path: Path) -> dict[str, str]:
    """For each headline declaration, its erratum key."""
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    out = {}
    for entry in (data.get("alignment") or {}).get("statements") or []:
        for name in str(entry.get("lean", "")).split(","):
            if name.strip() and entry.get("erratum"):
                out[name.strip()] = str(entry["erratum"])
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("annotations", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--formalization", type=Path, default=Path("formalization.yaml"))
    args = parser.parse_args()
    text = args.annotations.read_text(encoding="utf-8")
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    erratum = errata(args.formalization)

    # Citation id -> {"citation", "end", "results": {(label, is a proof): rows}}.
    works: dict[str, dict] = {}
    repo = commit = ""
    for a in records:
        lean = next((e for e in a.get("object") or [] if e.get("type") == "lean"), None)
        if not lean:
            continue
        repo, commit = lean.get("uri", repo), lean.get("version", commit)
        for end in a.get("subject") or []:
            citation = end.get("citation") or {}
            key = citation.get("id") or end.get("uri", "")
            work = works.setdefault(key, {"citation": citation, "end": end, "results": {}})
            label = (end.get("location") or {}).get("label") or a.get("id", "")
            rows = work["results"].setdefault((label, a.get("kind") == "proof"), [])
            where = lean["location"]
            rows.append((where.get("declaration", ""), where.get("module", ""),
                         a.get("relation") or ""))

    lib = Path(repo).name or "the project"
    # Jekyll turns a relative link to a file into one from the domain's root, which misses the
    # repository's part of the path: an absolute link, like those of the home page.
    data = f"{{{{ site.url }}}}/{args.out.parent.name}/{args.annotations.name}"
    lines = [
        "---",
        "layout: default",
        "title: Literature links",
        f"description: Which declarations of {lib} formalize which results",
        "---",
        "",
        f"The declarations of [{lib}]({repo}) whose docstrings cite a result of the literature, at "
        f"commit [`{commit[:7]}`]({repo}/tree/{commit}). Each declaration links to the "
        "[referee site](../referee/), its file to the source. Declarations in `ForLMLExplore/` are "
        "the general forms that the project contributes to "
        "[LMLExplore](https://github.com/LeanMachineLearning/LMLExplore).",
        "",
        "For the headline results, the relation says how the paper's statement compares with the "
        "Lean one, read \"paper *relation* Lean\", as checked against the paper:",
        "",
    ]
    lines += [f"* **{name}**: {text};" for name, text in LEGEND[:-1]]
    lines += [f"* **{LEGEND[-1][0]}**: {LEGEND[-1][1]}.", ""]
    lines += [
        "The same links, in the "
        "[Literature Links](https://github.com/mathlib-initiative/literature-links) format: "
        f"[annotations.jsonl]({data}) ({len(records)} annotations).",
        "",
    ]
    # The paper first: the work with the most results.
    for key, work in sorted(works.items(), key=lambda kv: (-len(kv[1]["results"]), kv[0])):
        title, byline = work_heading(work["citation"], work["end"])
        lines += [f"## {cell(title)}", "", byline, "", "| Result | Declaration | File | Relation |",
                  "| --- | --- | --- | --- |"]
        for (label, proof), rows in sorted(work["results"].items(),
                                           key=lambda kv: (number_key(kv[0][0]), kv[0][1])):
            first = f"Proof of {label}" if proof else label
            for decl, module, relation in sorted(set(rows), key=lambda r: (not r[2], r[0])):
                short = decl.removeprefix(f"{lib}.")
                href = "../referee/#/d/" + urllib.parse.quote(decl, safe="")
                path = module.replace(".", "/") + ".lean"
                shown = path.removeprefix(f"{lib}/")
                note = relation
                if relation and decl in erratum:
                    note += f" ([erratum {erratum[decl]}]({repo}/blob/main/notes/paper-errata.md))"
                lines.append(f"| {cell(first)} | [`{short}`]({href}) | "
                             f"[{shown}]({repo}/blob/{commit}/{path}) | {note} |")
                first = ""
        lines.append("")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines), encoding="utf-8")
    results = [rows for w in works.values() for rows in w["results"].values()]
    print(f"wrote {args.out}: {len(results)} results, "
          f"{len({r[0] for rows in results for r in rows})} declarations")


if __name__ == "__main__":
    main()
