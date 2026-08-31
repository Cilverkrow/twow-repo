# Projektstruktur-Abgleich v1

Erfasst: 2026-08-30T16:34:08Z  
Task: `PROJECT-STRUCTURE-ALIGNMENT-01`  
Modus: `READ_ONLY_ALIGNMENT`

## Ergebnis

```text
RESULT=PASS
ONLINE_INVENTORY_ACCEPTED=YES
LOCAL_INVENTORY_ACCEPTED=YES
CANONICAL_WORKSTREAM_COUNT=9
ONLINE_CURRENT_CHAT_COUNT=9
ONLINE_CANONICAL_CHAT_COUNT_AFTER_ACTIONS=9
ONLINE_LEGACY_REFERENCE_COUNT_AFTER_ACTIONS=2
ONLINE_TOTAL_CHAT_COUNT_AFTER_ACTIONS=11
ONLINE_RENAME_COUNT=7
ONLINE_CREATE_COUNT=2
LOCAL_CURRENT_CHAT_COUNT=6
LOCAL_CANONICAL_CHAT_COUNT_AFTER_ACTIONS=9
LOCAL_TOTAL_CHAT_COUNT_AFTER_ACTIONS=9
LOCAL_RENAME_COUNT=1
LOCAL_CREATE_COUNT=3
TOTAL_RENAME_COUNT=8
TOTAL_CREATE_COUNT=5
TOTAL_PROPOSED_UI_ACTION_COUNT=13
DELETE_COUNT=0
PHYSICAL_MERGE_COUNT=0
HISTORICAL_CONTENT_COPY_COUNT=0
LEGACY_REFERENCE_COUNT=2
UNRESOLVED_ALIGNMENT_COUNT=0
USER_APPROVAL_REQUIRED=YES
UI_MUTATIONS_PERFORMED=0
PROJECT_FILE_MUTATIONS_PERFORMED=5
NEXT_TASK_AUTHORIZED=NO
```

Beide Inventare wurden vollständig akzeptiert. Die vorgegebene Neun-Workstream-Matrix wird durch die freigegebene Online- und Lokal-Evidenz exakt unterstützt. Die vier lokalen Content-Freshness-Limitierungen sind rein informativ und erzeugen keine offene Alignment-Frage.

## Freigegebene Eingaben

Alle sieben Eingaben wurden vor der Auswertung anhand von Bytezahl und SHA-256 identifiziert.

| Seite | Nachweis | Bytes | SHA-256 | Ergebnis |
|---|---|---:|---|---|
| Online | `online-project-structure-inventory-v1-r2.md` | 11.117 | `820D020BBB7150B9DE677771347BEC5C690CCEA7E30D0A1DEBEC66B201E329E0` | akzeptiert |
| Online | `online-project-structure-inventory-v1-r2.json` | 12.522 | `1F271FAA395B5B93919693C93B2672A89395B7933FABF4D04BE5459F3A1B2B51` | akzeptiert |
| Online | `online-project-structure-handoff-v1-r2.md` | 1.262 | `34A15D4FFCBFC4FE4DB3364F87064FAC49EAD53FED2526B9E8D0B3069A6EE94A` | akzeptiert |
| Lokal | `local-project-structure-inventory-v1-r1.md` | 6.473 | `CCFF07188E86534A7FE4F790B48738106FD531B83BAD18097F5160A14A19FA24` | akzeptiert |
| Lokal | `local-project-structure-inventory-v1-r1.json` | 8.817 | `77E97BB469D98453830D4F925C89700EB04A28F1DB1F02BAA10681A18F09F433` | akzeptiert |
| Lokal | `local-project-structure-handoff-v1-r1.md` | 3.966 | `49B14A69D1EB7EB907F31229982A24D2424112C487B067F3E96A5EE565B2122F` | akzeptiert |
| Lokal | `sha256-manifest.txt` | 1.497 | `7CB3E50A76228E9E8F967F1DC388CA3FED94DD98D4224F1673EB06443098A105` | akzeptiert |

## Kanonische Neun-Workstream-Matrix

| ID | Kanonischer Titel | Online-Vorschlag | Lokal-Vorschlag |
|---|---|---|---|
| WS-00 | `Projektsteuerung und Workspace` | `Workspace einrichten` umbenennen | `Analysiere TWoW-Projektstruktur` umbenennen |
| WS-10 | `SSC – Analyse und Entwicklung` | `SSC Analyse und Entwicklung` umbenennen | Bestehenden kanonischen Chat beibehalten |
| WS-20 | `Datenbank und Migrationen` | `Datenbankmigrationen Übersicht` umbenennen | Bestehenden kanonischen Chat beibehalten |
| WS-30 | `Serverkonfiguration` | `Serverkonfiguration prüfen` umbenennen; `Bot Anzahl einschätzen` bleibt Legacy-Referenz | Fehlenden kanonischen Chat anlegen |
| WS-40 | `Deployment und Skripte` | `Deployment Skripte beschreiben` umbenennen | Bestehenden kanonischen Chat beibehalten |
| WS-50 | `Build und Serverbetrieb` | Kanonischen Chat anlegen; `Serverdateien gemeinsam nutzen` bleibt Legacy-Referenz | Bestehenden kanonischen Chat beibehalten |
| WS-60 | `Referenzserver und Backups` | Kanonischen Chat anlegen | Bestehenden kanonischen Chat beibehalten |
| WS-70 | `Bot-Persönlichkeiten` | `Ollama Botpersönlichkeiten planen` umbenennen | Fehlenden kanonischen Chat anlegen |
| WS-80 | `Dokumentation und Entscheidungen` | `Dokumentation anlegen TWoW Server` umbenennen | Fehlenden kanonischen Chat anlegen |

Es bestehen keine widersprüchlichen Identitäten oder Eigentumszuordnungen. Online bleiben zwei zusätzliche historische Chats erhalten; lokal entstehen nach dem vorgeschlagenen Plan keine Legacy-Zusatzchats.

## Zählwertableitung

Online:

- Ausgang: 9 Chats.
- Sieben Umbenennungen verändern die Chatanzahl nicht.
- Zwei neue kanonische Chats erhöhen die Gesamtzahl auf 11.
- Danach bestehen neun kanonische Chats und zwei unveränderte Legacy-Referenzen.

Lokal:

- Ausgang: 6 Chats.
- Eine Umbenennung verändert die Chatanzahl nicht.
- Drei neue kanonische Chats erhöhen Gesamt- und Kanonzahl auf 9.

Gesamt:

- 8 vorgeschlagene Umbenennungen.
- 5 vorgeschlagene Neuanlagen.
- 13 vorgeschlagene UI-Aktionen.
- 0 Löschungen, 0 physische Zusammenführungen und 0 Kopien historischer Inhalte.

## Bindende Richtlinie für historische Inhalte

```text
HISTORICAL_CONTENT_POLICY=CROSS_REFERENCES_ONLY
COPY_OLD_CHAT_CONTENT=NO
REWRITE_OLD_CHAT_CONTENT=NO
DELETE_LEGACY_CHATS=NO
```

Die beiden Online-Legacy-Chats bleiben unverändert:

- `Bot Anzahl einschätzen`
- `Serverdateien gemeinsam nutzen`

Künftige Facharbeit wird nur per Querverweis zu WS-30 beziehungsweise zu WS-40/WS-50/WS-60 geroutet. Ihre Verläufe werden weder kopiert noch umgeschrieben.

## Informative lokale Content-Freshness-Limitierungen

1. Der WS-10-Turn war beim lokalen V1-Snapshot aktiv.
2. Der jüngste WS-20-Turn war in der App-Ansicht kompaktiert.
3. Der jüngste WS-40-Turn war kompaktiert.
4. Der letzte sichtbare WS-50-Trainer-Control-Punkt war fachlich WS-20 zuzuordnen und nicht abschließend sichtbar.

Diese Punkte ändern weder die Matrix noch `UNRESOLVED_ALIGNMENT_COUNT=0`.

## Freigabegrenze

Der beiliegende UI-Aktionsplan wurde nur erstellt, nicht ausgeführt. Vor jeder Umbenennung oder Chatanlage ist eine neue ausdrückliche Benutzerfreigabe erforderlich. Zukünftige Workstream-Verzeichnisse wurden nicht angelegt. Server-, Build- und Datenbankzustände wurden nicht verändert.
