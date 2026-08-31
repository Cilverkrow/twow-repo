# Character Migration Completion Note

## Disposition

`completed_with_documented_evidence_gaps`

This disposition documents the completed character migration, the preserved recovery evidence, and the runtime corrections made afterward. It is a documentation disposition only. It is not a replacement audit result.

The historical Post-Run audit remains `review_required` and must never be described as `passed`. Its result, its executed migration runbook, and all recovery artifacts remain immutable. No Follow-up audit was created because the offline feasibility gate failed. No rollback trigger was established. The two historical evidence gaps described below cannot be repaired retroactively from the immutable evidence currently available.

## Historical boundary

The executed migration runbook and the historical Post-Run audit describe the identities and runtime conditions that applied when they ran. Current runtime hashes must not be inserted into either historical file or used to rewrite their evidence.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1` | 93,173 | `89C6C934B3CAAB861570BE54092A768ACEDACDD6D58DA731884EBDE06669314A` |
| `C:\TW\ComTW\runbooks\tw-char-migration-post-run-audit-candidate.ps1` | 69,795 | `BC25FC6C0833683DFF3553EEE910B3F67A2F1224F0B8F61AFC1DB1CE3E9AD189` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-recovery-result.json` | 283,441 | `A185DB60B4E76EE51FC138BE1665F9D6E6F1F245AFAFC9208A712AF93F639834` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-recovery-artifacts.sha256` | 662 | `7D25A3288C95E4D75F8C623CD597EC4B59729F15AEBFD5243FBC04E637A38451` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-error-log-snapshot.txt` | 948,759 | `923570252AE730181938F071F5F0EB71C7BE114C48A305DEBB56C65071088294` |

The recovery manifest contains seven entries, and all seven entries were verified against their preserved files. The historical result remains `review_required`.

## Error-log evidence gap

The executed runbook calculated an in-memory pre-start `$errorOffset` before starting the Worldserver. That offset was not persisted as independent evidence. The runbook intended to create `error-log.appended.txt` after controlled Worldserver shutdown, but the controlled shutdown failure occurred before that evidence step.

The later audit therefore possessed only the complete error-log snapshot. It found three older error markers, but it could not independently assign them to or exclude them from the migration run's appended byte range. Timestamps alone cannot replace a persisted byte offset, pre-start file hash, or independently captured byte range.

The historical conclusion is indeterminate. This note does not claim that the markers came from the migration, and it does not claim that the migration produced no new marker.

Future runbooks must correct this evidence gap by:

1. Persisting the pre-start log size, byte offset, and SHA-256 before starting the Worldserver.
2. Capturing the appended byte range even if later shutdown handling fails.
3. Placing the capture in a `finally` path where technically safe.
4. Hashing and manifesting the resulting range independently.

## PvP evidence gap

The immutable before/after evidence establishes:

```text
Before rows:             13,465
After rows:              17,929
Additional GUIDs:         4,464
Missing existing GUIDs:       0
Changed existing GUIDs:       0
Additional GUID range:   13,466–17,929
```

The server-free inspection of the immutable pre-migration dump additionally establishes:

```text
Characters in pre-migration dump:               4,501
Pre-existing PvP GUIDs:                         13,465
Pre-migration characters with an existing row:  4,501
Additional PvP GUIDs present as old characters:     0
```

The 4,464 additional GUIDs were not character GUIDs in the pre-migration dump. The schema migration created the table definition but did not explain or populate these rows. `HonorMgr.cpp` demonstrates a possible per-character materialization mechanism through persistence of PvP currency state, but it does not establish the timing, cause, or population membership of these exact 4,464 rows.

The additional rows must not be equated with approximately 50 active bots. No time-aligned, immutable Post-Run character or Bot-population snapshot exists. Current Bot-discovery data can provide later context but cannot retroactively prove historical population membership.

The absence of missing existing GUIDs and the absence of changed existing GUIDs are positive, bounded findings. They do not convert the overall historical audit to `passed`.

The PvP evidence used for this assessment is bound as follows:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\evidence\tw_char.pre-migration.sql` | 66,426,372 | `97E509C87B40CE44DCA0D0EF11CC665A4329DBF9070DAFD902EB952B22BADE22` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-pvp-before.tsv` | 244,778 | `DBDBB90754CF4C446DA217ABD0EC7649044BEA069BE238F0B67D2340B7F924C4` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-pvp-after.tsv` | 329,594 | `0807E577AFBA301D537D62D2573B5A5961325A2AE78B62777F96C6E2582E8DB2` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\post-run-recovery\post-run-pvp-differences.tsv` | 178,711 | `8418986B984DD5217C571C36D5C62061CC71EA6C7C8FF85C1950539177DD23A5` |
| `E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920\migration-files\20260817151028_character.sql` | 437 | `916F19DA19C54C04A094FD12D2D7D20CB40786DBFDA40BD8115B590FEE3A49D5` |
| `C:\TW\ComTW\source\src\game\HonorMgr.cpp` | 33,749 | `8AD43B421A9D28B729771AB3EB4C34C3720456B4452D58C258731E7CE2299EE9` |

## Later Bot-Personality discovery

The subsequent read-only Bot-Personality discovery package and its complete local package were verified successfully.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip` | 84,494 | `8287DAF2124B08863A43FE2A4C03EAB2FFA8FFD7DCC64A527ADA1D928BBEA290` |
| `C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032\sha256-manifest.txt` | 2,406 | `C6598760C34F0A7F680B184B326287239F42F383EE5130FF3F0C1871A564C64E` |
| `C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032\package-entry-list.txt` | 776 | `18299221663FFDD55B7977967CAD3FDBC780710B8797DAAF37602057389201B8` |

The later current-state context contains:

- 4,500 RNDBOT stock characters.
- 100 `active_random_rotation` characters.
- 4,400 `inactive_random_reserve` characters.
- Zero configured player-owned always-online bots.
- Zero active runtime bots because the Worldserver was stopped.

Independent review of all 4,500 exported Bot rows establishes:

```text
Current RNDBOT GUID minimum:       17,930
Current RNDBOT GUID maximum:       22,429
Current RNDBOT GUID count:          4,500
Current RNDBOT GUID gaps:               0
Historical additional PvP range: 13,466–17,929
Intersection count:                     0
```

The later current RNDBOT GUID set is disjoint from the historical set of 4,464 additional PvP GUIDs. It therefore does not identify that historical set as the current RNDBOT population. The adjacency of the ranges establishes no cause, ownership, deletion, recreation, or migration sequence. The historical origin and population membership remain unresolved and `review_required`.

## Runtime corrections completed after the historical run

### Shutdown helper

| State | Path | Bytes | SHA-256 |
|---|---|---:|---|
| Archived predecessor | `C:\TW\ComTW\runbooks\runtime-file-archive-20260828\shutdown-tortoise-servers-gracefully-6582740F.ps1` | 13,052 | `6582740F7D452EB74ABA368CB70EB33F1683B5511E0169AA0CB98056A2E79884` |
| Current production | `C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully.ps1` | 17,047 | `76D899BE55BAE77E72CCD5DF6C5CBD8203986524E944C3AEE7B8C2DD7862EA1A` |

The current helper was proven through controlled command-delivery and shutdown testing before production materialization.

### World launcher

| State | Path | Bytes | SHA-256 |
|---|---|---:|---|
| Archived predecessor | `C:\TW\ComTW\runbooks\runtime-file-archive-20260828\start-mangosd-131A0141.bat` | 37 | `131A0141358D660BAD04AD540BDC170C7CD1B1A99C8AE6AC308EE165B3E6719E` |
| Current production | `C:\TW\ComTW\server\start-mangosd.bat` | 54 | `0C9A97A7E528F0A4451AA9CD0637C3246271CBAACD09DFB8895AFCB3C57B82AF` |

### Compile generator

| State | Path | Bytes | SHA-256 |
|---|---|---:|---|
| Archived predecessor | `C:\TW\ComTW\runbooks\compile-script-archive-20260828\compile-tortoise-wow-1C9C9149.ps1` | 29,407 | `1C9C914950E153FEEF773D319114FDBB69E27EDB4FF72557963B3F1D5C732FBD` |
| Current active script | `C:\TW\ComTW\compile-tortoise-wow.ps1` | 29,480 | `80D4D4607AF05048D14487AAD335C56ED2857D3F984D7F133A41F25D66706ECC` |

The active compile workflow now regenerates the approved 54-byte launcher deterministically and cannot silently restore the obsolete launcher form.

## Current approved runtime identities

These are the current 11 runtime identities. They are operational identities only and must not be inserted into or used to rewrite the historical `89C6C934` runbook.

| Runtime role | Path | Bytes | SHA-256 |
|---|---|---:|---|
| Production helper | `C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully.ps1` | 17,047 | `76D899BE55BAE77E72CCD5DF6C5CBD8203986524E944C3AEE7B8C2DD7862EA1A` |
| Production launcher | `C:\TW\ComTW\server\start-mangosd.bat` | 54 | `0C9A97A7E528F0A4451AA9CD0637C3246271CBAACD09DFB8895AFCB3C57B82AF` |
| Database launcher | `C:\TW\ComTW\DB\start-database.bat` | 102 | `C0EEC81CE8797DDE77685D5639E90AD36892EE473CAD01F8558B6A8C6237336A` |
| Database configuration | `C:\TW\ComTW\DB\data\my.ini` | 109 | `7039B21A8D50E85511EDF7D5BC2ECD501830AD151D9EF0331243B43ADA4BA9B8` |
| MariaDB server | `C:\TW\ComTW\DB\bin\mysqld.exe` | 13,312 | `FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7` |
| MariaDB client | `C:\TW\ComTW\DB\bin\mariadb.exe` | 4,802,560 | `9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95` |
| MariaDB dump client | `C:\TW\ComTW\DB\bin\mariadb-dump.exe` | 4,805,632 | `FD6E467EAA49F166E355A5660952E2488ABB2BE80CB90B2DB229DF7253D24EDB` |
| MariaDB administration client | `C:\TW\ComTW\DB\bin\mariadb-admin.exe` | 1,010,688 | `1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E` |
| Worldserver executable | `C:\TW\ComTW\server\mangosd.exe` | 20,376,576 | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` |
| Worldserver configuration | `C:\TW\ComTW\server\mangosd.conf` | 69,547 | `2078618151892E41FE5059C22030D25A6E34042E02A457CB3E8E7C42399BB144` |
| PlayerBot configuration | `C:\TW\ComTW\server\aiplayerbot.conf` | 283,706 | `757D560F87F2280DF8637B0F2CF8FA12C51286DD5451E9C5935AC6A7CC8502D1` |

## Operational conclusion

- The completed migration and recovery artifacts remain preserved.
- Current runtime corrections are materialized and byte-verified.
- No established finding requires rollback.
- Two historical provenance questions remain documented.
- Those questions are evidence-completeness limitations, not proof of a current server failure.
- The server remains independently startable without Ollama.
- No LLM bridge or Ollama dependency is currently installed as a required runtime component.
- Any later LLM integration must remain optional and fail safely.

The historical `89C6C934` runbook must never be executed again. Any future operational run requires a newly identified runbook containing the current runtime hashes and corrected evidence capture.

This note preserves the historical audit status and does not claim that either evidence gap has been resolved.
