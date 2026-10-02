"""Command line: ``python -m clientinventory <archives|maps|dbdiff|wdb> ...``.

Everything is read-only. Client files are opened for reading only, database
data comes from TSV exports (``mariadb -B``), results go to ``--out`` (keep it
outside Git: it names content of the client).
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from . import archives, dbdiff, maps, wdb
from .common import load_typed, read_tsv, write_tsv


def cmd_archives(a) -> int:
    lists = archives.load_listings(a.lists)
    rows = archives.archive_facts(a.client / "Data", lists)
    write_tsv(a.out / "archives.tsv", ["archive", "bytes", "files_in_block_table", "names_listed", "unlisted", "hash_slots", "top_types"], rows)
    chain = archives.override_chains(lists)
    multi = {n: c for n, c in chain.items() if len(c) > 1}
    # DBC files by the archives that carry them (who overrides whom)
    dbc_rows = sorted((n.split("\\")[-1], " > ".join(c)) for n, c in chain.items() if n.startswith("dbfilesclient\\"))
    write_tsv(a.out / "dbc-chains.tsv", ["dbc", "archives_in_load_order"], dbc_rows)
    by_final = Counter(c[-1] for c in multi.values())
    write_tsv(a.out / "overrides-by-winner.tsv", ["winning_archive", "files_that_override_an_earlier_archive"], sorted(by_final.items()))
    total = len(chain)
    print(f"{len(lists)} archives, {total} distinct names, {len(multi)} names in more than one archive")
    return 0


def cmd_maps(a) -> int:
    lists = archives.load_listings(a.lists)
    eff = archives.effective_map_files(a.client / "Data", lists)
    cmaps = maps.client_maps(lists, eff)
    emptied = sorted(n for n, (arch, size) in eff.items() if size == 0 and n.endswith(".adt"))
    write_tsv(a.out / "tiles-emptied-by-patch.tsv", ["adt_emptied_to_0_bytes"], ([n] for n in emptied))
    map_dbc = load_typed(a.dbc, "Map")
    tpl = read_tsv(a.db / "map_template.tsv")
    stiles = maps.server_tiles(a.server_data)
    rows = maps.inventory(map_dbc, tpl, cmaps, stiles)
    cols = list(rows[0])
    write_tsv(a.out / "maps.tsv", cols, ([r[c] for c in cols] for r in rows))
    write_tsv(a.out / "tiles-diff.tsv", ["map_id", "directory", "side", "x", "y", "client_archives", "client_file_bytes"], maps.tile_diffs(map_dbc, cmaps, stiles, eff))
    map_dirs = {r["ID"]: (r["Directory"] or "") for r in map_dbc}
    spawn_out = []
    for table in ("creature", "gameobject"):
        f = a.db / f"spawn_tiles_{table}.tsv"
        if f.is_file():
            spawn_out += maps.spawns_without_terrain(cmaps, read_tsv(f), map_dirs, table)
    write_tsv(a.out / "spawns-without-client-terrain.tsv", ["table", "map_id", "directory", "tile_x", "tile_y", "spawns"], spawn_out)
    content = maps.content_by_map(map_dbc, tpl, read_tsv(a.db / "creature_spawn_maps.tsv"), read_tsv(a.db / "gameobject_spawn_maps.tsv"),
                                  read_tsv(a.db / "areatrigger_teleport.tsv"), read_tsv(a.db / "game_tele.tsv"), rows)
    ccols = list(content[0])
    write_tsv(a.out / "map-content.tsv", ccols, ([r[c] for c in ccols] for r in content))
    flags = Counter()
    for r in rows:
        if r["dbc"] and not r["template"]:
            flags["in Map.dbc, no map_template"] += 1
        if r["template"] and not r["dbc"]:
            flags["map_template without Map.dbc"] += 1
        if r["dbc"] and r["wdt"] and not (r["server_maps"] or r["server_vmaps"]):
            flags["client has a WDT, server has no map data"] += 1
    print(f"{len(rows)} maps; " + "; ".join(f"{k}: {v}" for k, v in sorted(flags.items())))
    return 0


def cmd_dbdiff(a) -> int:
    out = a.out / "dbdiff"
    summary = []
    for spec in dbdiff.SPECS:
        r = dbdiff.run_spec(spec, a.dbc, a.db)
        write_tsv(out / f"{spec.name}-only-in-dbc.tsv", ["key", "name"], ([k, r.dbc_by_key[k].get(spec.name_dbc, "") if spec.name_dbc else ""] for k in r.only_dbc))
        write_tsv(out / f"{spec.name}-only-in-db.tsv", ["key", "name"], ([k, r.db_by_key[k].get(spec.name_db, "") if spec.name_db else ""] for k in r.only_db))
        by_key: dict = {}
        for lbl, v in r.diffs.items():
            for k, x, y in v:
                by_key.setdefault(k, []).append(f"{lbl}: dbc={x} db={y}")
        write_tsv(out / f"{spec.name}-diff-by-key.tsv", ["key", "name", "differences"], ([k, (r.db_by_key[k].get(spec.name_db, "") if spec.name_db else ""), "; ".join(d)] for k, d in sorted(by_key.items())))
        write_tsv(out / f"{spec.name}-diff-columns.tsv", ["column", "rows_that_differ"], ((lbl, len(v)) for lbl, v in r.diffs.items()))
        samples = [[lbl, k, x, y] for lbl, v in r.diffs.items() for k, x, y in v[:30]]
        write_tsv(out / f"{spec.name}-diff-samples.tsv", ["column", "key", "dbc", "db"], samples)
        worst = sorted(((len(v), lbl) for lbl, v in r.diffs.items() if v), reverse=True)[:5]
        summary.append([spec.name, spec.dbc_name, spec.table, r.dbc_rows, r.db_rows, r.both, len(r.only_dbc), len(r.only_db),
                        sum(len(v) for v in r.diffs.values()), " ".join(f"{l}:{n}" for n, l in worst)])
    write_tsv(out / "summary.tsv", ["spec", "dbc", "table", "dbc_rows", "table_rows", "in_both", "only_in_dbc", "only_in_table", "differing_cells", "worst_columns"], summary)
    ref_rows = []
    for label, known, missing in dbdiff.references(a.dbc, a.db):
        ref_rows.append([label, known, len(missing), sum(len(v) for v in missing.values())])
        write_tsv(out / ("ref-" + label.split(" ")[0].replace(".", "_") + ".tsv"), ["missing_id", "used_by"], ([k, " ".join(map(str, v[:10]))] for k, v in sorted(missing.items())))
    write_tsv(out / "references.tsv", ["reference", "ids_in_dbc", "missing_ids", "rows_using_missing_ids"], ref_rows)
    for row in summary:
        print("	".join(map(str, row)))
    return 0


def cmd_wdb(a) -> int:
    out = a.out / "wdb"
    plan = [("creaturecache", "creature_template", "name", "name"), ("itemcache", "item_template", "name", "name"),
            ("gameobjectcache", "gameobject_template", "name", "name"), ("questcache", "quest_template", "Title", "title")]
    summary = []
    for cache, table, db_name, cache_name in plan:
        hdr, count, rows = wdb.load(a.client / "WDB" / f"{cache}.wdb")
        db = {int(r["entry"]): r for r in read_tsv(a.db / f"{table}.tsv")}
        missing, differs = [], []
        for r in rows:
            d = db.get(r["entry"])
            if d is None:
                missing.append(r)
            elif (r.get(cache_name) or "").strip().lower() != (d.get(db_name) or "").strip().lower():
                differs.append([r["entry"], r.get(cache_name), d.get(db_name)])
        cols = [c for c in (missing[0] if missing else rows[0] if rows else {"entry": 0})]
        write_tsv(out / f"{cache}-not-in-db.tsv", cols, ([m.get(c) for c in cols] for m in missing))
        write_tsv(out / f"{cache}-name-differs.tsv", ["entry", "cache", "db"], differs)
        summary.append([cache, hdr.build, hdr.locale, count, len(rows) - len(missing), len(missing), len(differs)])
    write_tsv(out / "summary.tsv", ["cache", "build", "locale", "records", "in_db", "not_in_db", "name_differs"], summary)
    for row in summary:
        print("	".join(map(str, row)))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="clientinventory", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("archives", cmd_archives), ("maps", cmd_maps)):
        p = sub.add_parser(name)
        p.add_argument("--client", type=Path, required=True, help="client folder (contains Data/)")
        p.add_argument("--lists", type=Path, required=True, help="folder with the mpqcli listings")
        p.add_argument("--out", type=Path, required=True)
        if name == "maps":
            p.add_argument("--dbc", type=Path, required=True, help="folder with the client's effective DBCs")
            p.add_argument("--db", type=Path, required=True, help="folder with the database TSV exports")
            p.add_argument("--server-data", type=Path, required=True, help="server data folder (maps, vmaps, mmaps)")
        p.set_defaults(fn=fn)
    p = sub.add_parser("dbdiff")
    p.add_argument("--dbc", type=Path, required=True, help="folder with the client's effective DBCs")
    p.add_argument("--db", type=Path, required=True, help="folder with the database TSV exports")
    p.add_argument("--out", type=Path, required=True)
    p.set_defaults(fn=cmd_dbdiff)
    p = sub.add_parser("wdb")
    p.add_argument("--client", type=Path, required=True)
    p.add_argument("--db", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.set_defaults(fn=cmd_wdb)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
