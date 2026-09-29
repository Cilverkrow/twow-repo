"""Find creature entries that C++ scripts summon, for expected/cpp-summoned-bosses.toml.

    python tools/scan_summons.py --core-src <dir with src/scripts and src/game> \\
        --candidates ids.txt --core-commit <sha> > expected/cpp-summoned-bosses.toml

It reads every ``.cpp``/``.h`` file below ``src/scripts`` and ``src/game``,
collects numeric constants (``enum`` members, ``constexpr``/``const`` values and
``#define``) with upper-case names, and looks at the first argument of every
``SummonCreature(...)`` and ``SpawnCreature(...)`` call. A number is used as it
is, a name is resolved through the constants. It prints a TOML expected list with
one ``[[summoned_boss]]`` per candidate entry it can prove, with file, line and
the argument as written in the note.

Limits: only direct calls with a number or a constant. Summons through a
variable that holds a value at run time, through a spell, an array or a table are
not found; those are entered by hand in ``expected/cpp-summoned-bosses-manual.toml``.
Python standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_CONST = re.compile(r"\b([A-Z][A-Z0-9_]{2,})\b\s*=\s*(\d{3,9})\b")
_DEFINE = re.compile(r"^\s*#\s*define\s+([A-Z][A-Z0-9_]{2,})\s+(\d{3,9})\b")
_CALL = re.compile(r"\b(?:Do)?(?:Summon|Spawn)Creature\(\s*((?:[A-Za-z_][A-Za-z0-9_]*::)*[A-Za-z_][A-Za-z0-9_]*|\d+)")
_SUFFIXES = {".cpp", ".h", ".hpp"}


def source_files(root: Path):
    for sub in ("src/scripts", "src/game"):
        base = root / sub
        if base.is_dir():
            for p in sorted(base.rglob("*")):
                if p.suffix.lower() in _SUFFIXES and p.is_file():
                    yield p


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def collect_constants(files) -> dict[str, dict[int, str]]:
    """name -> {number: 'file:line'}; a name that means several numbers keeps all of them."""
    consts: dict[str, dict[int, str]] = {}
    for f in files:
        for n, line in enumerate(read_lines(f), 1):
            code = line.split("//", 1)[0]
            m = _DEFINE.match(code)
            pairs = [(m.group(1), int(m.group(2)))] if m else [(a, int(b)) for a, b in _CONST.findall(code)]
            for name, num in pairs:
                consts.setdefault(name, {}).setdefault(num, f"{f.name}:{n}")
    return consts


def scan(root: Path, candidates: dict[int, str]) -> list[tuple[int, str, str]]:
    """Return ``(entry, candidate name, 'relative/path:line (argument)')`` for every provable candidate."""
    files = list(source_files(root))
    consts = collect_constants(files)
    found: dict[int, str] = {}
    for f in files:
        rel = f.relative_to(root).as_posix()
        for n, line in enumerate(read_lines(f), 1):
            m = _CALL.search(line.split("//", 1)[0])
            if not m:
                continue
            tok = m.group(1)
            short = tok.split("::")[-1]
            numbers = [int(tok)] if tok.isdigit() else list(consts.get(short, {}))
            for num in numbers:
                if num in candidates and num not in found:
                    found[num] = f"{rel}:{n} ({tok})"
    return [(e, candidates[e], found[e]) for e in sorted(found)]


def render(rows, commit: str, date: str) -> str:
    out = [
        "# Bosses and NPCs that C++ scripts summon: they have no spawn row on purpose.",
        f"# Found by tools/scan_summons.py over twow-core main @ {commit}, src/scripts and src/game:",
        "# SummonCreature/SpawnCreature calls whose first argument (a number, or a constant",
        "# resolved to a number) is a candidate creature entry. The note gives file, line and",
        "# the argument as written. Cases the scan cannot see are in cpp-summoned-bosses-manual.toml.",
        "# Regenerate when the scripts change.",
        "",
        "[instance]",
        'id = "cpp-summoned-bosses"',
        'name = "Bosses that C++ scripts summon"',
        f'source = "twow-core main {commit}, src/scripts and src/game (SummonCreature and SpawnCreature calls)"',
        f'source_date = "{date}"',
        "",
    ]
    for entry, name, where in rows:
        note = f"{name}: {where}".replace("\\", "/").replace('"', '\\"')
        out += ["[[summoned_boss]]", f"entry = {entry}", 'via = "cpp"', f'note = "{note}"', ""]
    return "\n".join(out)


def read_candidates(path: Path) -> dict[int, str]:
    cands: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        head, _, name = line.partition(" ")
        cands[int(head)] = name.strip() or head
    return cands


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--core-src", type=Path, required=True, help="directory that contains src/scripts and src/game")
    ap.add_argument("--candidates", type=Path, required=True, help="text file: '<entry> <name>' per line")
    ap.add_argument("--core-commit", required=True, help="commit of the scanned sources (goes into the header)")
    ap.add_argument("--date", default="1970-01-01", help="source_date for the list header")
    a = ap.parse_args(argv)
    rows = scan(a.core_src, read_candidates(a.candidates))
    sys.stdout.write(render(rows, a.core_commit, a.date) + "\n")
    print(f"{len(rows)} of the candidates proven", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
