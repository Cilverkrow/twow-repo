#!/usr/bin/env python3
"""Generate clientpatch bindings from WoWDBDefs, cross-checked against the core.

    python3 tools/gen_bindings.py \
        --wowdbdefs /path/to/WoWDBDefs --core /path/to/twow-core \
        --build 1.12.1.5875 --out bindings/1.12.1.5875 Talent TalentTab ...

For every DBC it:
  * takes the layout for the build from WoWDBDefs (definitions/<Dbc>.dbd);
  * when the core has a format string for the DBC (src/game/Database/DBCfmt.h),
    compares field count and per-field kind (f = float, s = string). Where
    the core reads a field as float/string and WoWDBDefs disagrees, the core
    wins - the server loads these files every day - and the binding says so;
  * marks server_loaded when the core's LoadDBCStores() loads the file;
  * writes bindings/<build>/<Dbc>.toml with the provenance in 'source'.

A DBC whose field count disagrees with the core is an error: fix it by hand
and document why. Re-run this tool after a WoWDBDefs or core update and
review the diff.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

LOC_FIELDS = 9  # 8 locales + flags in the 1.12 client


def pv(s: str) -> tuple:
    return tuple(int(x) for x in s.split("."))


def build_matches(line: str, target: tuple) -> bool:
    for part in line[len("BUILD "):].split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-")
            if pv(lo) <= target <= pv(hi):
                return True
        elif pv(part) == target:
            return True
    return False


def parse_dbd(path: Path, target: tuple) -> list[dict] | None:
    lines = path.read_text(encoding="utf-8").split("\n")
    if lines[0].strip() != "COLUMNS":
        raise SystemExit(f"{path}: not a .dbd file")
    cols: dict[str, str] = {}
    i = 1
    while lines[i].strip():
        m = re.match(r"(\w+)(?:<[^>]*>)?\s+(\w+)\??", lines[i].strip())
        cols[m.group(2)] = m.group(1)
        i += 1
    blocks, cur = [], None
    for line in lines[i:]:
        if not line.strip():
            if cur:
                blocks.append(cur)
            cur = None
            continue
        cur = cur or {"hdr": [], "fields": []}
        (cur["hdr"] if line.startswith(("BUILD", "LAYOUT", "COMMENT")) else cur["fields"]).append(line)
    if cur:
        blocks.append(cur)
    for b in blocks:
        if any(h.startswith("BUILD") and build_matches(h, target) for h in b["hdr"]):
            out = []
            for f in b["fields"]:
                f = f.split("//")[0].strip()
                m = re.match(r"(?:\$([\w,]+)\$)?(\w+)(?:<(u?)(\d+)>)?(?:\[(\d+)\])?", f)
                ann, name, uns, bits, arr = m.groups()
                out.append({"name": name, "ctype": cols[name], "bits": int(bits) if bits else None,
                            "unsigned": bool(uns), "count": int(arr) if arr else 1,
                            "id": "id" in (ann or "")})
            return out
    return None


def binding_type(f: dict) -> str:
    if f["ctype"] == "locstring":
        return "locstring"
    if f["ctype"] == "string":
        return "string"
    if f["ctype"] == "float":
        return "float"
    return ("uint" if f["unsigned"] else "int") + str(f["bits"] or 32)


def expand_kinds(fields: list[dict]) -> list[str]:
    kinds = []
    for f in fields:
        t = binding_type(f)
        for _ in range(f["count"]):
            if t == "locstring":
                kinds += ["s"] * (LOC_FIELDS - 1) + ["i"]
            elif t == "string":
                kinds.append("s")
            elif t == "float":
                kinds.append("f")
            else:
                kinds.append("i")
    return kinds


def core_formats(core: Path) -> tuple[dict[str, str], dict[str, str], set[str]]:
    fmt_text = (core / "src/game/Database/DBCfmt.h").read_text(encoding="utf-8")
    fmts = {}
    for m in re.finditer(r"const\s+char\s+(\w+)\s*\[\]\s*=\s*((?:\s*\"[^\"]*\")+)\s*;", fmt_text):
        fmts[m.group(1)] = "".join(re.findall(r'"([^"]*)"', m.group(2)))
    stores_text = (core / "src/game/Database/DBCStores.cpp").read_text(encoding="utf-8")
    store_fmt = dict(re.findall(r"DBCStorage\s*<\s*\w+\s*>\s*(\w+)\s*\(\s*(\w+)\s*\)", stores_text))
    body = stores_text[stores_text.index("void LoadDBCStores("):]
    file_fmt, loaded = {}, set()
    for store, fname in re.findall(r"LoadDBC\([^,]+,[^,]+,\s*(\w+)\s*,[^,]+,\s*\"(\w+)\.dbc\"", body):
        loaded.add(fname)
        if store in store_fmt:
            file_fmt[fname] = store_fmt[store]
    return fmts, file_fmt, loaded


def git_rev(path: Path) -> str:
    try:
        return subprocess.run(["git", "-C", str(path), "rev-parse", "--short=12", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wowdbdefs", required=True, type=Path)
    ap.add_argument("--core", required=True, type=Path)
    ap.add_argument("--build", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("dbcs", nargs="+")
    a = ap.parse_args()

    target = pv(a.build)
    fmts, file_fmt, loaded = core_formats(a.core)
    defs_rev, core_rev = git_rev(a.wowdbdefs), git_rev(a.core)
    a.out.mkdir(parents=True, exist_ok=True)
    failed = False
    for dbc in a.dbcs:
        fields = parse_dbd(a.wowdbdefs / "definitions" / f"{dbc}.dbd", target)
        if fields is None:
            print(f"{dbc}: no layout for {a.build} in WoWDBDefs", file=sys.stderr)
            failed = True
            continue
        kinds = expand_kinds(fields)
        fmt_name = file_fmt.get(dbc) or next(
            (n for n in (f"{dbc}Entryfmt", f"{dbc}fmt") if n in fmts), None)
        notes = []
        if fmt_name:
            fmt = fmts[fmt_name]
            if len(fmt) != len(kinds):
                print(f"{dbc}: WoWDBDefs has {len(kinds)} fields, core {fmt_name} has {len(fmt)}",
                      file=sys.stderr)
                failed = True
                continue
            # Walk expanded positions back to their field entries.
            pos = 0
            for f in fields:
                t = binding_type(f)
                width = f["count"] * (LOC_FIELDS if t == "locstring" else 1)
                core_kinds = set(fmt[pos:pos + width]) - {"x"}
                if t not in ("locstring", "string") and core_kinds == {"f"} and t != "float":
                    notes.append(f"{f['name']}: core reads float, WoWDBDefs says {t}; using float")
                    f["ctype"] = "float"
                elif t == "float" and core_kinds and core_kinds <= {"i", "n", "d"}:
                    notes.append(f"{f['name']}: core reads int, WoWDBDefs says float; using int32")
                    f["ctype"], f["bits"], f["unsigned"] = "int", 32, False
                elif t != "locstring" and "s" in core_kinds and t != "string":
                    print(f"{dbc}.{f['name']}: core reads a string, WoWDBDefs says {t}", file=sys.stderr)
                    failed = True
                pos += width
            check = f"cross-checked with core {fmt_name} ({len(fmt)} fields)"
        else:
            check = "no core format string; layout from WoWDBDefs only"
        key = [f["name"] for f in fields if f["id"]]
        if not key:
            key = [f["name"] for f in fields if binding_type(f).startswith(("int", "uint"))]
        source = (f"WoWDBDefs {defs_rev} definitions/{dbc}.dbd, build {a.build}; {check}; "
                  f"core twow-core {core_rev}")
        lines = [
            "# Generated by tools/gen_bindings.py - edit only with a comment saying why.",
            f'dbc = "{dbc}"',
            f'build = "{a.build}"',
            f"server_loaded = {'true' if dbc in loaded else 'false'}",
            "key = [" + ", ".join(f'"{k}"' for k in key) + "]",
            f'source = "{source}"',
        ]
        for n in notes:
            lines.append(f"# note: {n}")
        for f in fields:
            lines += ["", "[[field]]", f'name = "{f["name"]}"', f'type = "{binding_type(f)}"']
            if f["count"] > 1:
                lines.append(f"count = {f['count']}")
        (a.out / f"{dbc}.toml").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        print(f"{dbc}: {len(kinds)} fields, key {key}, {check}"
              + (f", {len(notes)} note(s)" if notes else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
