# V4 profession-prefix maintenance gate

`v4-136-profession-prefix.csv` is the immutable, ordered WS-10 roster
checkpoint used by the V4 maintenance gate.  Its SHA-256 is
`51F0559A6914E0D3A4886CD0B21A669C15BCB54A48DC06E948E9BF55AF6AEC39`;
the 800-row master from which the prefix was derived has SHA-256
`4E313D575FBA261986F69562E42976C188D6759CDE5A9515398E8651A9E8F509`.

The gate validates the exact 136 rows, ordinals, unique GUIDs and profession
labels before opening a database transaction.  It maps the labels to the
current core's `ProfessionPair::Pair` values: 1 Herbalism/Alchemy, 2
Skinning/Leatherworking, 3 Mining/Blacksmithing, 4 Mining/Engineering, 5
Mining/Jewelcrafting and 6 Tailoring/Enchanting.  The persisted event contract
comes from `core/modules/mod-playerbots/src/playerbot/ProfessionPair.h`:
`event=profession_pair`, `data=v1`, and `validIn=4294967295`.

This is intentionally not part of `make up`, `db-init.sh`, or the Helm
bootstrap.  After independently verifying the active roster version and with
`realmd` and `mangosd` stopped, an operator may use:

```sh
make roster-v4-apply ROSTER_V4_MAINTENANCE=YES ROSTER_V4_EXPECTED_ROSTER_VERSION=<verified-version-id>
```

The transaction refuses a nonmatching current-roster pointer or prefix, a
non-randombot/player target (proved by the persisted character account name,
not the transient `add` event), invalid existing target events, duplicate/foreign
input GUIDs, invalid values, or a schema-contract mismatch.  It can only insert
or update the `owner=0, event=profession_pair` row keyed to a verified target.
All other event types and GUIDs are outside its SQL write path.  A zero-row
change is reported as `ROSTER_V4_GATE=NOOP`.

Before authorizing an actual run, execute the hermetic source-contract test and
the disposable-DB matrix: canonical apply; second no-op; hash/count/order/
duplicate/foreign-GUID/invalid-pair rejection; a non-target player and another
event type unchanged; talents, quests, inventory and skills unchanged; and a
forced precondition failure proving no partial row is committed.
