# SSC-LLM-PRODUCTION-BRIDGE-01 – Phase B

## Abschlussentscheidung

`PHASE_B_RESULT=PASS`

Der vollständige A-R2-Minimalpatch wurde ausschließlich im neuen detached Worktree `C:\TW\ssc-llm-phase-b-20260830-173121\source` auf Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`, implementiert. Der ursprüngliche Produktions-Sourcebaum blieb in Inhalt und Dirty-Status unverändert. Die aktive Produktions-EXE und beide aktiven Configs besitzen weiterhin ihre verbindlichen Hashes.

Der maßgebliche finale Build ist `build-final-r2`. Er wurde erst nach 107/107 bestandenen Fake-Child-Tests und bestandenem statischen Verbotsgate aus einem neuen Buildverzeichnis konfiguriert und ausschließlich als Target `Release/mangosd` gebaut. Die EXE wurde nicht gestartet oder deployed.

## Verbindliche Eingaben

| Eingabe | Verifiziert |
|---|---|
| Baseline-Commit | `42b8a7f742548793910fe8880463aeeb71627fb9` |
| Baseline-Tree | `b2cf4e38fd288a53f61b9f2350f74caa85d606ab` |
| A-R2-ZIP | `8D62769D838C1B359B590F3797EC9C17D809EAC1F1B907A49BF4A9644907625F` |
| Worktree | detached, keine Submodule |
| Produktions-EXE | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` |
| `mangosd.conf` | `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D` |
| `aiplayerbot.conf` | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` |

## Implementierter Produktionsumfang

Exakt neun freigegebene Produktionsdateien wurden geändert beziehungsweise neu angelegt; es gibt keine ungeplante Produktionsdatei:

1. **Neu:** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h`
2. **Neu:** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp`
3. `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h`
4. `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp`
5. `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in`
6. `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp`
7. `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp`
8. `src/modules/PlayerBots/playerbot/PlayerbotAI.h`
9. `src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp`

`src/modules/PlayerBots/CMakeLists.txt` blieb unverändert; dessen bestehender GLOB nimmt die beiden neuen Service-Dateien auf.

## Implementierter Vertrag

### Admission, Queue und Ledger

- Adapter default-off; exakt die Configfelder `Enabled`, `NodeExecutable`, `PackageRoot`.
- Bot-GUID 18281, Whisper-only und echter Zielspieler.
- Höchstens drei lokale Outstanding-Routes entsprechend 1 aktiv + 2 wartend; Completion-Kapazität 3.
- CSPRNG UUIDv4, strikte UTF-8- und Control-Prüfung, höchstens 2.048 Messagebytes.
- `created_utc` und `expires_utc` werden aus demselben Wall-Clock-Snapshot gebildet; die interne 45-Sekunden-Lebensdauer verwendet ausschließlich `steady_clock`.
- Der erste exakt gültige `ledger_full`-Datensatz setzt atomar den permanenten `ledger_exhausted`-Latch. Noch nicht gesendete lokale Routes werden retired; bereits akzeptierte Keys werden weiter gepollt/consumed. Danach entstehen keine weiteren Submitbytes und genau ein strukturiertes Warning.
- Kein Retry, Resubmit oder automatischer Child-Neustart.

### Paket- und Child-Grenze

- Der Core implementiert keinen ZIP-Parser und erhält nur ein bereits extrahiertes absolutes PackageRoot.
- Vor Start: Payload-Manifest-Pin und jede Payload-Datei, Config, Personality und CLI werden geprüft; Pfadescape und Reparse-Ziele werden abgelehnt.
- CLI ausschließlich `PackageRoot/bridge/src/cli.mjs`; Prozessstart ausschließlich direkt über `CreateProcessW`, Argument `--run`, ohne Shell und ohne PATH-Suche.
- Nur die drei Child-Pipeenden werden über `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` vererbt.
- Genau ein joinbarer I/O-Worker. stdout ist strict UTF-8 NDJSON mit 16.384-Byte-Zeilenlimit; stderr wird separat fortlaufend in einen 65.536-Byte-Ringpuffer drainiert.
- Höchstens ein offenes CLI-Kommando. Ready-, Submit-, Status-, Consume-, Metrics- und Shutdown-Envelopes werden gegen exakte Feldmengen, Typen, Nullregeln, Zustände und kontextgebundene Codes geprüft. Unbekannt, zusätzlich, fehlend, Duplicate-Key oder falscher Kontext schließt Admission dauerhaft.
- Shutdown sendet höchstens einmal `drain=true`; nach Timeout kann ausschließlich das besessene Child-Process-Handle terminiert werden. Keine Prozesssuche, keine fremde Node-/Ollama-/Server-/DB-Steuerung.

### World-Grenze und Ausgabe

- Über Threadgrenzen gehen ausschließlich Werte: Request-ID, rohe GUID-Werte, Account-ID, Loginzeit, eindeutige Sessiongeneration, Name, Nachricht, Zeitgrenzen und Completiontext.
- Keine gespeicherten `Player*`, `WorldSession*`, `PlayerbotAI*` oder Packet-Helper-Rohzeiger.
- Vor Zustellung werden Bot, AI, beide Sessions, Accounts, Loginzeiten, Generationen, Zielname, Deadline, Completion, Modell, UTF-8, 240 Codepoints, 240 UTF-8-Bytes, Sanitizer-Kanonicalität und maximal zwei Terminatorläufe im World-Thread erneut geprüft.
- Die Route ist vor exakt einem `bot->Whisper(...)` retired. Die WoW-Protokollsprache wird frisch aus dem Bot-Team abgeleitet; semantisches Englisch wird nicht mit `LANG_COMMON` gleichgesetzt.
- Modelltext besitzt keinen Action-, Emote-, Command-, Tool- oder Alternativkanal. Die Action-Allowlist bleibt leer.
- Bei lokaler Ablehnung, einschließlich Ledger-Latch, fällt der Code in den bestehenden normalen PlayerBot-Antwortpfad zurück. Nicht-LLM-Chat wird nicht global deaktiviert.

## Tests

Der C++-Harness kompiliert die Produktionsimplementierung mit einem ausschließlich testseitigen Standalone-Schalter und startet nur Kopien seiner eigenen Fake-Child-EXE. Ergebnis: **107/107 PASS**, Exitcode 0.

Abgedeckt wurden:

- exakter Ready-Datensatz und vollständige gültige/ungültige Wire-Matrix;
- fehlende/zusätzliche Felder, falsche Typen/nulls, Duplicate Keys, BOM, invalides UTF-8, Trailing JSON, Zeilenlimit, unbekannte und kontextfremde Codes;
- alle Submit-/Status-/Consume-Varianten sowie Metrics-/Shutdown-Envelopes;
- Ready-Timeout, EOF, invalides NDJSON, unsolicited duplicate record;
- 1+2 Queuegrenze, monotone Deadline, exakt 45.000 ms Wire-TTL, Consume-once;
- `ledger_full`-Latch, Retire ungesendeter Routes, Weiterverarbeitung akzeptierter Keys, keine Submitbytes nach Latch;
- 65.536-Byte-stderr-Ring ohne Deadlock und Beibehaltung der neuesten Bytes;
- explizite Handle-Allowlist: ein absichtlich vererbbares fremdes Handle war im Child nicht vorhanden;
- Shutdown-Timeout: nur das eigene hung Fake-Child wurde beendet; der Sentinel blieb bis zu seinem separaten Testevent aktiv;
- Logout/Relog/Sessiongeneration-Mismatch verwirft; gültiger Snapshot erzeugt exakt eine Zustellmarke und keine zweite;
- 240-Byte-Grenze, zwei Sätze, drei Sätze ohne Leerzeichen und Unicode-Ellipse;
- globaler Statuspoll: beobachtet 108 ms, Mindestwert 100 ms.

Das separate statische Gate bestand alle Prüfungen: exakter Dateisatz, kein neuer detach-/`std::async`-Pfad, kein HTTP/Ollama/11434-Code im Service, keine Shell, keine Prozessenumeration, nur eigenes Process-Handle, kein frei wählbarer CLI-Pfad, nur drei Configfelder, Whisper-only, unveränderter Non-LLM-Fallback und keine Action-/Emote-/Command-Zustellung.

## Clean Build

Toolchainprofil:

- CMake 4.4.2
- Visual Studio 17 2022, x64
- MSVC 19.44.35228 / Tools 14.44.35207
- Windows SDK 10.0.26100.0
- Boost 1.92.0 und ACE aus `C:/TW/ComTW/vcpkg/installed/x64-windows`
- identische 02B-CMake-Optionen; `Release/mangosd` als einzig angefordertes Target
- kontrollierte Parallelität: 2 Projekte und `CL_MPCount=2`

Der erste unbeschränkte Versuch wurde wegen Windows-Commit-Limit 1455 (`C3859/C1076`) beendet und vollständig als nicht maßgebliche Evidenz bewahrt. R1 und ein weiterer Zwischenstand linkten erfolgreich, wurden aber wegen anschließend ergänzter, bereits im A-R2-Plan geforderter Eligibility-/Lifecycle-Härtungen nicht als Kandidat gewertet. Der finale R2-Build wurde in einem erneut neuen Buildverzeichnis nach vollständigem Test-PASS erstellt.

Finaler R2-Build:

| Artefakt | Wert |
|---|---|
| `mangosd.exe` SHA-256 | `6601A1961171CDE413DA387773054DE5B83C8A08E6DD01A22B32541F85C32C05` |
| Größe | 20.504.064 Bytes |
| `mangosd.pdb` SHA-256 | `17EC0D798C3250C0E867D71D7756B215DE8DBB5DD9EACEB6EE583532F8FC85B2` |
| CMakeCache SHA-256 | `AE0CC3023C0753CCE1FAB2050F26C15A7CB4FAF1E4F3A637D8B5DAE4AFA32A19` |
| PE | x64 / PE32+ / ImageBase `0x0000000140000000` |
| Link-Zeit | `2026-08-30T16:22:45Z` |
| CodeView GUID | `810BDA8A-EE8A-420B-ABB2-D558569C5833`, Age 1 |
| Eingebettete Revision | `42b8a7f742548793910f` vorhanden |
| Historischer Release-No-op-Marker | vorhanden; der neue externe Adapter ist zusätzlich default-off |
| Finaler Buildfehler | 0 |
| Warnungen | 12 Zeilen: vier bekannte `g3dlite` C4838 und acht bekannte `httplib.h` C4834; keine in den neun Patchdateien |

## Unverändert und nicht ausgeführt

- Produktions-Source-Status vor/nach ist bytegleich als Statusliste; die vier historischen Debugänderungen und sechs PDB-Dateien blieben bestehen und wurden nicht übernommen oder verändert.
- Produktions-EXE, `mangosd.conf` und `aiplayerbot.conf` stimmen mit den verbindlichen Hashes überein.
- Keine aktive Configänderung, kein Deployment, kein Serverstart, kein Game-Chat, kein Datenbankzugriff.
- Das echte English-Correction-Paket und dessen Node-CLI wurden nicht gestartet.
- Kein Ollama-Zugriff und keine Inferenz.
- Phase C wurde nicht begonnen.

## Evidenzindex

- `evidence/final-evidence.json`: Git-, Build-, PE-, PDB-, Produktions- und Hashdaten
- `evidence/full-git-diff.patch`: vollständiger Diff einschließlich beider neuer Dateien
- `source-copies/`: Kopien aller neun Produktionsdateien
- `tests/`: Fake-Child-/Runner- und Static-Gate-Quellen
- `logs/fake-child-tests.tap`: vollständige 107-Test-Ausgabe
- `logs/static-forbidden-paths.json`: statisches Gate
- `logs/configure-final-r2.*` und `logs/build-final-r2*`: maßgebliche Configure-/Buildlogs
- `logs/build.stdout.log`: nicht maßgeblicher Speicherfehler des ersten Versuchs
- `artifacts/mangosd.exe`: nicht gestartete, nicht deployte Clean-Build-EXE
- `SHA256SUMS.txt`: Paketmanifest (wird vor ZIP-Erstellung erzeugt)

Nach diesem Bericht wird keine weitere Phase begonnen.

