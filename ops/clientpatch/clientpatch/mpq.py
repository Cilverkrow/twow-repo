"""MPQ packing through a pinned, StormLib-based command-line tool (mpqcli).

The command lines live in ``clientpatch.toml`` ([mpq]), not in code. The
tool version is checked before every build, so a different mpqcli fails
with a clear message instead of silently producing a different archive.
The configured flags produce a reproducible archive: MPQ format 1 (the
1.12 client), zlib, a (listfile), and (attributes) *without* file times.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .errors import ToolError


def resolve_tool(cfg: dict, override: str | None) -> str:
    name = override or os.environ.get("CLIENTPATCH_MPQCLI") or cfg["tool"]
    path = shutil.which(name) or (name if Path(name).is_file() else None)
    if not path:
        raise ToolError(
            f"mpqcli not found ({name!r}). Use the container (see README), put mpqcli "
            "on PATH, or pass --mpqcli / set CLIENTPATCH_MPQCLI."
        )
    return path


def _run(argv: list[str]) -> str:
    try:
        res = subprocess.run(argv, capture_output=True, check=False)
    except OSError as e:
        raise ToolError(f"cannot run {argv[0]}: {e}") from None
    if res.returncode != 0:
        raise ToolError(f"{' '.join(argv)} failed: {res.stderr.decode(errors='replace').strip()}")
    return res.stdout.decode(errors="replace")


def check_version(tool: str, cfg: dict) -> str:
    out = _run([tool] + list(cfg["version_args"])).strip()
    want = str(cfg["version_prefix"])
    if not out.startswith(want):
        raise ToolError(
            f"mpqcli version {out!r} is not the pinned {want!r}. The archive format "
            "depends on the tool version; update the pin in clientpatch.toml on purpose "
            "(and re-run the determinism test) or use the pinned tool."
        )
    return out


def _fill(args: list[str], **values) -> list[str]:
    return [a.format(**values) for a in args]


def create(tool: str, cfg: dict, src_dir: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    _run([tool] + _fill(list(cfg["create_args"]), input=str(src_dir), output=str(output)))
    if not output.is_file():
        raise ToolError(f"mpqcli reported success but {output} was not written")


def list_raw(tool: str, cfg: dict, archive: Path) -> list[str]:
    """Archive member names as stored (backslash separators)."""
    out = _run([tool] + _fill(list(cfg["list_args"]), archive=str(archive)))
    return [line.strip() for line in out.splitlines() if line.strip()]


def list_files(tool: str, cfg: dict, archive: Path) -> list[str]:
    """Archive member names with forward slashes."""
    return [n.replace("\\", "/") for n in list_raw(tool, cfg, archive)]


def extract_file(tool: str, cfg: dict, archive: Path, member: str, out_dir: Path) -> Path:
    """Extract one member (flat) into out_dir; returns the written path."""
    out_dir.mkdir(parents=True, exist_ok=True)
    _run([tool] + _fill(list(cfg["extract_args"]), file=member, output=str(out_dir),
                        archive=str(archive)))
    path = out_dir / member.replace("\\", "/").split("/")[-1]
    if not path.is_file():
        raise ToolError(f"mpqcli did not write {path} from {archive}")
    return path
