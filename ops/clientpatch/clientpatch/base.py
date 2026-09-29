"""Client base fingerprints.

A base is the set of pristine DBCs extracted from one client install. Each
known base is registered in ``bases/<id>.toml``::

    id = "turtle-1.18.1-enUS"
    build = "1.12.1.5875"                     # which binding set applies
    client = "Turtle WoW 1.18.1 (build 7272), English"
    registered = "2026-10-01, by OB-15"

    [dbc]
    "Spell.dbc" = "<sha256>"
    ...

Only hashes are stored; the DBC files themselves never enter Git.
A build refuses to run on a base whose files do not match a registered
fingerprint - a new or modified client gives a clear error, not a patch
built on the wrong data.
"""

from __future__ import annotations

import hashlib
import tomllib
from dataclasses import dataclass
from pathlib import Path

from .errors import BaseError


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dbc_files(directory: Path) -> dict[str, Path]:
    """DBC files of a directory, keyed by canonical 'Name.dbc' (case-insensitive)."""
    if not directory.is_dir():
        raise BaseError(f"base directory {directory} does not exist")
    out: dict[str, Path] = {}
    for p in directory.iterdir():
        if p.is_file() and p.suffix.lower() == ".dbc":
            out[p.stem.lower()] = p
    return out


def locate(directory: Path, dbc: str) -> Path | None:
    return dbc_files(directory).get(dbc.lower())


@dataclass
class Base:
    id: str
    build: str
    client: str
    hashes: dict[str, str]  # 'Name.dbc' -> sha256
    path: Path


def load_bases(directory: Path) -> list[Base]:
    out = []
    if not directory.is_dir():
        return out
    for p in sorted(directory.glob("*.toml")):
        data = tomllib.loads(p.read_text(encoding="utf-8"))
        hashes = {str(k): str(v).lower() for k, v in data.get("dbc", {}).items()}
        if not hashes:
            raise BaseError(f"{p}: base without [dbc] hashes")
        out.append(Base(id=str(data.get("id", p.stem)), build=str(data["build"]),
                        client=str(data.get("client", "")), hashes=hashes, path=p))
    return out


def identify(base_dir: Path, bases_dir: Path, needed: list[str]) -> Base:
    """Return the registered base the directory matches.

    Every DBC in ``needed`` must be registered in the base and match its hash.
    """
    files = dbc_files(base_dir)
    known = load_bases(bases_dir)
    if not known:
        raise BaseError(
            f"no registered client base in {bases_dir}. Register the pristine "
            "client once with 'clientpatch fingerprint' (see README)."
        )
    reports = []
    for base in known:
        problems = []
        registered = {k.lower().removesuffix(".dbc"): v for k, v in base.hashes.items()}
        for dbc in needed:
            want = registered.get(dbc.lower())
            path = files.get(dbc.lower())
            if want is None:
                problems.append(f"{dbc}.dbc is not part of the registered fingerprint")
            elif path is None:
                problems.append(f"{dbc}.dbc is missing in {base_dir}")
            elif sha256_file(path) != want:
                problems.append(f"{dbc}.dbc differs from the registered hash")
        if not problems:
            return base
        reports.append(f"  {base.id}: " + "; ".join(problems))
    raise BaseError(
        f"{base_dir} matches no registered client base. A different client build, "
        "a localised client or a modified DBC would all cause this. Details:\n"
        + "\n".join(reports)
    )


def fingerprint_toml(base_dir: Path, base_id: str, build: str, client: str,
                     registered: str) -> str:
    files = dbc_files(base_dir)
    if not files:
        raise BaseError(f"no .dbc files in {base_dir}")
    lines = [
        "# Client base fingerprint. Hashes only - never commit the DBC files.",
        f'id = "{base_id}"',
        f'build = "{build}"',
        f'client = "{client}"',
        f'registered = "{registered}"',
        "",
        "[dbc]",
    ]
    for key in sorted(files):
        p = files[key]
        lines.append(f'"{p.stem}.dbc" = "{sha256_file(p)}"')
    return "\n".join(lines) + "\n"
