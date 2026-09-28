"""Build: deltas -> DBC -> MPQ, with review, consistency, version and hashes.

Steps (docs/design/client-patch-pipeline.md 3.4):

1. identify the client base by fingerprint (unknown base -> stop)
2. load every DBC that has deltas or a consistency rule, through its binding
3. apply deltas, write changed DBCs
4. dbcdiff against the base; any undeclared difference -> stop
5. consistency against the server SQL exports; blocking finding -> stop
6. version file, pack with the pinned mpqcli, verify the archive listing
7. copy changed server-loaded DBCs to server-dbc/ (coupled release)
8. SHA256SUMS, sha1 (Nostalgia pins sha1) and build-info.json
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

from . import __version__, consistency, mpq
from .base import identify, locate, sha256_file
from .binding import Binding, load_bindings
from .delta import Touched, apply_all, changed_dbcs
from .diff import dbcdiff, undeclared, write_review
from .errors import BindingError, ClientPatchError, ConsistencyError, DeltaError
from .sqlsrc import SqlData, load_sources
from .wdbc import Table


@dataclass
class Config:
    path: Path
    data: dict

    @property
    def root(self) -> Path:
        return self.path.parent

    def dir(self, key: str) -> Path:
        return (self.root / self.data["paths"][key]).resolve()

    @property
    def patch(self) -> dict:
        return self.data["patch"]

    @property
    def mpq(self) -> dict:
        return self.data["mpq"]


def load_config(path: Path) -> Config:
    try:
        data = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise ClientPatchError(f"cannot read config {path}: {e}") from None
    return Config(Path(path).resolve(), data)


def _hashes(path: Path) -> dict:
    h1, h256 = hashlib.sha1(), hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h1.update(chunk)
            h256.update(chunk)
    return {"size": path.stat().st_size, "sha1": h1.hexdigest(), "sha256": h256.hexdigest()}


def git_commit(root: Path) -> str:
    try:
        rev = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--", "."],
                               capture_output=True, text=True, check=True).stdout.strip()
        return rev + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def guard_output(out_dir: Path) -> None:
    """Client-derived files must never land in Git: refuse an output directory
    inside a work tree unless Git ignores it."""
    out_dir = out_dir.resolve()
    probe = out_dir
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent  # nearest existing ancestor decides the work tree
    try:
        top = subprocess.run(["git", "-C", str(probe), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return  # not inside a Git work tree
    res = subprocess.run(["git", "-C", top, "check-ignore", "-q", str(out_dir / "probe")],
                         capture_output=True, check=False)
    if res.returncode != 0:
        raise ClientPatchError(
            f"output {out_dir} is inside the Git work tree {top} and not ignored. "
            "Built DBCs/MPQs are client-derived and must never be committed; "
            "use a directory outside the repository (or ops/clientpatch/dist/)."
        )


def _write_version(staging: Path, cfg: Config, info: dict) -> Path:
    p = staging / cfg.patch["version_file"]
    p.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}={info[k]}" for k in ("version", "label", "kind", "commit", "base")]
    p.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return p


def _pack(cfg: Config, staging: Path, out_dir: Path, version: int, mpqcli: str | None) -> tuple[Path, str]:
    tool = mpq.resolve_tool(cfg.mpq, mpqcli)
    tool_version = mpq.check_version(tool, cfg.mpq)
    archive = out_dir / cfg.patch["release_name"].format(version=version)
    mpq.create(tool, cfg.mpq, staging, archive)
    expected = sorted(str(p.relative_to(staging)).replace("\\", "/")
                      for p in staging.rglob("*") if p.is_file())
    listed = sorted(mpq.list_files(tool, cfg.mpq, archive))
    if listed != expected:
        raise ClientPatchError(f"archive listing {listed} != staged files {expected}")
    return archive, tool_version


def _finish(cfg: Config, out_dir: Path, archive: Path, info: dict, extra: list[Path]) -> dict:
    files = {archive.name: _hashes(archive)}
    for p in extra:
        files[str(p.relative_to(out_dir)).replace("\\", "/")] = _hashes(p)
    info["files"] = files
    info["patch_name"] = cfg.patch["name"]
    sums = "".join(f"{v['sha256']}  {k}\n" for k, v in sorted(files.items()))
    (out_dir / "SHA256SUMS").write_text(sums, encoding="utf-8", newline="\n")
    (out_dir / "build-info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n",
                                             encoding="utf-8", newline="\n")
    return info


def _fresh(out_dir: Path) -> Path:
    guard_output(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if any(out_dir.iterdir()):
        raise ClientPatchError(f"output directory {out_dir} is not empty")
    staging = out_dir / "staging"
    staging.mkdir()
    return staging


def build_testpatch(cfg: Config, version: int, label: str, out_dir: Path,
                    mpqcli: str | None = None) -> dict:
    """An archive with nothing but the version file (stage 1 transport test).
    It contains no client data, so it needs no base and no SQL."""
    staging = _fresh(out_dir)
    info = {"version": version, "label": label, "kind": "testpatch",
            "commit": git_commit(cfg.root), "base": "none", "tool": f"clientpatch {__version__}"}
    _write_version(staging, cfg, info)
    archive, tool_version = _pack(cfg, staging, out_dir, version, mpqcli)
    info["mpqcli"] = tool_version
    shutil.rmtree(staging)
    return _finish(cfg, out_dir, archive, info, [])


def load_tables(names: list[str], bindings: dict[str, Binding], base_dir: Path) -> dict[str, Table]:
    tables = {}
    for name in names:
        if name not in bindings:
            raise BindingError(f"no binding for {name}; add bindings/<build>/{name}.toml (see README)")
        path = locate(base_dir, name)
        if path is None:
            raise ClientPatchError(f"{name}.dbc not found in {base_dir}")
        tables[name] = Table.read(path, bindings[name])
    return tables


def build(cfg: Config, base_dir: Path, sql_dir: Path, version: int, label: str,
          out_dir: Path, mpqcli: str | None = None, log=print) -> dict:
    changes = cfg.dir("changes")
    changed = changed_dbcs(changes)
    rules = consistency.load_rules(cfg.dir("consistency"))
    needed = sorted(set(changed) | set(consistency.dbcs_needed(rules)))

    base = identify(base_dir, cfg.dir("bases"), needed)
    log(f"base: {base.id} (build {base.build})")
    bindings = load_bindings(cfg.dir("bindings") / base.build)

    sources = load_sources(cfg.dir("sql_sources"))
    missing = [s for s in consistency.sources_needed(rules) if s not in sources]
    if missing:
        raise ConsistencyError(f"rules use undeclared SQL sources: {', '.join(missing)}")
    sql = SqlData(sources, sql_dir)

    staging = _fresh(out_dir)
    tables = load_tables(needed, bindings, base_dir)
    base_tables = load_tables(changed, bindings, base_dir)  # pristine copies for dbcdiff

    touched: dict[str, Touched] = {}
    all_diffs = []
    for name in changed:
        t, files = apply_all(tables[name], changes, sql)
        touched[name] = t
        diffs = dbcdiff(base_tables[name], tables[name])
        bad = undeclared(diffs, t)
        if bad:
            write_review(bad, out_dir / "undeclared.csv")
            raise DeltaError(f"{name}: {len(bad)} undeclared difference(s), see undeclared.csv")
        all_diffs += diffs
        tables[name].write(staging / "DBFilesClient" / f"{name}.dbc")
        log(f"{name}: {len(files)} delta file(s), {len(diffs)} field change(s)")
    write_review(all_diffs, out_dir / "review.csv")

    findings = consistency.run(rules, tables, sql, touched)
    consistency.write_report(findings, out_dir / "consistency.csv")
    block = consistency.blocking(findings)
    if block:
        raise ConsistencyError(
            f"{len(block)} blocking consistency finding(s), see consistency.csv; first: "
            f"[{block[0].rule}] key {block[0].key}: {block[0].message}")
    log(f"consistency: {len(rules)} rule(s), {len(findings)} finding(s), all accepted")

    info = {"version": version, "label": label, "kind": "release",
            "commit": git_commit(cfg.root), "base": base.id, "build": base.build,
            "tool": f"clientpatch {__version__}", "python": sys.version.split()[0],
            "changed_dbcs": changed, "consistency_rules": [r.id for r in rules]}
    _write_version(staging, cfg, info)

    server_dir = out_dir / "server-dbc"
    extra = []
    for name in changed:
        if bindings[name].server_loaded:
            server_dir.mkdir(exist_ok=True)
            dst = server_dir / f"{name}.dbc"
            shutil.copyfile(staging / "DBFilesClient" / f"{name}.dbc", dst)
            extra.append(dst)
    info["server_dbcs"] = [p.name for p in extra]

    archive, tool_version = _pack(cfg, staging, out_dir, version, mpqcli)
    info["mpqcli"] = tool_version
    shutil.rmtree(staging)
    extra += [out_dir / "review.csv", out_dir / "consistency.csv"]
    return _finish(cfg, out_dir, archive, info, extra)


def extract_base(cfg: Config, client_dir: Path, out_dir: Path, mpqcli: str | None = None,
                 log=print) -> dict[str, str]:
    """Extract every DBFilesClient\\*.dbc from the base archives in load order;
    a later archive's copy replaces an earlier one (design 2.2). Returns
    {dbc file name: archive it came from} and writes extract-report.txt."""
    guard_output(out_dir)
    tool = mpq.resolve_tool(cfg.mpq, mpqcli)
    mpq.check_version(tool, cfg.mpq)
    data_dir = client_dir / "Data" if (client_dir / "Data").is_dir() else client_dir
    present = {p.name.lower(): p for p in data_dir.iterdir() if p.suffix.lower() == ".mpq"}
    order = [a.lower() for a in cfg.data["base"]["archives"]]
    prefix = cfg.data["base"]["member_prefix"].lower()
    ignored = sorted(n for n in present if n.startswith("patch") and n not in order)
    for n in ignored:
        log(f"not part of the base (ignored): {present[n].name}")
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = out_dir / ".extract-tmp"
    source: dict[str, str] = {}
    names: dict[str, Path] = {}  # lower-case name -> output path (first spelling wins)
    used = [present[a] for a in order if a in present]
    if not used:
        raise ClientPatchError(f"none of the base archives {order} found in {data_dir}")
    for archive in used:
        members = [m for m in mpq.list_raw(tool, cfg.mpq, archive)
                   if m.lower().startswith(prefix) and m.lower().endswith(".dbc")]
        for m in members:
            got = mpq.extract_file(tool, cfg.mpq, archive, m, tmp)
            key = got.name.lower()
            dst = names.setdefault(key, out_dir / got.name)
            shutil.move(str(got), dst)
            source[dst.name] = archive.name
        log(f"{archive.name}: {len(members)} DBC(s)")
    shutil.rmtree(tmp, ignore_errors=True)
    report = "".join(f"{k}\t{v}\n" for k, v in sorted(source.items()))
    (out_dir / "extract-report.txt").write_text(
        "# dbc\tarchive it was taken from (last in load order wins)\n" + report,
        encoding="utf-8", newline="\n")
    return source


def roundtrip(bindings: dict[str, Binding], directory: Path) -> list[str]:
    """Read and re-write every DBC that has a binding; report any byte difference."""
    problems = []
    for name, b in sorted(bindings.items()):
        path = locate(directory, name)
        if path is None:
            continue
        data = path.read_bytes()
        try:
            again = Table.from_bytes(data, b, str(path)).to_bytes()
        except ClientPatchError as e:
            problems.append(str(e))
            continue
        if again != data:
            problems.append(f"{name}: round trip changed the file")
    return problems


def file_hashes(path: Path) -> dict:
    return _hashes(path)


__all__ = ["Config", "load_config", "build", "build_testpatch", "roundtrip", "sha256_file"]
