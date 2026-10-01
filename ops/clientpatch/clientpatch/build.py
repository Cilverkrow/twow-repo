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

import csv
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

from . import __version__, consistency, mpq, ui
from .base import dbc_files, identify, locate, sha256_file
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


def _write_probe(staging: Path, cfg: Config, version: int) -> None:
    """Tiny addon (our own code, no Blizzard data) that prints a chat line at
    login. Whether the 1.12 client loads addons from a patch MPQ is exactly
    what the transport test shows (design 8, N1/N5); a client can't read
    TWPatch/version.txt from Lua."""
    name = cfg.patch["probe_addon"]
    d = staging / "Interface" / "AddOns" / name
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.toc").write_text(
        "## Interface: 11200\n"
        f"## Title: {name}\n"
        "## Notes: clientpatch transport test (#409), shipped inside the test patch MPQ\n"
        f"{name}.lua\n", encoding="utf-8", newline="\n")
    msg = f"{name}: TWPatch v{version} loaded from {cfg.patch['name']}"
    (d / f"{name}.lua").write_text(
        "-- Generated by clientpatch testpatch. Lua 5.0 (1.12 client).\n"
        'local f = CreateFrame("Frame")\n'
        'f:RegisterEvent("PLAYER_LOGIN")\n'
        f'f:SetScript("OnEvent", function() DEFAULT_CHAT_FRAME:AddMessage("{msg}") end)\n',
        encoding="utf-8", newline="\n")


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
    """Stage 1 transport test: the version file plus a probe addon that prints a
    chat line at login. It contains no client data, so it needs no base and no SQL."""
    staging = _fresh(out_dir)
    info = {"version": version, "label": label, "kind": "testpatch",
            "commit": git_commit(cfg.root), "base": "none", "tool": f"clientpatch {__version__}"}
    _write_version(staging, cfg, info)
    _write_probe(staging, cfg, version)
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


# The 1.12 protocol sends spell IDs as uint16 in SMSG_INITIAL_SPELLS,
# SMSG_SUPERCEDED_SPELL and SMSG_REMOVED_SPELL (twow-core Player.cpp): a spell
# above 65535 reaches the client as id - 65536 after a relog (#455, train 8b).
MAX_CLIENT_SPELL = 0xFFFF
SPELL_REF_COLUMNS = {
    "Talent": [f"SpellRank[{i}]" for i in range(9)] + ["RequiredSpellID"],
    "SkillLineAbility": ["Spell", "SupercededBySpell"],
}
ENCHANT_SPELL_EFFECTS = {1, 3, 7}  # SpellItemEnchantment.Effect: proc, equip and use spell


def check_client_spell_ids(tables: dict[str, Table], touched: dict[str, Touched]) -> None:
    """Every Spell row we add or change, and every spell a changed Talent,
    SkillLineAbility or spell-type SpellItemEnchantment row points at, must fit
    into 16 bits."""
    bad = []
    if "Spell" in touched:
        bad += [f"Spell row {k[0]}" for k in sorted(touched["Spell"].keys()) if k[0] > MAX_CLIENT_SPELL]
    for name, columns in SPELL_REF_COLUMNS.items():
        if name not in touched:
            continue
        for key in sorted(touched[name].keys()):
            for col in columns:
                v = tables[name].get(key, col)
                if v > MAX_CLIENT_SPELL:
                    bad.append(f"{name} {key[0]} {col}={v}")
    if "SpellItemEnchantment" in touched:
        t = tables["SpellItemEnchantment"]
        for key in sorted(touched["SpellItemEnchantment"].keys()):
            for i in range(3):
                v = t.get(key, f"EffectArg[{i}]")
                if t.get(key, f"Effect[{i}]") in ENCHANT_SPELL_EFFECTS and v > MAX_CLIENT_SPELL:
                    bad.append(f"SpellItemEnchantment {key[0]} EffectArg[{i}]={v}")
    if bad:
        raise DeltaError(f"{len(bad)} spell ID(s) above {MAX_CLIENT_SPELL} (the 1.12 client keeps "
                         f"spell IDs in 16 bits, #455); first: {', '.join(bad[:5])}")


def build(cfg: Config, base_dir: Path, sql_dir: Path, version: int, label: str,
          out_dir: Path, mpqcli: str | None = None, log=print,
          server_dbc_dir: Path | None = None) -> dict:
    changes = cfg.dir("changes")
    changed = changed_dbcs(changes)
    rules = consistency.load_rules(cfg.dir("consistency"))
    needed = sorted(set(changed) | set(consistency.dbcs_needed(rules)))

    base = identify(base_dir, cfg.dir("bases"), needed)
    log(f"base: {base.id} (build {base.build})")
    if server_dbc_dir is None:
        raise ClientPatchError("the server's data/dbc directory is required (--server-dbc)")
    log(f"server DBCs: {check_server_dbcs(base_dir, server_dbc_dir)} identical to the base")
    foreign_warnings = check_foreign(base_dir, changed, cfg.patch["name"], log)
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
        group = cfg.data.get("record_order", {}).get(name)
        if group:
            tables[name].group_by(group)
            split = tables[name].split_groups(group)
            if split:
                raise DeltaError(f"{name}: rows of {group} {sorted(split)} are not one contiguous block "
                                 f"(the client reads only the last block of a group, #455)")
        tables[name].write(staging / "DBFilesClient" / f"{name}.dbc")
        log(f"{name}: {len(files)} delta file(s), {len(diffs)} field change(s)")
    write_review(all_diffs, out_dir / "review.csv")
    check_client_spell_ids(tables, touched)
    log(f"spell IDs: every patched spell and spell reference <= {MAX_CLIENT_SPELL}")

    findings = consistency.run(rules, tables, sql, touched)
    consistency.write_report(findings, out_dir / "consistency.csv")
    block = consistency.blocking(findings)
    if block:
        raise ConsistencyError(
            f"{len(block)} blocking consistency finding(s), see consistency.csv; first: "
            f"[{block[0].rule}] key {block[0].key}: {block[0].message}")
    log(f"consistency: {len(rules)} rule(s), {len(findings)} finding(s), all accepted")

    if "Talent" in changed:
        ui.check_talents_per_tab(tables["Talent"], ui.talent_buttons(cfg.data))
    ui_files = ui.build_files(cfg.data, base_dir, staging)
    for row in ui_files:
        log(f"ui: {row['path']} ({row['transform']}, source {row['source_sha256'][:12]})")

    info = {"version": version, "label": label, "kind": "release",
            "commit": git_commit(cfg.root), "base": base.id, "build": base.build,
            "tool": f"clientpatch {__version__}", "python": sys.version.split()[0],
            "changed_dbcs": changed, "consistency_rules": [r.id for r in rules],
            "ui_files": ui_files, "foreign_archive_warnings": foreign_warnings}
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


FOREIGN_FILE = "foreign-archives.tsv"


def patch_rank(name: str) -> tuple | None:
    """Load position of a patch archive: patch < patch-2..9 < patch-A..Z
    (letters case-insensitive, design 2.2). None: not a patch-N/-L archive,
    so its load order relative to ours is unknown."""
    stem = name.lower().removesuffix(".mpq")
    if stem == "patch":
        return (0, "")
    m = re.fullmatch(r"patch-([0-9a-z])", stem)
    if not m:
        return None
    c = m.group(1)
    return (1, c) if c.isdigit() else (2, c)


def load_relation(name: str, ours: str) -> str:
    """'after' (loads after our patch and overrides it), 'before', 'ours' or 'unknown'."""
    r, o = patch_rank(name), patch_rank(ours)
    if r is None or o is None:
        return "unknown"
    if r == o:
        return "ours"
    return "after" if r > o else "before"


def check_foreign(base_dir: Path, changed: list[str], ours: str, log=print) -> list[str]:
    """Stop when an archive outside the base that loads after our patch (or in
    an unknown order) carries a DBC we change - it would silently override us
    on the client. An earlier foreign archive carrying one is a warning: our
    copy replaces its changes. Returns the warnings."""
    path = base_dir / FOREIGN_FILE
    if not path.is_file():
        raise ClientPatchError(
            f"{path} is missing. Create the base with 'clientpatch extract-base': it records "
            "which archives outside the base carry DBCs that could override our patch.")
    warnings, blocking = [], []
    wanted = {c.lower() for c in changed}
    with path.open(encoding="utf-8", newline="") as f:
        for row in csv.DictReader((ln for ln in f if not ln.startswith("#")), delimiter="\t"):
            dbcs = {d.lower().removesuffix(".dbc") for d in row["dbcs"].split(",") if d}
            hit = sorted(dbcs & wanted)
            if not hit:
                continue
            msg = f"{row['archive']} ({row['load_order']}) also carries {', '.join(hit)}"
            if row["load_order"] in ("after", "unknown"):
                blocking.append(msg)
            elif row["load_order"] == "before":
                warnings.append(msg + ": our copy replaces its changes to these DBCs")
    if blocking:
        raise ClientPatchError(
            "archive(s) in the client would override or may override our DBCs: "
            + "; ".join(blocking)
            + ". Remove or rename them on every client, or leave these DBCs unchanged (README, Limits).")
    for w in warnings:
        log(f"warning: {w}")
    return warnings


def check_server_dbcs(base_dir: Path, server_dir: Path) -> int:
    """Design 3.4 step 2 a: every DBC the server loads must be byte-identical to
    the client base, or client and server were extracted from different
    clients. Compares every *.dbc of the server's data/dbc directory."""
    server = dbc_files(server_dir)
    if not server:
        raise ClientPatchError(f"no .dbc files in the server directory {server_dir}")
    base = dbc_files(base_dir)
    missing = sorted(server[k].name for k in server if k not in base)
    differ = sorted(server[k].name for k in server
                    if k in base and sha256_file(server[k]) != sha256_file(base[k]))
    if missing or differ:
        raise ClientPatchError(
            "server DBCs and client base disagree - they were extracted from different "
            f"clients. Missing in the base: {missing or 'none'}; different: {differ or 'none'}")
    return len(server)


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
    known = {k.lower() for k in cfg.data["base"].get("known_other", [])}
    foreign = sorted(n for n in present if n not in order and n not in known)
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
    # Interface files we patch (clientpatch.ui): same archives, same rule.
    ui_source: dict[str, str] = {}
    for entry in ui.files(cfg.data):
        want = entry["path"].lower()
        for archive in used:
            hits = [m for m in mpq.list_raw(tool, cfg.mpq, archive) if m.lower() == want]
            if hits:
                got = mpq.extract_file(tool, cfg.mpq, archive, hits[0], tmp)
                dst = ui.local_path(out_dir, entry["path"])
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(got), dst)
                ui_source[entry["path"]] = archive.name
        if entry["path"] not in ui_source:
            raise ClientPatchError(f"{entry['path']}: in none of the base archives")
        log(f"ui: {entry['path']} from {ui_source[entry['path']]}")
    shutil.rmtree(tmp, ignore_errors=True)
    if ui_source:
        (out_dir / "ui-report.txt").write_text(
            "# ui file\tarchive it was taken from (last in load order wins)\n"
            + "".join(f"{k}\t{v}\n" for k, v in sorted(ui_source.items())), encoding="utf-8", newline="\n")
    report = "".join(f"{k}\t{v}\n" for k, v in sorted(source.items()))
    (out_dir / "extract-report.txt").write_text(
        "# dbc\tarchive it was taken from (last in load order wins)\n" + report,
        encoding="utf-8", newline="\n")

    # Archives outside the base: record where they load relative to our patch
    # and which DBCs they carry, so the build can refuse to be overridden.
    lines = ["# archives outside the base (not part of the pristine DBCs)",
             "archive\tload_order\tdbc_count\tdbcs"]
    for n in foreign:
        archive = present[n]
        rel = load_relation(archive.name, cfg.patch["name"])
        dbcs = sorted(m.replace("\\", "/").split("/")[-1]
                      for m in mpq.list_raw(tool, cfg.mpq, archive)
                      if m.lower().startswith(prefix) and m.lower().endswith(".dbc"))
        lines.append(f"{archive.name}\t{rel}\t{len(dbcs)}\t{','.join(dbcs)}")
        log(f"not part of the base: {archive.name} (loads {rel} {cfg.patch['name']}, "
            f"{len(dbcs)} DBC(s))")
    (out_dir / FOREIGN_FILE).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
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
