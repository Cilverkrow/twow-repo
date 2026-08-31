# Lokale TWoW-Projektstruktur – Abschlussrevision R1

Erfasst: 2026-08-30T16:23:49Z  
Task: `PROJECT-STRUCTURE-LOCAL-INVENTORY-01-R1-CLOSURE`  
Projektseite: `LOCAL`  
Revisionstyp: Statuskorrektur ohne erneute Inventarisierung

## Abschlussstatus

```text
RESULT=PASS
STRUCTURE_INVENTORY_COMPLETE=YES
CONTENT_SNAPSHOT_STATUS=PARTIAL
LOCAL_CHAT_COUNT=6
CANONICAL_TITLE_MATCH_COUNT=5
RENAME_PROPOSAL_COUNT=1
MISSING_CANONICAL_WORKSTREAM_COUNT=3
UNRESOLVED_STRUCTURE_COUNT=0
CONTENT_FRESHNESS_LIMITATION_COUNT=4
NEXT_PHASE_DECISION_COUNT=3
CHAT_MUTATIONS_PERFORMED=0
PROJECT_FILE_MUTATIONS_PERFORMED=0
NEXT_TASK_AUTHORIZED=NO
```

Die Strukturaufnahme ist vollständig abgeschlossen. Die vier bisherigen Einschränkungen betreffen ausschließlich die Aktualität beziehungsweise Sichtbarkeit einzelner Chatinhalte. Sie sind keine offenen Struktur-, Identitäts- oder Eigentumsfragen.

## Unveränderliche V1-Quelle

Die folgenden Dateien wurden vor Erstellung dieser Revision byte- und hashgenau geprüft und nicht verändert:

| Datei | Bytes | SHA-256 |
|---|---:|---|
| `local-project-structure-inventory-v1.md` | 15.306 | `6FC8AFACF3A2BECCA1C9B345BD404C49E89A42B3BFC56219CC24DCA2DF9244EA` |
| `local-project-structure-inventory-v1.json` | 13.790 | `6016EDD91223B9B2508F7E2CC17846FEFCDF42EC6914A78656796E1C1D4AA340` |
| `local-project-structure-handoff-v1.md` | 4.175 | `C3F123C54A1FCA54DF053158E9D080E2A941C11455F05F414F184DF8F18E4C60` |
| `sha256-manifest.txt` | 1.327 | `67BEE8F1ADFCBD7564800E4A09333F693D02F64C4DDA5D6FA66DA3D515F7047B` |

Quellverzeichnis: `C:\TW\ComTW\runbooks\project-structure-local-inventory-20260830T161124Z`

## Unverändert übernommene Struktur

### Chatzuordnung

| Aktueller lokaler Chat | Workstream | Kanonischer Titel | Einstufung |
|---|---|---|---|
| `Analysiere TWoW-Projektstruktur` | WS-00 | `Projektsteuerung und Workspace` | Umbenennung vorgeschlagen |
| `SSC – Analyse und Entwicklung` | WS-10 | `SSC – Analyse und Entwicklung` | Exakter Treffer |
| `Datenbank und Migrationen` | WS-20 | `Datenbank und Migrationen` | Exakter Treffer |
| `Deployment und Skripte` | WS-40 | `Deployment und Skripte` | Exakter Treffer |
| `Build und Serverbetrieb` | WS-50 | `Build und Serverbetrieb` | Exakter Treffer |
| `Referenzserver und Backups` | WS-60 | `Referenzserver und Backups` | Exakter Treffer |

Fehlende kanonische lokale Workstreams bleiben exakt:

1. WS-30 `Serverkonfiguration`
2. WS-70 `Bot-Persönlichkeiten`
3. WS-80 `Dokumentation und Entscheidungen`

### Runbook-Eigentum und Zählwerte

Die 41 bestehenden Runbook-Verzeichnisse und 43 Dateien auf Runbook-Oberseite behalten ihre V1-Eigentümer:

| Workstream | Verzeichnisse | Oberste Dateien | Eigentumsbereich |
|---|---:|---:|---|
| WS-00 | 0 | 0 | Projektkarte, Routing, Governance und Übergaben |
| WS-10 | 19 | 13 | SSC, PlayerBot, Source-Baselines und technische LLM-Brücke |
| WS-20 | 14 | 19 | Datenbank, Migrationen, ACL, Trainer, Berufe/Reiten und Spendenpunkte |
| WS-30 | 0 | 0 | Künftige sanitisierte Konfigurations-, Port- und Pfadevidenz |
| WS-40 | 4 | 3 | Skripte, Launcher, Archive und Hilfsprogramme |
| WS-50 | 2 | 3 | Buildausführung, Dienste und Live-Smoke-Evidenz |
| WS-60 | 0 | 0 | Künftige langfristige, historische und Referenzserver-Sicherungen |
| WS-70 | 2 | 5 | Bot-Persönlichkeiten und Kontextvertrag |
| WS-80 | 0 | 0 | Künftige projektweite Entscheidungen, ADRs und Indizes |
| **Summe** | **41** | **43** | |

Migrationslokale Sicherungen bleiben WS-20 zugeordnet. Historische und langfristige Sicherungen gehören künftig WS-60. Die beiden `_superseded-phase1b-package-build-*`-Gruppen bleiben historische WS-10-Evidenz.

### Neun unveränderte Dateisystem-Mapping-Vorschläge

Diese Pfade bleiben reine Vorschläge; sie wurden nicht angelegt:

1. `C:\TW\ComTW\runbooks\workstreams\WS-00-projectsteuerung-workspace`
2. `C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung`
3. `C:\TW\ComTW\runbooks\workstreams\WS-20-datenbank-migrationen`
4. `C:\TW\ComTW\runbooks\workstreams\WS-30-serverkonfiguration`
5. `C:\TW\ComTW\runbooks\workstreams\WS-40-deployment-skripte`
6. `C:\TW\ComTW\runbooks\workstreams\WS-50-build-serverbetrieb`
7. `C:\TW\ComTW\runbooks\workstreams\WS-60-referenzserver-backups`
8. `C:\TW\ComTW\runbooks\workstreams\WS-70-bot-persoenlichkeiten`
9. `C:\TW\ComTW\runbooks\workstreams\WS-80-dokumentation-entscheidungen`

### Unveränderte Überschneidungsregeln

1. WS-40 entwickelt und versioniert Skripte; WS-50 besitzt Ausführungs-, Dienst- und Live-Smoke-Evidenz.
2. WS-20 besitzt migrationslokale Rücksicherung; WS-60 besitzt langfristige, historische und referenzserverbezogene Backups.
3. WS-10 besitzt technische LLM-/PlayerBot-Brücke und Kontexttransport; WS-70 besitzt Persona-Inhalt, Verhalten und Dialogregeln.
4. Fachdokumentation bleibt beim jeweiligen Fachbereich; WS-80 besitzt nur projektweite Entscheidungen, ADRs und Indizes.
5. WS-30 besitzt Konfigurationswerte, Ports und Pfade; WS-40 besitzt Verteilungs-/Steuerskripte; WS-50 besitzt die beobachtete Laufzeitwirkung.
6. Historische Fehlzuordnungen werden nicht umgeschrieben. Neue Arbeit folgt der kanonischen Workstream-ID.

## Content-Freshness-Limitierungen

Diese vier Punkte beeinflussen nur die Aktualität des Chatinhalts-Snapshots:

1. Der WS-10-Turn war beim V1-Snapshot aktiv; sein endgültiges Ergebnis war nicht verfügbar.
2. Der jüngste abgeschlossene WS-20-Turn war in der App-Ansicht kompaktiert.
3. Der jüngste abgeschlossene WS-40-Turn war kompaktiert; verfügbar waren nur Vorschau und Zusammenfassung.
4. Der letzte sichtbare WS-50-Trainer-Control-Übergabepunkt gehört fachlich zu WS-20; sein endgültiger Ergebnisstand war nicht sichtbar.

`UNRESOLVED_STRUCTURE_COUNT=0` bleibt davon unberührt.

## Entscheidungen für die nächste Phase

Noch nicht autorisiert:

1. Darf WS-00 später in `Projektsteuerung und Workspace` umbenannt werden?
2. Dürfen WS-30, WS-70 und WS-80 später als lokale Chats angelegt werden?
3. Soll historisch fehlplatziertes Material am bisherigen Ort verbleiben und nur durch Querverweise verbunden werden?

Empfehlung für Entscheidung 3: **Nur Querverweise.** Historische Chatinhalte weder kopieren noch umschreiben.

## Mutationsnachweis

- Chatänderungen: 0
- Änderungen an bestehenden Projektdateien: 0
- Änderungen an den unveränderlichen V1-Dateien: 0
- Server-, Build-, Datenbank-, Migrations- oder Rollback-Aktionen: 0
- Autorisierter Folgeauftrag: nein
