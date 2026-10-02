"""Map inventory: Map.dbc, the client's WDT/ADT files, map_template and the server map data.

Client tiles come from the archive listings (the listings are complete: block
count = listed names + (listfile) + (attributes)). Server tiles come from the
file names in ``maps/``, ``vmaps/`` and ``mmaps/`` of the server data folder.
Nothing is opened except the names of these files.
"""

from __future__ import annotations

import re
from pathlib import Path

_ADT = re.compile(r"^world\\maps\\([^\\]+)\\([^\\]+)_(\d+)_(\d+)\.adt$", re.IGNORECASE)
_WDT = re.compile(r"^world\\maps\\([^\\]+)\\([^\\]+)\.wdt$", re.IGNORECASE)


def client_maps(listings: dict[str, list[str]], effective: dict | None = None):
    """directory (lower case) -> {'wdt': [archives], 'tiles': {(x, y): [archives]}}.

    With ``effective`` (name -> (archive, size), from archives.effective_map_files) a tile counts only when the
    winning archive holds a non-empty file; a patch that overwrote it with 0 bytes removed it.
    """
    out: dict[str, dict] = {}
    for arch, names in listings.items():
        for n in names:
            m = _ADT.match(n)
            if m:
                if effective is not None and effective.get(n.lower(), ("", 1))[1] == 0:
                    continue
                d = out.setdefault(m.group(1).lower(), {"wdt": [], "tiles": {}})
                d["tiles"].setdefault((int(m.group(3)), int(m.group(4))), []).append(arch)
                continue
            m = _WDT.match(n)
            if m and m.group(1).lower() == m.group(2).lower():
                out.setdefault(m.group(1).lower(), {"wdt": [], "tiles": {}})["wdt"].append(arch)
    return out


def server_tiles(data_dir: Path):
    """Server map data by map id: {'maps': {(a, b)}, 'vmaps': {(a, b)}, 'mmaps': {(a, b)}, 'vmtree': bool, 'mmap': bool}."""
    res: dict[int, dict] = {}

    def slot(mid):
        return res.setdefault(mid, {"maps": set(), "vmaps": set(), "mmaps": set(), "vmtree": False, "mmap": False})

    for p in (data_dir / "maps").glob("*.map"):
        s = p.stem
        if re.fullmatch(r"\d{7}", s):
            slot(int(s[:3]))["maps"].add((int(s[3:5]), int(s[5:7])))
    for p in (data_dir / "vmaps").iterdir():
        s = p.name.lower()
        m = re.fullmatch(r"(\d{3})_(\d{2})_(\d{2})\.vmtile", s)
        if m:
            slot(int(m.group(1)))["vmaps"].add((int(m.group(2)), int(m.group(3))))
        elif re.fullmatch(r"\d{3}\.vmtree", s):
            slot(int(s[:3]))["vmtree"] = True
    for p in (data_dir / "mmaps").iterdir():
        s = p.name.lower()
        if re.fullmatch(r"\d{7}\.mmtile", s):
            slot(int(s[:3]))["mmaps"].add((int(s[3:5]), int(s[5:7])))
        elif re.fullmatch(r"\d{3}\.mmap", s):
            slot(int(s[:3]))["mmap"] = True
    return res


def best_orientation(client: set, server: set):
    """The server names tiles (a, b); the client names them (x, y). Decide by overlap whether a = x or a = y."""
    straight = len(client & server)
    swapped = len({(y, x) for x, y in client} & server)
    return ("same", straight) if straight >= swapped else ("swapped", swapped)


def inventory(map_dbc: list[dict], map_template: list[dict], cmaps: dict, stiles: dict):
    """One row per map id (union of Map.dbc, map_template and server files)."""
    dbc = {r["ID"]: r for r in map_dbc}
    tpl = {int(r["entry"]): r for r in map_template}
    ids = sorted(set(dbc) | set(tpl) | set(stiles))
    rows = []
    for mid in ids:
        d = dbc.get(mid)
        t = tpl.get(mid)
        directory = (d["Directory"] if d else "") or ""
        c = cmaps.get(directory.lower(), {"wdt": [], "tiles": {}})
        ctiles = set(c["tiles"])
        s = stiles.get(mid, {"maps": set(), "vmaps": set(), "mmaps": set(), "vmtree": False, "mmap": False})
        orient, overlap = best_orientation(ctiles, s["maps"]) if ctiles and s["maps"] else ("-", 0)
        sm = s["maps"] if orient != "swapped" else {(b, a) for a, b in s["maps"]}
        rows.append({
            "id": mid, "dbc": bool(d), "directory": directory, "name": (d or {}).get("MapName_lang_enUS") if d else "",
            "instance_type": (d or {}).get("InstanceType") if d else "",
            "template": bool(t), "template_name": (t or {}).get("map_name", ""), "template_type": (t or {}).get("map_type", ""),
            "wdt": bool(c["wdt"]), "client_tiles": len(ctiles),
            "server_maps": len(s["maps"]), "server_vmaps": len(s["vmaps"]), "server_vmtree": s["vmtree"],
            "server_mmaps": len(s["mmaps"]), "server_mmap": s["mmap"],
            "overlap": overlap, "orientation": orient,
            "client_only_tiles": len(ctiles - sm) if s["maps"] else len(ctiles),
            "server_only_tiles": len(sm - ctiles) if ctiles else len(s["maps"]),
        })
    return rows


def tile_diffs(map_dbc: list[dict], cmaps: dict, stiles: dict, eff: dict | None = None):
    """Rows (map id, directory, side, x, y, archives) for tiles only the client or only the server has.

    Coordinates are the client's (x, y); server tiles are turned around when the overlap says the
    server names them the other way. Tiles of maps the server has no ``.map`` file for at all are
    listed as client-only; they are the "whole map missing" case, counted per map in maps.tsv.
    """
    rows = []
    for r in map_dbc:
        mid, directory = r["ID"], (r["Directory"] or "")
        c = cmaps.get(directory.lower(), {"tiles": {}})
        ctiles = c["tiles"]
        s = stiles.get(mid, {"maps": set()})
        orient, _ = best_orientation(set(ctiles), s["maps"]) if ctiles and s["maps"] else ("-", 0)
        sm = s["maps"] if orient != "swapped" else {(b, a) for a, b in s["maps"]}
        for t in sorted(set(ctiles) - sm):
            name = "world" + chr(92) + "maps" + chr(92) + directory.lower() + chr(92) + f"{directory.lower()}_{t[0]}_{t[1]}.adt"
            size = (eff or {}).get(name, ("", ""))[1]
            rows.append([mid, directory, "client-only", t[0], t[1], " ".join(ctiles[t]), size])
        for t in sorted(sm - set(ctiles)):
            rows.append([mid, directory, "server-only", t[0], t[1], "", ""])
    return rows


def content_by_map(map_dbc, map_template, spawn_c, spawn_g, teleports, game_tele, inv_rows):
    """Per map: how much server content points at it (spawns, teleport targets) against what the client has.

    ``inv_rows`` are the rows of :func:`inventory`. The interesting cases are maps the server fills
    with content but the client's Map.dbc does not know (nobody can enter them with this client) and
    maps the client has whose server side is empty.
    """
    def by_map(rows, key, weight=None):
        out: dict[int, int] = {}
        for r in rows:
            try:
                m = int(r[key])
            except (TypeError, ValueError):
                continue
            out[m] = out.get(m, 0) + (int(r[weight]) if weight else 1)
        return out

    c = by_map(spawn_c, "map", "spawns")
    g = by_map(spawn_g, "map", "spawns")
    tp = by_map(teleports, "target_map")
    gt = by_map(game_tele, "map")
    rows = []
    for r in inv_rows:
        mid = r["id"]
        rows.append({
            "id": mid, "directory": r["directory"], "name": r["name"] or r["template_name"], "in_map_dbc": r["dbc"], "in_map_template": r["template"],
            "creature_spawns": c.get(mid, 0), "gameobject_spawns": g.get(mid, 0), "areatrigger_entrances": tp.get(mid, 0), "game_tele_rows": gt.get(mid, 0),
            "client_wdt": r["wdt"], "client_tiles": r["client_tiles"], "server_map_files": r["server_maps"], "server_vmap_tiles": r["server_vmaps"],
            "server_mmap_tiles": r["server_mmaps"],
        })
    for mid in sorted((set(c) | set(g) | set(tp) | set(gt)) - {r["id"] for r in inv_rows}):
        rows.append({"id": mid, "directory": "", "name": "", "in_map_dbc": False, "in_map_template": False, "creature_spawns": c.get(mid, 0),
                     "gameobject_spawns": g.get(mid, 0), "areatrigger_entrances": tp.get(mid, 0), "game_tele_rows": gt.get(mid, 0),
                     "client_wdt": False, "client_tiles": 0, "server_map_files": 0, "server_vmap_tiles": 0, "server_mmap_tiles": 0})
    return rows


def spawns_without_terrain(cmaps: dict, spawn_rows: list[dict], map_dirs: dict[int, str], table: str):
    """Server spawns whose tile has no non-empty ADT in the client.

    ``spawn_rows`` come from ``SELECT map, FLOOR(32 - position_y/533.33333) AS tx_from_y,
    FLOOR(32 - position_x/533.33333) AS ty_from_x, COUNT(*) AS n FROM <table> GROUP BY ...``. The client
    names a tile (x, y) with x from the world Y axis and y from the world X axis (checked against the spawns).
    """
    out = []
    for r in spawn_rows:
        mid = int(r["map"])
        directory = map_dirs.get(mid)
        if not directory:
            continue
        tile = (int(r["tx_from_y"]), int(r["ty_from_x"]))
        if tile not in cmaps.get(directory.lower(), {"tiles": {}})["tiles"]:
            out.append([table, mid, directory, tile[0], tile[1], int(r["n"])])
    return sorted(out, key=lambda x: (x[0], x[1], -x[5]))
