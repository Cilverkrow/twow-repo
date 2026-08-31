# Lokale TWoW-Projektstruktur – Inventar v1

Erfasst: 2026-08-30T16:11:24Z  
Arbeitsauftrag: `PROJECT-STRUCTURE-LOCAL-INVENTORY-01`  
Modus: `READ_ONLY_ANALYSIS`  
Ergebnis: `PARTIAL`

## Kurzfassung

Die lokale Codex-Projektseite `TWoW - Lokal` enthält sechs Chats. Fünf Titel entsprechen bereits einem kanonischen Arbeitsbereich. Der zentrale Struktur-Chat ist inhaltlich WS-00 zugeordnet, benötigt aber nach Freigabe eine Umbenennung. Drei kanonische Arbeitsbereiche besitzen noch keinen lokalen Chat: WS-30, WS-70 und WS-80.

Unter `C:\TW\ComTW\runbooks` wurden 41 vorhandene Evidenzverzeichnisse und 43 Dateien auf oberster Ebene erfasst. Jeder bestehende Evidenztyp erhielt genau einen künftigen fachlichen Eigentümer. Es wurden keine bestehenden Dateien oder Chatstrukturen verändert.

Kennzahlen:

| Kennzahl | Wert |
|---|---:|
| Lokale Chats | 6 |
| Exakte kanonische Titel | 5 |
| Umbenennungsvorschläge | 1 |
| Fehlende kanonische Arbeitsbereiche | 3 |
| Historische/fachlich fehlplatzierte Chatbezüge | 3 |
| Künftige Dateisystem-Zuordnungen | 9 |
| Offene Befunde | 4 |
| Chatänderungen | 0 |
| Geänderte bestehende Projektdateien | 0 |
| Server-/Datenbankoperationen | 0 |

## 1. Fakten

### 1.1 Lokales Projekt und Chatbestand

Lokales Codex-Projekt:

- Bezeichnung: `TWoW - Lokal`
- Projekt-ID: `bad28a62-cbc0-4374-bd12-e7e23a17aedf`
- Projektpfad: `C:\TW`
- Von Codex als Git-Repository erkannt: `false`

| Aktueller lokaler Titel | Kanonischer Arbeitsbereich | Einstufung | Zweck / aktueller Befund | Vorgeschlagene Aktion |
|---|---|---|---|---|
| `Analysiere TWoW-Projektstruktur` | WS-00 `Projektsteuerung und Workspace` | Umbenennung vorgeschlagen | Zentrale Projektkarte, Regeln, Zuordnung und Übergaben; dieser Inventarauftrag läuft hier. | Nach ausdrücklicher Freigabe umbenennen. |
| `SSC – Analyse und Entwicklung` | WS-10 `SSC – Analyse und Entwicklung` | Exakter Treffer | SSC-, PlayerBot-, Quellcode- und LLM-Brückenanalyse; aktiver Arbeitsstand war beim Snapshot noch nicht abgeschlossen. | Titel beibehalten; laufenden Stand später synchronisieren. |
| `Datenbank und Migrationen` | WS-20 `Datenbank und Migrationen` | Exakter Treffer | Datenbank-, Migrations-, ACL-, Trainer-, Berufe-/Reiten- und Spendenpunkte-Themen. | Titel beibehalten; kompakten aktuellen Stand ergänzen. |
| `Deployment und Skripte` | WS-40 `Deployment und Skripte` | Exakter Treffer | Build-/Transfer-/Start-/Stopp-/Rollback-Skripte und Hilfsprogramme. Ein Vorschautext verweist historisch auf LLM-Debugging. | Titel beibehalten; historischen Fehlbezug nur dokumentieren. |
| `Build und Serverbetrieb` | WS-50 `Build und Serverbetrieb` | Exakter Treffer | Builds, Live-Smoke-Tests, Dienste und Laufzeitbefunde. Der letzte sichtbare Trainer-Control-Bezug gehört fachlich zu WS-20. | Titel beibehalten; künftige Arbeit sauber routen. |
| `Referenzserver und Backups` | WS-60 `Referenzserver und Backups` | Exakter Treffer | Historische Sicherungen, Referenzzustände und Vergleich zum neuen Host; noch kein substanzieller sichtbarer Arbeitsstand. | Titel beibehalten; Zweck mit einem Sync-Block bestätigen. |

Fehlende lokale kanonische Arbeitsbereiche:

- WS-30 `Serverkonfiguration`
- WS-70 `Bot-Persönlichkeiten`
- WS-80 `Dokumentation und Entscheidungen`

Die zweite Bildschirmaufnahme zeigt das Online-ChatGPT-Projekt `TWoW - Server` nur als Vergleich. Online-Titel wurden nicht als Beweis für lokale Chatinhalte verwendet.

### 1.2 Ordnerstruktur im Server-Arbeitsbereich

Erfasste oberste Ebene von `C:\TW\ComTW`:

| Pfad/Typ | Bedeutung |
|---|---|
| `data\` | Server-/Laufzeitdaten; nicht vertieft analysiert. |
| `DB\` | Datenbankbezogene Inhalte und Migrationen. |
| `logs\` | Laufzeit-, Build- und Diagnoseprotokolle. |
| `runbooks\` | Nachweis-, Übergabe- und Arbeitsartefakte. |
| `server\` | Serverprogramme und aktive Konfigurationen. |
| `source\` | Git-Repository des Server-/PlayerBot-Quellcodes. |
| `vcpkg\` | Abhängigkeiten/Tooling; nicht vertieft analysiert. |
| `compile-tortoise-wow.bat/.ps1` | Build-Launcher. |
| `pull-docker.bat/.ps1` | Abruf-/Deployment-Helfer. |
| `pull-oldnative.bat/.ps1` | Abruf-/Legacy-Helfer. |
| `transfer-apply.bat/.ps1` | Transfer-/Anwendungs-Helfer. |
| `RECOMMENDED_aiplayerbot.conf` | Referenzkonfiguration für PlayerBot. |
| `RECOMMENDED_mangosd.conf` | Referenzkonfiguration für den Worldserver. |
| `README.md`, `TRANSFER-GUIDE.txt`, `install-prerequisites-guide.txt` | Bestehende Projektdokumentation. |

Nicht vorhanden waren eigenständige oberste Verzeichnisse `backup`, `backups`, `docs` oder `documentation`. Daraus wird keine Lösch- oder Erstellungsaktion abgeleitet.

### 1.3 Quellcode- und Laufzeitstand

Git-Repository `C:\TW\ComTW\source`:

- Branch: `playerbots-integration-gh`
- Commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Vorhandene lokale Änderungen, nicht von diesem Auftrag verursacht:
  - `M src/modules/PlayerBots/CMakeLists.txt`
  - `M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp`
  - `M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h`
  - `M src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp`
  - `?? bin/`

Dienstzustand beim Snapshot:

| Dienst/Prozess | Zustand |
|---|---|
| `mangosd` | nicht laufend |
| `realmd` | nicht laufend |
| `mysqld` | nicht laufend |
| `mariadbd` | nicht laufend |
| `ollama` | laufend, 1 Prozess |

Es wurden keine Prozesse gestartet, beendet oder verändert.

### 1.4 Relevanz für lokale LLM- und Bot-Chat-Integration

| Priorität | Arbeitsbereich | Relevanz |
|---|---|---|
| Primär | WS-10 | PlayerBot-Quellcode, `PlayerbotLLMInterface`, Debug-Aktionen, Transport-/Kontextbrücke und technische Skalierung. |
| Primär | WS-70 | Bot-Persönlichkeiten, Prompts, Verhalten, Gedächtnis und Dialogregeln. |
| Hoch | WS-30 | Aktive und empfohlene PlayerBot-/Serverkonfiguration, Pfade, Ports und Laufzeitparameter. |
| Hoch | WS-20 | Persistente Zustände, optionale Gedächtnis-/Kontextdaten und migrationspflichtige Schemaänderungen. |
| Hoch | WS-50 | Build- und Live-Smoke-Nachweise sowie Laufzeitbeobachtung. |
| Mittel | WS-40 | Build-, Verteilungs-, Start-/Stopp- und Rollback-Abläufe für die Integration. |
| Mittel | WS-80 | Architekturentscheidungen, Schnittstellenverträge und Betriebsdokumentation. |
| Unterstützend | WS-60 | Vergleichbare Referenzstände und wiederherstellbare Sicherungen. |
| Steuernd | WS-00 | Routing, Freigaben und kompakte Synchronisationsblöcke. |

## 2. Eigentum der vorhandenen Runbook-Evidenz

Grundregel: Ein Evidenzartefakt besitzt genau einen fachlichen Eigentümer. Domänenspezifische Dokumentation bleibt beim Fachbereich; WS-80 verwaltet nur übergreifende Entscheidungen und kanonische Indizes.

### WS-10 – SSC – Analyse und Entwicklung (19 Verzeichnisse)

Auch die zwei als `_superseded` markierten Phase-1b-Pakete bleiben historische WS-10-Evidenz.

- `_superseded-phase1b-package-build-20260829-163519`
- `_superseded-phase1b-package-build-20260829-163519-timestamp-audit`
- `playerbot-discovery-matrix-preflight-02-20260830-173815`
- `ssc-llm-bridge-phase0-20260829-015349`
- `ssc-llm-bridge-phase1a-20260829-023418`
- `ssc-llm-bridge-phase1a-hardening-20260829-035317`
- `ssc-llm-bridge-phase1b-live-20260829-163519`
- `ssc-llm-bridge-v1-english-correction-20260830-131349`
- `ssc-llm-production-bridge-01-phase-a-20260830-012815`
- `ssc-llm-production-bridge-01-phase-a-r1-20260830-163931`
- `ssc-llm-production-bridge-01-phase-a-r2-20260830-170407`
- `ssc-llm-production-bridge-01-phase-b-20260830-173121`
- `ssc-ollama-manual-scaling-01-phase1-20260829-210352`
- `ssc-source-baseline-01-20260829-193848`
- `ssc-source-baseline-02-20260829-204358`
- `ssc-source-baseline-02a2-20260829-213222`
- `ssc-source-baseline-02a3-20260829-215858`
- `ssc-source-baseline-02c-20260829-233607`
- `ssc-source-baseline-02c-r1-20260830-004551`

Zusätzlich gehören 13 Runbook-Dateien auf oberster Ebene mit SSC-/Audit-/Metadaten-/Lieferpaketbezug zu WS-10.

### WS-20 – Datenbank und Migrationen (14 Verzeichnisse)

- `acl-context-lab`
- `autodonationpoints-preflight-20260829-034455`
- `db-profession-riding-discovery-01-20260830-010856`
- `donation-point-backup-20260829-183323`
- `donation-point-manual-20260829-182942`
- `donation-point-migration-20260829-183829`
- `donation-point-progress-migration-20260829-173126`
- `donation-point-progress-migration-20260829-180600`
- `donation-point-progress-migration-20260829-181230`
- `donation-runtime-test-01-20260829-184426`
- `semantic-acl-e2e-lab`
- `semantic-acl-e2e-lab-3`
- `trainer-control-20260829-014115-699`
- `trainer-purchase-money-loss-20260829-004949-873`

Zusätzlich gehören 19 Dateien mit `tw-char-migration-*`- und verwandtem Migrationsbezug zu WS-20. Migrationslokale Rücksicherungsartefakte bleiben WS-20; langfristige Referenz- und Archivbackups gehören WS-60.

### WS-40 – Deployment und Skripte (4 Verzeichnisse)

- `compile-launcher-regeneration-lab`
- `compile-script-archive-20260828`
- `runtime-file-archive-20260828`
- `shutdown-helper-console-lab`

Zusätzlich gehören drei oberste Dateien zu WS-40: Build-Launcher-Kandidat/Review und Shutdown-Helper-Review.

### WS-50 – Build und Serverbetrieb (2 Verzeichnisse)

- `post-completion-live-smoke-20260829-000920-697`
- `world-shutdown-smoke-evidence-20260828-160724-135`

Zusätzlich gehören drei `tw-world-shutdown-smoke-*`-Dateien zu WS-50.

### WS-70 – Bot-Persönlichkeiten (2 Verzeichnisse)

- `bot-personality-discovery-20260828-223311`
- `bot-personality-discovery-20260828-224032`

Zusätzlich gehören fünf Dateien mit Bot-Persönlichkeits-Paket-/Chunk-Bezug sowie `personality-context-contract-v1.md` zu WS-70.

### Gegenwärtig ohne eigene Runbook-Gruppe

- WS-00: Das hier erzeugte Inventar wird sein erster eindeutig zugeordneter lokaler Evidenzsatz.
- WS-30: Noch keine eigene Gruppe; vorhandene Konfigurationsdateien bleiben an ihrem aktuellen Ort.
- WS-60: Noch keine eindeutig dedizierte Referenzserver-/Langzeitbackup-Gruppe.
- WS-80: Noch keine eigene Gruppe; vorhandene Fachdokumente bleiben bei ihren Domänen.

## 3. Überschneidungen und verbindliche Trennlinien

1. **WS-40 / WS-50:** Entwicklung und Versionierung von Skripten, Launchern und Hilfsprogrammen gehören WS-40. Konkrete Ausführung, Live-Smoke, Prozesszustand und Betriebsnachweis gehören WS-50.
2. **WS-20 / WS-60:** Direkt zu einer Migration gehörende Rücksicherungsartefakte gehören WS-20. Historische, langfristige und referenzserverbezogene Sicherungen gehören WS-60.
3. **WS-10 / WS-70:** Technische LLM-Brücke, Kontexttransport und PlayerBot-Integration gehören WS-10. Persona-Inhalte, Prompts, Verhalten, Gedächtnisregeln und Dialogstil gehören WS-70.
4. **WS-80 / Fachbereiche:** Fachberichte verbleiben beim Fachbereich. WS-80 übernimmt nur projektweite Entscheidungen, ADRs, Indizes und verbindliche Betriebsdokumentation.
5. **WS-30 / WS-40 / WS-50:** Konfigurationswerte, Ports und Pfade gehören WS-30; Skripte, die sie verteilen oder Dienste steuern, WS-40; beobachtete Laufzeitwirkung und Dienstzustand WS-50.
6. **Historische Chatbezüge:** Ein WS-40-Vorschautext nennt LLM-Debugging, ein WS-50-Arbeitsstand nennt Trainer-Control und ein WS-20-Vorschautext verweist auf Deployment. Diese Historie wird nicht umgeschrieben; künftige Fortsetzungen werden dem kanonischen Eigentümer zugeordnet.

## 4. Annahmen

- Chatvorschauen und kompaktierte Zusammenfassungen beschreiben den letzten sichtbar verfügbaren Stand, ersetzen aber keinen aktuellen Datei-, Git-, Hash- oder Datenbankbefund.
- Der laufende WS-10-Turn kann nach diesem Snapshot neue Ergebnisse liefern; diese sind nicht Teil dieses Inventars.
- Die vorgeschlagenen Dateisystempfade sind Namens- und Eigentumsvorschläge. Es wird nicht angenommen, dass bestehende Runbooks bereits sicher verschoben werden können.

## 5. Vorschläge – noch nicht ausgeführt

### 5.1 Künftige Dateisystem-Zuordnung

Nur als Zielbild; kein Verzeichnis wurde angelegt:

- `C:\TW\ComTW\runbooks\workstreams\WS-00-projectsteuerung-workspace`
- `C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung`
- `C:\TW\ComTW\runbooks\workstreams\WS-20-datenbank-migrationen`
- `C:\TW\ComTW\runbooks\workstreams\WS-30-serverkonfiguration`
- `C:\TW\ComTW\runbooks\workstreams\WS-40-deployment-skripte`
- `C:\TW\ComTW\runbooks\workstreams\WS-50-build-serverbetrieb`
- `C:\TW\ComTW\runbooks\workstreams\WS-60-referenzserver-backups`
- `C:\TW\ComTW\runbooks\workstreams\WS-70-bot-persoenlichkeiten`
- `C:\TW\ComTW\runbooks\workstreams\WS-80-dokumentation-entscheidungen`

### 5.2 Manuelle UI-Aktionsliste

Nur nach ausdrücklicher Freigabe:

1. `Analysiere TWoW-Projektstruktur` in `Projektsteuerung und Workspace` umbenennen.
2. Den lokalen Chat `Serverkonfiguration` für WS-30 anlegen.
3. Den lokalen Chat `Bot-Persönlichkeiten` für WS-70 anlegen.
4. Den lokalen Chat `Dokumentation und Entscheidungen` für WS-80 anlegen.
5. Die fünf bereits exakt passenden Titel unverändert lassen.
6. Keine vollständigen Altverläufe kopieren; pro Arbeitsbereich nur kompakte Synchronisationsblöcke verwenden.
7. Historische Fehlzuordnungen nur als Querverweis dokumentieren, nicht nachträglich umschreiben.
8. Bei jeder neuen Aufgabe zuerst anhand der Workstream-ID routen.

## 6. Offene Punkte und benötigte Entscheidungen

Benötigte Benutzerentscheidung:

1. Darf WS-00 später wie vorgeschlagen umbenannt werden?
2. Dürfen die drei fehlenden lokalen Chats WS-30, WS-70 und WS-80 später angelegt werden?
3. Sollen historische Fehlzuordnungen am bisherigen Ort mit Querverweis verbleiben (empfohlen), oder sollen zusätzlich manuelle Kurzübernahmen in den kanonischen Zielchat erstellt werden?

Noch nicht vollständig auflösbar:

1. Der WS-10-Turn war beim Snapshot aktiv; sein Endergebnis liegt noch nicht vor.
2. Der jüngste abgeschlossene WS-20-Inhalt war in der App-Ansicht kompaktiert.
3. Der jüngste abgeschlossene WS-40-Inhalt war ebenfalls kompaktiert; verfügbar waren nur Vorschau und Zusammenfassung.
4. Der letzte sichtbare WS-50-Trainer-Control-Übergabepunkt ist fachlich WS-20 zuzuordnen; ein endgültiger Ergebnisstand war nicht sichtbar.

## 7. Integrität und Grenzen

Quellnachweise:

| Nachweis | SHA-256 |
|---|---|
| Lokaler Projekt-Screenshot | `7535E7CEA60D01177D6E85E13ADBD96ADF75B8E35A0750D6FD68523D431FBC9F` |
| Online-Vergleichs-Screenshot | `47652E2C7C493E42082AB0CADCFA307FC865E1475825606447E1F0FED5F6CBA3` |
| Arbeitsauftrag | `67C0CB448C6510DEA8D0CD03588F3E472F00A93A22631AB4CE5306D6841ACB15` |

Wichtige lokale Referenzhashes:

| Datei | SHA-256 |
|---|---|
| `C:\TW\ComTW\compile-tortoise-wow.ps1` | `80D4D4607AF05048D14487AAD335C56ED2857D3F984D7F133A41F25D66706ECC` |
| `C:\TW\ComTW\server\mangosd.exe` | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` |
| `C:\TW\ComTW\server\realmd.exe` | `A36A3B611229D2A68FEAA4BD92D4283888CA64CD45FBD7C5E6F28050AB0B676B` |
| `C:\TW\ComTW\server\aiplayerbot.conf` | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` |

Keine Passwörter, Tokens oder Datenbankzugänge wurden aufgenommen. Große Client-/MPQ-/Cache-Dateien wurden nicht geöffnet. Der Auftrag hat ausschließlich das neue Evidenzverzeichnis und seine vier Dateien erzeugt.
