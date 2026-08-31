# Post-completion live server smoke result

SMOKE_RESULT=INDETERMINATE

Evidence directory: C:\TW\ComTW\runbooks\post-completion-live-smoke-20260829-000920-697

## User world-entry confirmation

- `CHARACTER_ONLINE` received: yes
- Established world-port connection present in both observations: yes
- No connection addresses, account data, character names, or command lines were captured.

## Completion Note identity

- Path: C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion.md
- Bytes: 12164
- SHA-256: CCEF3FDF2341CA3A814146D70AF5B5F638FB3BC87909D67BB22D9E26B6A0733C

## Runtime observations

Observation interval: 30.951 seconds

| Role | Observation 1 PID | Observation 2 PID | Executable path | Start time UTC | Alive across both |
|---|---:|---:|---|---|---|
| mariaDb | 14776 | 14776 | C:\TW\ComTW\DB\bin\mysqld.exe | 2026-08-28T22:12:37.9655841Z | True |
| mangosd | 9628 | 9628 | C:\TW\ComTW\server\mangosd.exe | 2026-08-28T22:12:48.2884890Z | True |
| realmd | 24080 | 24080 | C:\TW\ComTW\server\realmd.exe | 2026-08-28T22:12:45.2939531Z | True |

| Port | Observation 1 listener PID(s) | Observation 2 listener PID(s) | Established connections O1/O2 |
|---:|---|---|---:|
| 3307 | 14776 | 14776 | 33/33 |
| 3724 | 24080 | 24080 | 0/0 |
| 8090 | 9628 | 9628 | 1/1 |

- Matching running Windows services, observation 1: 0
- Matching running Windows services, observation 2: 0
- Unexpected duplicate process: False
- Unexpected duplicate listener: False

## Appended-log evidence

| Source | Status | Appended bytes | SHA-256 | Fatal | Crash | Assert | Unhandled | DB-connect | Login/world | Warnings |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| anticheat.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| bg.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| bot_events.csv | indeterminate-shorter | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| bot_test_results.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| char.log | appended-range-captured | 4472 | B7A6EFD0F0F9A69F192E61251643C5C0FD733E183A6239E9CE20166301868C07 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| chat.log | appended-range-captured | 507 | F0497ED4BE570C3B8FDE9CABAC5B5E8EA60C4490D94934A471673FAAB82AC380 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| chatspam.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| client.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| crash_20260826_205523.dmp | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| crash_20260826_205523.dmp.txt | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| deaths.csv | indeterminate-shorter | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| errors.log | appended-range-captured | 189748 | 33A58AE560AC9748BC4006C9A47FFADF53DDF1910E4079BE080AF400C48C9348 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| gm_critical.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| gm.log | appended-range-captured | 221 | 84C4A234D6E39625F8E0607458777D21F7781419F66057E7146F3ED96DD46A3F | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| hardcore.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| honor.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| info.log | appended-range-captured | 1601 | 54315E0CE2B65E483CBAFC287F7DA03E16D03343881AC8A4BE4ED06F80271C2F | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| levelup.log | appended-range-captured | 8239 | E814473A47D6941984B51A279891BB9ED25019FC3FA653B37AF1425A75F85F0D | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| loot.log | appended-range-captured | 38547 | B9D415F29BDB7E7FC2C68E64CCA056D324023B660CDFAB6BA64D320206B9FBD2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| perf.log | appended-range-captured | 49 | BDECE10C6DA930DB69BEF8DDCBD523197CB318637F979A9FE451286F2561FD3B | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| racechange.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| raid.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| rareloot.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Realmd.log | indeterminate-replaced-or-modified | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-25_22-47-24.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-26_00-10-53.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-26_18-09-20.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-26_20-55-17.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-27_23-00-06.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-28_18-07-31.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| trades.log | appended-range-captured | 918 | 54C5308DCBA5A96398386A68C2F4206AB11B62694F77E7CC23DA7D44C54FEA34 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| warden.log | unchanged-empty-range | 0 | E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| server_2026-08-29_00-12-48.log | created-after-baseline | 18554273 | A2B3255B5AD6F0FDCF59053811543B00983A5D9FC4F6B01578D2B2602DB9D7FF | 0 | 0 | 0 | 0 | 0 | 0 | 1 |

All marker searches were restricted to newly appended or newly created byte ranges. Historical bytes before baseline offsets were not classified as new findings.

## Findings

- Demonstrated failures: none
- Indeterminate: 3 log range(s) could not be captured reliably.
- Warning: 1 warning marker(s) were found in appended ranges; warnings alone do not fail the smoke test.
- Warning: 1602 generic error marker(s) were found and classified separately from the result-rule fatal categories.

## Ollama and prohibited-operation confirmation

- Ollama process count, observation 1: 1
- Ollama process count, observation 2: 1
- Ollama was not queried, stopped, or modified.
- No launcher, shutdown, SQL, migration, rollback, dump, Honor maintenance, audit, compilation, or historical runbook operation was invoked.
- The running game server was left untouched.
