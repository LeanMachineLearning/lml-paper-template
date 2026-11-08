#!/usr/bin/env python3
"""The Tau Ceti workers of this paper, read from PAPER_ROADMAP.md, for scripts/formalize.sh.

    workers-toml.py --conf URL --source DIR --prs 231,240   the workers.toml, on stdout
    workers-toml.py --conf URL --source DIR --off           the same workers, all disabled
    workers-toml.py --pending                               items still to be ported, one per line

The workers (https://github.com/TauCetiProject/TauCetiWorker, docs/workers.md):

* one authoring worker per LMLRoadmaps area that has `target` items, enabled while one of them is
  `proved` (ready to port). It ports those items to LMLExplore, from the paper repository given
  as its source;
* one worker for the paper's open pull requests to LMLExplore (rebases, CI fixes, review fixes,
  reviews), limited to them through TAUCETI_PR, and disabled when there is none.

The format of PAPER_ROADMAP.md is owned by the paper-roadmap skill of the lml plugin.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAGS = {"exists", "target", "refactor", "staged", "paper"}


def items(path: Path) -> list[dict]:
    """The rows of the Items table: Id, Item, Tag, Link, Status, Files."""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 6 and re.fullmatch(r"R\d+", cells[0]) and cells[2] in TAGS:
            rows.append(dict(zip(("id", "item", "tag", "link", "status", "files"), cells)))
    return rows


def header_paper(path: Path) -> str:
    match = re.search(r"^Paper:\s*(\S+)", path.read_text(encoding="utf-8"), re.M)
    if not match or "/" not in match.group(1):
        sys.exit("PAPER_ROADMAP.md has no `Paper: <owner>/<repo>` header line")
    return match.group(1)


def pending(rows: list[dict]) -> list[str]:
    """`target` and `refactor` items whose pull request is not merged yet."""
    return [r["id"] for r in rows if r["tag"] in ("target", "refactor") and not r["status"].startswith("merged")]


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def worker_id(base: str, suffix: str) -> str:
    """An id of at most 40 characters of [a-z0-9-], unique to this paper and this role."""
    suffix = slug(suffix)
    return f"{base[: 39 - len(suffix)].strip('-')}-{suffix}"


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def prompt(area: str, paper: str) -> str:
    return (
        f"Port to LMLExplore only the items of PAPER_ROADMAP.md, in the source repository, that are "
        f"tagged target with a link in the {area} roadmap and have the status proved. Their proofs "
        f"are in the files that the Files column lists, under the library's ForLMLExplore/ folder. "
        f"Adapt them to pass LMLExplore's review: the generality that their target states (see the "
        f"Notes of PAPER_ROADMAP.md), names, placement and documentation; keep their citations. "
        f"One item per pull request. Open no pull request when no such item is left. End the pull "
        f"request description with the standalone lines `Paper: {paper}` and `Item: <the item's Id>`."
    )


def workers_toml(rows: list[dict], paper: str, conf: str, source: str, prs: str, off: bool) -> str:
    base = slug(paper.split("/", 1)[1])
    areas: dict[str, bool] = {}
    for row in rows:
        if row["tag"] == "target" and row["link"]:
            area = row["link"].split()[0]
            areas[area] = areas.get(area, False) or row["status"] == "proved"
    out = ["# Written by scripts/formalize.sh from PAPER_ROADMAP.md; do not edit.", "version = 1", ""]
    # No soft pacing: the user asked for this formalization now, and the paper loop is not paced
    # either. A worker still stops when the quota is used up.
    pace = 'pace = "0:100"'
    for area, ready in sorted(areas.items()):
        out += [
            "[[workers]]",
            f"id = {toml_string(worker_id(base, area))}",
            f"enabled = {'true' if ready and not off else 'false'}",
            f"conf = {toml_string(conf)}",
            'only = ["roadmap"]',
            f"roadmap_only = {toml_string(area)}",
            f"source = {toml_string(source)}",
            f"extra_roadmap_prompt = {toml_string(prompt(area, paper))}",
            pace,
            "",
        ]
    prs = ",".join(p for p in prs.split(",") if p.strip())
    out += [
        "[[workers]]",
        f"id = {toml_string(worker_id(base, 'prs'))}",
        f"enabled = {'true' if prs and not off else 'false'}",
        f"conf = {toml_string(conf)}",
        'only = ["rebase", "fix-ci", "fix", "review"]',
        pace,
    ]
    if prs:
        out.append(f"env = {{ TAUCETI_PR = {toml_string(prs)} }}")
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--roadmap", default=str(ROOT / "PAPER_ROADMAP.md"))
    parser.add_argument("--conf", help="the LMLExplore project configuration (tauceti.toml URL)")
    parser.add_argument("--source", help="the paper repository, as the authoring workers' source")
    parser.add_argument("--prs", default="", help="the paper's open pull requests, comma-separated")
    parser.add_argument("--off", action="store_true", help="disable every worker")
    parser.add_argument("--pending", action="store_true", help="list the items still to be ported")
    args = parser.parse_args()
    roadmap = Path(args.roadmap)
    rows = items(roadmap)
    if args.pending:
        print("\n".join(pending(rows)))
        return
    if not args.conf or not args.source:
        parser.error("--conf and --source are required")
    print(workers_toml(rows, header_paper(roadmap), args.conf, args.source, args.prs, args.off), end="")


if __name__ == "__main__":
    main()
