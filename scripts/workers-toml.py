#!/usr/bin/env python3
"""The Tau Ceti workers of this paper, read from PAPER_ROADMAP.md, for scripts/formalize.sh.

    workers-toml.py --conf URL --source DIR --ported R3,R5   the workers.toml, on stdout
    workers-toml.py --conf URL --source DIR --off           the same workers, all disabled
    workers-toml.py --pending                               items still to be ported, one per line

`--roadmap -` reads PAPER_ROADMAP.md on stdin: formalize.sh passes the committed one, which is what
the workers port from.

The workers (https://github.com/TauCetiProject/TauCetiWorker, docs/workers.md) are authoring
workers, one per LMLRoadmaps area that has `target` items, enabled while one of them is ready to
port: `proved`, and named by no open or merged pull request of the paper (its `Item:` line;
`--ported` lists those items). Each ports those items to LMLExplore, from the paper repository
given as its source. The paper runs no worker for its pull requests: LMLExplore's side reviews
them and makes the changes they need.

A worker in the middle of a run keeps its current block (`--current`, `--state-dir`): the manager
stops a worker at once when its block changes, which would kill the agent's run. Its change is
written once the worker is between runs.

The format of PAPER_ROADMAP.md is owned by the paper-roadmap skill of the lml plugin.
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAGS = {"exists", "target", "refactor", "staged", "paper"}
# The states in which a worker is between runs, as TauCetiWorker's manager tests them before it
# reloads a changed configuration (worker_manager._defer_read_policy_reload).
BETWEEN_RUNS = {"idle", "backoff", "waiting-github", "waiting-budget", "waiting-quota"}


def items(text: str) -> list[dict]:
    """The rows of the Items table: Id, Item, Tag, Link, Status, Files."""
    rows = []
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 6 and re.fullmatch(r"R\d+", cells[0]) and cells[2] in TAGS:
            rows.append(dict(zip(("id", "item", "tag", "link", "status", "files"), cells)))
    return rows


def header_paper(text: str) -> str:
    match = re.search(r"^Paper:\s*(\S+)", text, re.M)
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


def busy(state_dir: Path | None, wid: str) -> bool:
    """Whether a managed worker is in the middle of a run, by its status file in the manager's state
    directory: alive (heartbeat in the last minute) and not between runs, the test of the manager."""
    if state_dir is None:
        return False
    try:
        status = json.loads((state_dir / f"{wid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    now = time.time()
    if not status.get("alive") or now - float(status.get("heartbeat_at") or 0) > 60:
        return False
    if status.get("state") not in BETWEEN_RUNS:
        return True
    if (status.get("next_action_at") or 0) - now < 15:
        return True
    pid = status.get("child_pid")
    if sys.platform.startswith("linux") and isinstance(pid, int):
        try:
            return bool(Path(f"/proc/{pid}/task/{pid}/children").read_text().strip())
        except OSError:
            return True
    return False


def current_blocks(path: Path | None) -> dict[str, str]:
    """The worker blocks of the workers.toml in use, by id, as this script wrote them."""
    if path is None or not path.is_file():
        return {}
    blocks = {}
    for block in re.split(r"(?m)^(?=\[\[workers\]\]$)", path.read_text(encoding="utf-8")):
        match = re.search(r'(?m)^id = "([^"]+)"$', block)
        if block.startswith("[[workers]]") and match:
            blocks[match.group(1)] = block.rstrip("\n")
    return blocks


def workers_toml(rows: list[dict], paper: str, conf: str, source: str, ported: set[str],
                 off: bool, current: dict[str, str], state_dir: Path | None) -> str:
    base = slug(paper.split("/", 1)[1])
    areas: dict[str, bool] = {}
    for row in rows:
        if row["tag"] == "target" and row["link"]:
            area = row["link"].split()[0]
            ready = row["status"] == "proved" and row["id"] not in ported
            areas[area] = areas.get(area, False) or ready
    # No soft pacing: the user asked for this formalization now, and the paper loop is not paced
    # either. A worker still stops when the quota is used up.
    pace = 'pace = "0:100"'
    blocks = []
    for area, ready in sorted(areas.items()):
        blocks.append([
            "[[workers]]",
            f"id = {toml_string(worker_id(base, area))}",
            f"enabled = {'true' if ready and not off else 'false'}",
            f"conf = {toml_string(conf)}",
            'only = ["roadmap"]',
            f"roadmap_only = {toml_string(area)}",
            f"source = {toml_string(source)}",
            f"extra_roadmap_prompt = {toml_string(prompt(area, paper))}",
            pace,
        ])
    out = []
    for lines in blocks:
        text = "\n".join(lines)
        wid = json.loads(lines[1].split(" = ", 1)[1])
        if not off and wid in current and current[wid] != text and busy(state_dir, wid):
            text = current[wid]
        out.append(text)
    return ("# Written by scripts/formalize.sh from PAPER_ROADMAP.md; do not edit.\nversion = 1\n"
            + "".join(f"\n{text}\n" for text in out))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--roadmap", default=str(ROOT / "PAPER_ROADMAP.md"), help="the roadmap, or - for stdin")
    parser.add_argument("--conf", help="the LMLExplore project configuration (tauceti.toml URL)")
    parser.add_argument("--source", help="the paper repository, as the authoring workers' source")
    parser.add_argument("--ported", default="", help="the items of the paper's open or merged pull requests")
    parser.add_argument("--current", help="the workers.toml in use, whose blocks busy workers keep")
    parser.add_argument("--state-dir", help="the workers manager's state directory (TAUCETI_WORKERS_STATE_DIR)")
    parser.add_argument("--off", action="store_true", help="disable every worker")
    parser.add_argument("--pending", action="store_true", help="list the items still to be ported")
    args = parser.parse_args()
    text = sys.stdin.read() if args.roadmap == "-" else Path(args.roadmap).read_text(encoding="utf-8")
    rows = items(text)
    if args.pending:
        print("\n".join(pending(rows)))
        return
    if not args.conf or not args.source:
        parser.error("--conf and --source are required")
    ported = {i.strip() for i in args.ported.split(",") if i.strip()}
    current = current_blocks(Path(args.current) if args.current else None)
    state_dir = Path(args.state_dir) if args.state_dir else None
    print(workers_toml(rows, header_paper(text), args.conf, args.source, ported, args.off, current,
                       state_dir), end="")


if __name__ == "__main__":
    main()
