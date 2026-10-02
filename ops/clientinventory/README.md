# clientinventory: game client against server data (read-only)

Tool for #455 under the tool principle of #409. It answers one question:
**what does the game client know that the server does not, and the other way round?**

Python 3.11+ **standard library only**; it reads DBC files through the bindings of
`ops/clientpatch`.

## Rules

- **Read-only.** Client folders and server data are opened for reading; the tool writes only
  into the `--out` folder. Mount the client with `:ro` when you run it in a container.
- **No client content in Git.** Outputs (lists of ids, counts, file names, tile coordinates)
  belong in an evidence folder outside the repository. Only this tool and its tests are committed.
- **No database access of its own.** It reads TSV exports (`mariadb -B`) that you made from a
  **disposable** database; never point a scan at the live database.

## Commands

All commands take `--out <folder>`; the example paths are the folders mounted in a container.

| Command | Reads | Writes (below `--out`) |
|---|---|---|
| `archives --client C --lists L` | the MPQ hash/block tables of `C/Data` and the `mpqcli list` listings in `L` | `archives.tsv` (size, blocks, listed names, completeness), `dbc-chains.tsv`, `overrides-by-winner.tsv` |
| `maps --client C --lists L --dbc D --db X --server-data S` | listings, `Map.dbc`, exports of `map_template` and the spawn maps, the server `maps/vmaps/mmaps` file names | `maps.tsv`, `tiles-diff.tsv`, `tiles-emptied-by-patch.tsv`, `map-content.tsv`, `spawns-without-client-terrain.tsv` |
| `dbdiff --dbc D --db X` | the client's effective DBCs and the table exports | `dbdiff/<area>-only-in-dbc.tsv`, `-only-in-db.tsv`, `-diff-columns.tsv`, `-diff-samples.tsv`, `-diff-by-key.tsv`, `summary.tsv`, `references.tsv` |
| `wdb --client C --db X` | `C/WDB/*.wdb` caches (build 5875) | `wdb/summary.tsv`, `<cache>-not-in-db.tsv`, `<cache>-name-differs.tsv` |

Areas of `dbdiff`: Map, AreaTrigger, Spell, SkillLineAbility, AreaTable, Faction, FactionTemplate,
ItemDisplayInfo (add more in `clientinventory/dbdiff.py`, `SPECS`). `references.tsv` lists display
ids that creature, item and game object templates use but the client's DBCs do not know.

## Method notes (each one cost a wrong first answer)

- **Effective file = last archive in load order.** A patch can overwrite a file with 0 bytes; that
  removes it for the client. `maps` counts such tiles in `tiles-emptied-by-patch.tsv`, not as present.
- **Listings can be incomplete**, so `archives.tsv` compares the block count with the listed names
  (block count = names + `(listfile)` + `(attributes)`); `mpqmini` answers "is name X in this archive"
  from the hash table alone and decompresses nothing.
- **Tile naming.** The client names a tile `Map_x_y.adt` with x from the world Y axis; the server
  names `MMMXXYY.map` with the two axes the other way round. `best_orientation` decides by overlap.
- **int32 vs uint32.** DBC and table disagree on the sign of the same 32 bits; values are compared
  as `& 0xFFFFFFFF`.
- **Spell ids above 65535** are truncated to 16 bit by the 1.12 client in several packets
  (`SMSG_INITIAL_SPELLS`, removed/superseded spell); check any id set you plan to add.

## Tests

```
cd ops/clientinventory
python3 -m unittest discover -s tests -v
```

The tests use a tiny synthetic MPQ, WDBC and WDB written on the fly (`tests/synth.py`); they need no
game files. CI runs them in the `clientinventory` job.
