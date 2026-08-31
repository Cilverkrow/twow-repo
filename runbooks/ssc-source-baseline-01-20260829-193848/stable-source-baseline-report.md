# SSC-SOURCE-BASELINE-01 — Stable Source Revision Gate

Erfassungsdatum: 2026-08-29 (Europe/Berlin)  
Prüfmodus: ausschließlich lesend gegenüber Repository, Source, Builds, Konfiguration, Logs und Datenbankdateien  
Abschlussstatus: `STABLE_REVISION_RESULT=BLOCKED`

## 1. Ergebnis

Es gibt genau einen bevorzugten, aber **nicht freigegebenen** Baseline-Kandidaten:

`42b8a7f742548793910fe8880463aeeb71627fb9`

Dieser Commit ist lokaler `HEAD`, Ziel des lokal vorhandenen Upstream-Refs und die eindeutige lokale Auflösung des in Produktions-EXE und Startlog eingebetteten 20-Hex-Präfixes `42b8a7f742548793910f`. Die Produktions-EXE passt außerdem zu einer vorhandenen PDB mit identischer CodeView-GUID und Age.

Der Gate kann trotzdem nicht auf PASS gesetzt werden:

1. Die EXE enthält nur `git rev-parse --short=20 HEAD`. Der Buildmechanismus erfasst keinen Dirty-Status, kein vollständiges Quellbaum-Manifest und keine Build-/Dependency-Provenienz. Daher beweisen weder HEAD noch das eingebettete Präfix, dass die EXE aus einem sauberen Checkout genau dieses vollständigen Commits gebaut wurde.
2. Ein korrekt gequoteter, auf drei Sekunden begrenzter Read-only-MariaDB-Zugriff endete mit `ERROR 2002 / 10061` auf `127.0.0.1:3307`. Die vorhandenen Offline-Dateien und Produktionslogs belegen Tabellen und Betrieb, aber nicht transaktional den aktuellen Inhalt aller Migrationstracker.
3. Der Arbeitsbaum ist vollständig klassifiziert, aber dirty: vier frühere LLM-Debugänderungen und sechs unversionierte PDB-Buildartefakte. Dieser Arbeitsbaum selbst ist keine freigabefähige Baseline.

Die derzeitige Kombination aus Kandidaten-Source, Produktions-EXE, Config und Offline-Schema ist **stark indiziert und im beobachteten Produktionsbetrieb plausibel kompatibel**, aber wegen der beiden Provenienz-/Tracker-Lücken nicht abschließend zertifizierbar.

## 2. Repository und Revision

| Merkmal | Befund |
|---|---|
| Repository | `C:\TW\ComTW\source` |
| Aktiver Branch | `playerbots-integration-gh` |
| Vollständiger HEAD | `42b8a7f742548793910fe8880463aeeb71627fb9` |
| Parent | `58d7bec64779d7c5a0e629e6e58633f04346bf1a` |
| Commit-Zeit | `2026-08-25T15:22:11+01:00` |
| Betreff | `dc: load recorded routes at runtime, and raise the instance gate` |
| Upstream | `origin/playerbots-integration-gh` |
| Upstream-Ref | ebenfalls `42b8a7f742548793910fe8880463aeeb71627fb9` |
| Origin | `https://github.com/Shyalya/tortoise-wow.git` |
| Describe | `42b8a7f-dirty` |
| Tags | keine lokal vorhandenen Tags; kein Tag auf HEAD |
| Submodule | keine `.gitmodules`, keine Gitlink-Einträge |

Es wurde kein Fetch oder Pull ausgeführt. „Upstream“ bedeutet daher ausschließlich den lokal vorhandenen Remote-Tracking-Ref.

## 3. Vollständiger Arbeitsbaum und Klassifikation

`git status --short --untracked-files=all`:

```text
 M src/modules/PlayerBots/CMakeLists.txt
 M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp
 M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h
 M src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp
?? bin/Release/MoveMapGen.pdb
?? bin/Release/mangosd.pdb
?? bin/Release/mapextractor.pdb
?? bin/Release/realmd.pdb
?? bin/Release/vmap_assembler.pdb
?? bin/Release/vmapextractor.pdb
```

Es gibt keine gestagten Änderungen.

| Kategorie | Befund |
|---|---|
| Beabsichtigte Projektänderungen | keine nachweisbaren |
| Frühere LLM-Debugänderungen | genau die vier getrackten Dateien oben |
| Sonstige lokale Sourceänderungen | keine |
| Configänderungen im Repository | keine |
| Generierte/unversionierte Dateien | genau sechs PDB-Dateien |

Der vollständige Diff umfasst 495 Einfügungen und 16 Löschungen. Seine Hunk-Inhalte betreffen ausschließlich die frühere LLM-Debug-HTTP-/Async-Funktion, deren Debug-Chatpfad und den dafür ergänzten Include-Pfad. Die sechs PDBs sind Linker-/Buildausgaben.

Zusätzlich sind 1.820 ignorierte Einträge vorhanden. `build\` enthält 1.813 Dateien mit 4.417.952.166 Bytes; `bin\` enthält zwölf Dateien mit 260.059.648 Bytes. Relevante Ignore-Regeln sind `/build/`, `*.exe` und `/src/shared/revision.h`. Die Konfigurationen liegen außerhalb des Git-Repositorys und werden separat bewertet.

Der vor und nach der Analyse erfasste Git-Status ist bytegleich. Die Hashes der überwachten bestehenden EXE-, Config- und DB-Dateien sind ebenfalls unverändert.

## 4. Produktions-EXE und Provenienz

Referenzartefakt: `C:\TW\ComTW\server\mangosd.exe`

| Merkmal | Wert |
|---|---|
| SHA-256 | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` |
| Größe | 20.376.576 Bytes |
| CreationTime UTC | `2026-08-25T16:54:55.7705743Z` |
| LastWriteTime UTC | `2026-08-25T16:54:59.8378295Z` |
| PE Machine | `0x8664` (x64) |
| PE Linker Timestamp UTC | `2026-08-25T16:54:59Z` |
| Windows File-/ProductVersion | nicht vorhanden |
| Eingebettete Revision | `Core revision: 42b8a7f742548793910f / 2026-08-25 15:22:11 +0100 / Win64 (little-endian)` |
| CodeView | RSDS, GUID `c5ddd5cc-4b8d-47ae-b2a5-ab4e5f158cc3`, Age 1 |
| Eingebetteter PDB-Pfad | `C:\TW\ComTW\source\bin\Release\mangosd.pdb` |

Die Produktions-PDB `C:\TW\ComTW\server\mangosd.pdb` hat SHA-256 `0BBABAC50A4CF8D413ED651AF1BE74DC67BF02B0403E69193D9D9FB7907FC7A8` und dieselbe GUID/Age-Kombination; sie gehört damit zur Produktions-EXE.

Weitere Abgrenzung:

- `server\mangosd.pre-llm-debug-20260826.exe` ist mit der Produktions-EXE bytegleich.
- Der spätere Build `source\bin\Release\mangosd.exe` ist mit SHA-256 `43EEB340FE4F4FD8122E96FE464181EDF45A1374C890D4C2540577A274252961` verschieden und 20.421.632 Bytes groß.
- Dessen PDB verwendet dieselbe GUID, aber Age 4 und passt nicht zur Produktions-EXE.

Der lokale Commitraum enthält genau einen Commit mit dem eingebetteten 20-Hex-Präfix: den vollständigen Kandidaten `42b8a7f742548793910fe8880463aeeb71627fb9`.

Diese Indizien ordnen die EXE sehr stark der Commit-Linie zu. Sie belegen aber keinen sauberen Quellzustand: `CMakeLists.txt:346` führt lediglich `git rev-parse --short=20 HEAD` aus. Änderungen an getrackten Dateien, unversionierte Quelldateien, CMake-Optionen, Compiler und Libraries werden nicht in die Revision aufgenommen. HEAD allein ist daher ausdrücklich nicht der geforderte Provenienznachweis.

## 5. Letzter erfolgreicher Produktionsstart

Neuestes Log mit `World server is up and running!`:

`C:\TW\ComTW\logs\server_2026-08-29_19-19-30.log`

| Merkmal | Wert |
|---|---|
| SHA-256 | `4721E34F09E2AD4989CA45B73EBD238F2BC0F1C4401A8DA7E1CCB4CA8E10E318` |
| Start-Revision, Zeile 2115 | `42b8a7f742548793910f` |
| „World server is up“, Zeile 3977 | `2026-08-29 19:20:46` |
| Ladezeit | 1 Minute 16 Sekunden |
| „Halting process“, Zeile 8849 | `2026-08-29 19:25:28` |

Der Launcher `server\start-mangosd.bat` wechselt in sein eigenes Verzeichnis und startet dort `mangosd.exe`. Das verbindet das Log betrieblich mit dem installierten Pfad, ersetzt aber keinen Hash im Startlog.

## 6. Config

| Datei | SHA-256 | Abweichende Schlüssel gegenüber `.dist` |
|---|---|---:|
| `server\mangosd.conf` | `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D` | 59 |
| `server\aiplayerbot.conf` | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` | 35 |

Sicherheitsrelevante aktive Werte:

- `AutoDonationPoints.Enable = 1`
- `AutoDonationPoints.Amount = 100`
- `AutoDonationPoints.IntervalMs = 3600000`
- `AutoDonationPoints.FlushIntervalMs = 300000`
- `BackupCharacterInventory = 1`
- `Database.AutoUpdate.Enabled = 0`
- `AiPlayerbot.LLMEnabled = 0`
- `AiPlayerbot.LLMBotToBotChatChance = 0`
- `AiPlayerbot.LLMRpgAIChatChance = 0`
- `AiPlayerbot.LLMMaxSimultaniousGenerations = 1`
- `AiPlayerbot.LLMGenerationTimeout = 30`
- `AiPlayerbot.LLMContextLength = 4096`

Alle vier DB-Deskriptoren zeigen auf `127.0.0.1:3307` und die Schemas `tw_logon`, `tw_world`, `tw_char`, `tw_logs`. Benutzername/Passwort sowie LLM-Endpunkt/API-Key wurden nicht ausgegeben; für die LLM-Werte enthält die Evidenz nur Hashes. Der vorhandene LLM-Pfad ist in der aktiven Config deaktiviert.

## 7. Schema- und Migrationsprüfung

### Live Read-only-Abfrage

Der gültige Clientaufruf enthielt ausschließlich sieben `SELECT`-Statements gegen `information_schema`, die drei `migrations`-Tabellen und die beiden geforderten Fachtabellen. Verbindungsfrist: drei Sekunden. Ergebnis:

```text
ERROR 2002 (HY000): Can't connect to server on '127.0.0.1' (10061)
```

Die Datenbank wurde nicht gestartet und es gab keinen Wiederholungsversuch nach diesem gültigen Ergebnis. Ein vorheriger lokaler Aufruf war fehlerhaft gequotet, zeigte nur die MariaDB-Clienthilfe und erreichte keinen Server; er ist zur Transparenz als Zwischenartefakt erhalten.

### Offline-Evidenz

Aus vorhandenen `.frm`-Dateien:

| Schema | Tabellen | vorhandener Tracker |
|---|---:|---|
| `tw_logon` | 42 | `migrations` |
| `tw_world` | 297 | `migrations` |
| `tw_char` | 109 | `migrations` |
| `tw_logs` | 1 | keiner |

`character_db_version`, `db_version` und `realmd_db_version` sind in diesen physischen Schemata nicht vorhanden. Der aktive Trackertyp ist `migrations(Id, Name, Hash, AppliedAt)`.

#### character_inventory_copy

- Physisch vorhanden: `tw_char\character_inventory_copy.frm/.MYD/.MYI`.
- Die `.frm`-Struktur von `character_inventory_copy` und `character_inventory` ist gleich: MyISAM, `utf8mb3_general_ci`, Recordlength 18, fünf Felder und identische Schlüsseldefinitionen.
- Offline-Zähler: `character_inventory` 36.132 Datensätze, Snapshot `character_inventory_copy` 35.240 Datensätze. Diese Differenz ist als Backup-Zeitpunkt plausibel und kein Strukturfehler.
- Kandidaten-Source verlangt `sql/character_updates/20260812142512_character_inventory_copy.sql`, Blob `1a6ad33c523ed99baf20bf1799706a198134ed1c`, eingeführt durch `171a4fdfde52f784f4b6ef376d1749f83dfda365`, einen Ancestor des Kandidaten.
- Aus `tw_char\migrations.ibd` ist der Präfix `20260812142512_character_inventory_copy` als Klartext rekonstruierbar.
- Codezugriffe: `Commands.cpp:17236` sowie `ObjectMgr.cpp:10158-10161`.

Bewertung: Tabellenexistenz und Layout sind mit Kandidaten-Source und `BackupCharacterInventory=1` vereinbar. Die exakte Trackerzeile/der gespeicherte Hash konnte wegen der nicht erreichbaren DB nicht per SQL bestätigt werden.

#### donation_point_progress

- Physisch vorhanden: `tw_logon\donation_point_progress.frm/.ibd`.
- Kandidaten-Source verlangt `sql/logon/donation_point_progress.sql`, Blob `38386f8358585ee8c7a53ff5bd66f69605576976`, eingeführt durch `65056948ccb52e7a96a623bff164d1abf87673b9`, einen Ancestor des Kandidaten.
- Erwartete Spalten: `account_id INT UNSIGNED PRIMARY KEY`, `accumulated_ms INT UNSIGNED NOT NULL DEFAULT 0`, InnoDB/utf8mb4.
- Produktionslog `server_2026-08-29_18-45-43.log`, SHA-256 `985B8E3C591D254F8412BE39A7565A524E8326E49E4C4928F2DC5513EF91F94B`, zeigt einen erfolgreichen SELECT und drei spätere UPSERTs auf dieser Tabelle. Identifikatoren und SQL-Literale wurden nicht in das Paket übernommen.
- Codezugriffe: `World.cpp:2965, 2984, 2992`.

Bewertung: Die aktive Donation-Points-Funktion wurde mit der Produktions-EXE gegen die vorhandene Tabelle erfolgreich beobachtet. Aktuelle Zeileninhalte und der vollständige `tw_logon.migrations`-Tracker bleiben ohne Live-SELECT unbekannt; der Klartext-Scan der Logon-`.ibd` liefert keine belastbaren Migrationsnamen.

### Tracker-Parität

Aus `tw_world\migrations.ibd` lassen sich 146 Update-Namen rekonstruieren; Kandidaten-HEAD enthält ebenfalls 146 Dateien unter `sql/database_updates`. Aus `tw_char\migrations.ibd` sind vier relevante Namenspräfixe einschließlich `character_inventory_copy` sichtbar. Das ist unterstützende, aber keine transaktional belastbare Gleichheit: Offline-InnoDB-Dateien ersetzen weder `SELECT Id,Name,Hash,AppliedAt` noch eine Spaltenprüfung über `information_schema`.

## 8. Kompatibilitätsmatrix

| Beziehung | Bewertung | Begründung |
|---|---|---|
| Kandidaten-Source ↔ EXE | stark indiziert, nicht bewiesen | eindeutiges 20-Hex-Präfix, Datum, passendes PDB-Paar; kein Clean-Tree-/Buildmanifest |
| EXE ↔ Startlog | betrieblich konsistent | gleiche eingebettete Revision; Launcher startet installierten Pfad; Log enthält keinen EXE-Hash |
| Kandidaten-Source ↔ Config | konsistent | benötigte Donation-/Inventory-Funktionen vorhanden; LLM deaktiviert; Auto-Update aus |
| Kandidaten-Source ↔ Offline-Schema | konsistent mit Restunsicherheit | beide Tabellen vorhanden, Inventory-Layout passt, Migrationen indiziert |
| Produktions-EXE ↔ Donation-Schema | im Betrieb bestätigt | SELECT und drei UPSERTs im Produktionslog |
| Gesamtsystem | **nicht abschließend zertifiziert** | EXE-Provenienz und Live-Tracker-Parität fehlen |

## 9. Bevorzugter Baseline-Kandidat und fehlende Evidenz

Einziger bevorzugter Kandidat:

`42b8a7f742548793910fe8880463aeeb71627fb9`

Er darf erst als stabile Baseline freigegeben werden, wenn mindestens folgende Evidenz separat vorliegt:

1. Ein ursprüngliches Buildprotokoll oder signiertes Buildmanifest, das zur Hash-EXE `FB722B…E45FC` den vollständigen 40-Hex-Commit, einen leeren `git status --porcelain`, ein vollständiges Quellbaum-/Submodule-Manifest sowie CMake-Optionen, Compiler und relevante Dependency-Versionen bindet; alternativ ein kontrolliert reproduzierter bytegleicher Build aus einem nachweislich sauberen, separaten Checkout.
2. Ein erfolgreicher Read-only-SQL-Evidenzlauf mit `information_schema.TABLES/COLUMNS` und vollständigen `Id, Name, Hash, AppliedAt`-Zeilen aus `tw_logon.migrations`, `tw_world.migrations` und `tw_char.migrations`, einschließlich der beiden Fachtabellen.
3. Vor einer Source-Integration ein neuer Check der Fundstellen gegen genau den dann ausdrücklich freigegebenen Commit in einem sauberen Arbeitsbaum. Der aktuelle Dirty-Tree darf nicht als Integrationsbasis übernommen werden.

## 10. Später erneut zu prüfende Integrationspunkte

Nur Fundstellen; keine Änderung wurde vorgenommen:

| Zweck | Kandidaten-Fundstelle |
|---|---|
| Bestehender synchroner LLM-Transport | `PlayerbotLLMInterface.cpp:376` (`Generate`) |
| Request-Aufbau | `SayAction.cpp:421` (`GenerateResponsePackets`), JSON-Aufbau um `:598-600` |
| Bestehender Async-Dispatch | `SayAction.cpp:653` (`std::async`), `:655` (`SendDelayedPacket`) |
| RPG-Gating | `RpgTriggers.cpp:629, 635, 638` |
| AI-Tick | `PlayerbotAI.cpp:260` (`UpdateAI`), `:1222` (`UpdateAIInternal`) |
| Bot-Manager-Tick | `PlayerbotMgr.cpp:1229` (`UpdateAIInternal`), `:1244` (`UpdateSessions`) |
| Completion-Polling | `RpgSubActions.cpp:422-433`, insbesondere `:427`/`:430` |
| Unsicherer Altpfad | `PlayerbotAI.cpp:7978-8006`: `SendDelayedPacket`/`ReceiveDelayedPacket`, detached Threads bei `:7991`/`:8006` |
| World-Thread | `World.cpp:2628` (`World::Update`), `:2671` (`UpdateSessions`), `:3654` (Implementierung) |
| Packet-Thread-Regel | `WorldSession.h:137`, `:266` |
| Zustellung | `PlayerbotAI.cpp:3619` (`TellPlayerNoFacing`), Bereich `:3777-3790` (`TellPlayer`) |
| Config-Gating | `PlayerbotAIConfig.cpp:706, 717, 718` |
| Debug-Direktpfad in Kandidaten-HEAD | `DebugAction.cpp:1243`; nicht für Integration wiederverwenden |

Besonders wichtig: Der bestehende Delayed-Packet-Pfad erzeugt detached Threads und arbeitet mit einem rohen `WorldSession*`. Er widerspricht damit den bereits festgelegten Bridge-Sicherheitsgrenzen und darf später nicht als Queue-/Completion-Implementierung übernommen werden. Request-Queue, Completion-Queue und Zustellung müssen gegen den freigegebenen Commit neu auf Thread-Eigentum, Lebensdauer, Shutdown und World-/AI-Thread-Grenzen geprüft werden.

## 11. Unverändertheits- und Scope-Bestätigung

Die Analyse hat:

- keinen Checkout, Switch, Reset, Clean, Stash, Rebase, Pull oder Fetch ausgeführt;
- keine Source- oder bestehende Configdatei geändert;
- keinen Build und keine Kompilierung ausgeführt;
- keine Datenbank geschrieben und keine Migration ausgeführt;
- keine bestehenden Prozesse gestartet, gestoppt oder gesteuert;
- keine EXE ausgetauscht oder gestartet;
- keine Ollama-Inferenz und keinen Game-Chat ausgelöst;
- keinen Phase-1B-Code in den Game-Source übernommen.

Geschrieben wurden ausschließlich neue Bericht-, Evidenz-, Tool-, Manifest- und Paketdateien unter `C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848`. Der Vorher-/Nachher-Abgleich bestätigt unveränderten Git-Status und unveränderte SHA-256-Werte aller überwachten bestehenden Dateien.

## 12. Abschluss

`STABLE_REVISION_RESULT=BLOCKED`

Präziser Blocker: Der bevorzugte Commit ist aus den vorhandenen Indizien nicht eindeutig an den **vollständigen sauberen Quellzustand** der Produktions-EXE gebunden, und die aktuelle Migrationstracker-/Spaltenparität konnte bei abgeschalteter bzw. nicht erreichbarer MariaDB nicht per Read-only-SQL belegt werden.

Nach diesem Bericht wurde keine nächste Phase begonnen.
