# SSC-LLM-PRODUCTION-BRIDGE-01 – Phase B-R1

## Abschluss

`PHASE_B_R1_RESULT=PASS`

Die verlangte Contract-Conformance-Härtung wurde ausschließlich im isolierten Worktree `C:\TW\ssc-llm-phase-b-20260830-173121\source` auf dem unveränderten Baseline-Commit `42b8a7f742548793910fe8880463aeeb71627fb9` (Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`) umgesetzt. Die neun vorgesehenen Produktionsdateien sind die einzigen Source-/Config-Dist-Dateien im isolierten Delta; es gibt keine ungeplante Produktionsdatei.

Die vorherige Phase-B-ZIP blieb unverändert: Größe 8.049.818 Bytes, SHA-256 `510C3E365C959DAD8ACCE30A5DA29D5C6F0B6D268D9AD5DCC8E7A82FF99BE365`.

## Umgesetzte Härtung

### Shutdown und Pipe-I/O

- Shutdown-Flag, Acknowledgement und monotone Shutdown-Deadline werden unter derselben Mutex publiziert und gelesen (`ExternalLLMBridgeService.cpp`, insbesondere Zeilen 1268–1274 und 1621–1637). Ein Zugriff auf eine noch nicht publizierte Deadline ist ausgeschlossen.
- Die drei Child-Kanäle werden als eindeutig benannte Windows-Pipes mit `FILE_FLAG_OVERLAPPED` erzeugt (Zeilen 713–762). Read und Write verwenden echte `OVERLAPPED`-Operationen (Zeilen 779–872); `CancelIoEx` stellt den dokumentierten Abbruchweg bereit.
- Genau stdin, stdout und stderr stehen in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (Zeilen 1138–1159). Andere vererbbare Handles werden im Fake-Child-Test nachweislich nicht vererbt.
- Der Worker ist joinbar. Timeout-Cleanup terminiert nur das aus dem eigenen `CreateProcessW` stammende Prozesshandle, wartet auf den Worker und schließt die eigenen Pipe-, Thread- und Prozesshandles. `Start()==false` ist für Timeout, EOF, ungültiges NDJSON, Ready-Mismatch, Fatal-Envelope, CreateProcess- und Pipefehler erst nach Cleanup möglich.
- Ein Child, das stdin nicht liest, beendet den Shutdown-Pfad im Test nach 260 ms bei einer absichtlich auf 250 ms verkürzten Testdeadline; Sentinel-Fremdprozesse bleiben unberührt.

### Admission und Wire-Vertrag

- Der Service akzeptiert ausschließlich Bot-GUID `18281` und lehnt ECMAScript-trim-leere Nachrichten vor UUID-, Route- oder Wire-Erzeugung ab (Zeilen 137–178 und 1065–1077). ASCII-Leerraum, NBSP und BOM sind getestet; der Child-Submit-Zähler bleibt null.
- UTC-Werte werden als reale gregorianische Kalenderwerte validiert, einschließlich Schaltjahr-, Monats-, Tages- und Zeitgrenzen (Zeilen 180–231). Unmögliche Daten wie 2026-02-29, 2026-04-31, Stunde 24 oder Sekunde 60 werden verworfen.
- Ready-, Submit-, Status-, Consume-, Metrics-, Shutdown-, Fatal- und CLI-Error-Envelopes sind exakt feld-, typ-, null- und kontextgebunden. Zusätzliche oder unbekannte Felder und Codes schließen fail-closed.
- `queue_full` und `expired_before_run` sind ausschließlich Attempt 0; `shutdown_cancelled` und `shutdown_timeout` erlauben Attempt 0 oder 1; alle übrigen terminalen Fehler benötigen Attempt 1. Outcome, Error, Model, `started_utc`, `raw_response_bytes` und Text werden gemeinsam validiert (Zeilen 341–478).
- Der vollständige A-R2-Vertrag liegt unverändert als `bridge-contract-v1.json` bei. Die 683 Tests bilden jede gültige Antwortvariante, jede Envelope-Mutation und die vollständige Completion-Error-/Attempt-Matrix ab.

### World-Thread-Revalidierung

- Über die Threadgrenze gehen nur Wertdaten. Route, Session-Fingerprint und Completion-Evidenz enthalten keine `Player*`, `WorldSession*`, Bot- oder AI-Rohzeiger.
- Eine konsumierte Completion bleibt als `DeliveryPending` an ihre Route gebunden (Zeilen 641–678 und 1460–1474).
- Im World-Thread werden vor Zustellung Request-ID, Bot-GUID, `ready`, Modellpin, Attempt 1, null Error, Raw-Byte-Grenze, Textkanonizität, monotone Deadline sowie Bot-/Target-/Sessiongeneration und Whisperroute erneut geprüft (Zeilen 1214–1257).
- Erst nach erfolgreicher Revalidierung wird die Route retirert; danach erfolgt höchstens ein Whisper. Die Standalone-Suite prüft nur den wertbasierten Delivery-Token und behauptet ausdrücklich keinen echten Server-Whisper.

### Package-Verifier

- Ursprüngliche absolute PackageRoot-Komponenten werden vor Kanonisierung auf Reparse Points/Junctions geprüft (Zeilen 936–981).
- Die Manifestdatei und jeder manifestierte ursprüngliche Payloadpfad werden ebenfalls geprüft. Stream-, Open-, Badbit-, Failbit- und vorzeitige EOF-Fehler führen fail-closed.
- Der CLI-Pfad ist fest aus `PackageRoot/bridge/src/cli.mjs` abgeleitet. Der Core enthält weiterhin keinen ZIP-Parser; ZIP-Prüfung und Extraktion bleiben Aufgabe des späteren Deployment-Werkzeugs.
- Tests umfassen sichere Fake-Payload, Root-, Bridge- und Payload-Junctions, gesperrtes Manifest sowie abgeschnittenes Manifest.

## Tests und statisches Gate

- Finaler Fake-Child-/Vertragstest: `683/683`, keine Fehler.
- Unmittelbarer Reproduzierbarkeitslauf: ebenfalls `683/683`, keine Fehler.
- Statisches Gate: alle 27 Prüfungen `true`. Es bestätigt unter anderem exakte neun Dateien, Overlapped-I/O, gemeinsame Shutdown-Synchronisation, Start-Cleanup, Admission-Parität, reale UTC-Prüfung, vollständige Completion-Matrix, World-Evidenz, Reparse-Prüfung, abgeleiteten CLI-Pfad, drei Configschlüssel, leere Action-Fläche, keinen Ollama-/HTTP-Pfad und ausschließlich eigenen Prozessabbruch.
- Eine im Evidenzlauf erkannte variable TAP-Zählung wurde im Test selbst deterministisch gemacht: Der Cleanup-Assert für eine absichtlich unmittelbar nach Ready gesendete zusätzliche Antwort wird nun unabhängig davon ausgegeben, ob der Fehler noch in `Start()` oder direkt danach sichtbar wird. Beide Ausführungspfade prüfen dieselbe Cleanup-Invariante.

Die vollständigen TAP-Protokolle stehen unter `logs/fake-child-tests.tap` und `logs/fake-child-tests-reproducibility.tap`; das statische Ergebnis unter `logs/static-gate.log`.

## Clean Build

Der erfolgreiche neue Build erfolgte in `C:\TW\ssc-llm-phase-b-20260830-173121\build-r1-clean-final2` ausschließlich als `Release/mangosd`:

- CMake 4.4.2, Generator Visual Studio 17 2022 x64
- MSVC 19.44.35228 / Toolset 14.44.35207
- Windows SDK 10.0.26100.0
- ACE und Boost aus `C:\TW\ComTW\vcpkg\installed\x64-windows`
- Projektparallelität 2, Compiler `/MP2`
- vollständige Optionen: `evidence/build-options.json` und `evidence/CMakeCache.txt`

Eine erste, reine Configure-Ausführung in einem anderen neuen Buildverzeichnis scheiterte vor jedem Build, weil die zusätzlich rekonstruierte Legacy-Definition `PREFIX` mit dem CMake-4.4-Compiler-ID-Makro kollidierte. Es entstand dabei kein Kandidat. Der erfolgreiche Lauf verwendete ausschließlich `CMAKE_INSTALL_PREFIX`, wie der vorherige saubere Referenzbuild. Beide Configure-Protokolle bleiben vollständig erhalten.

Der erfolgreiche Build enthält 12 bereits bekannte Warnungsdiagnosen: viermal C4838 in `dep/src/g3dlite/System.cpp` und achtmal C4834 in `src/shared/httplib.h`. Fehlerdiagnosen: 0. Keine Warnung stammt aus dem R1-Delta.

### Kandidatenartefakte

- `mangosd.exe`: 20.523.520 Bytes, SHA-256 `1231B38B3EA8C241742B3735C13515DA0A0A98158F3ADE96FDBB7EA0AFB3718C`
- `mangosd.pdb`: 213.422.080 Bytes, SHA-256 `E07BD3E178D649CBB4A3194CA02F7664934BDF3146F2451FC2A09DCDFC80E325`
- `CMakeCache.txt`: SHA-256 `31901FD828F112E76DFBD1A8D1F6194B9D691E94F74E9C4261325F21385B016C`
- PE-Linkerzeit: `2026-08-30T18:11:29Z`
- CodeView: RSDS, GUID `810BDA8A-EE8A-420B-ABB2-D558569C5833`, Age 2
- Eingebettete Revision `42b8a7f742548793910f`: vorhanden
- Release-No-op-Marker `LLM generation disabled in this build`: vorhanden

Die PDB wird wegen ihrer Größe nicht in das Deliverable kopiert; Hash, Größe, Zeitstempel und CodeView-Verknüpfung sind vollständig in `evidence/final-evidence.json` dokumentiert. Die neue EXE liegt in `artifacts/mangosd.exe` und wurde nicht gestartet.

## Produktionsschutz

Vor R1 und nach Abschluss wurden `git status --short --untracked-files=all` sowie Größe und SHA-256 jeder bereits schmutzigen Produktionsdatei live erhoben. Es wurde keine fest codierte Before-Liste als Beweis verwendet.

Die zehn vorgefundenen Dirty-Tree-Dateien (vier geänderte Sources, sechs unversionierte PDBs) sind in Status, Größe und SHA-256 byteidentisch. Auch Produktions-EXE, aktive Configs und vorherige Phase-B-ZIP sind unverändert. Der maschinenlesbare Einzelvergleich steht in `evidence/production-byte-comparison.json`.

- Produktions-EXE: `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`
- `mangosd.conf`: `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`
- `aiplayerbot.conf`: `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`

Es gab kein Deployment, keine aktive Configänderung, keinen Datenbankzugriff, keinen Start der echten Bridge, keinen Ollama-Zugriff, keine Inferenz, keinen Game-Chat und keinen Start von Phase C.

## Ergebnisblock

```text
PHASE_B_R1_RESULT=PASS
SHUTDOWN_SYNCHRONIZATION=PASS
OVERLAPPED_PIPE_IO=PASS
FAILED_START_CLEANUP=PASS
ADMISSION_PARITY=PASS
WIRE_CONTRACT_MATRIX=PASS
WORLD_COMPLETION_REVALIDATION=PASS
PACKAGE_VERIFIER_TESTS=PASS
FAKE_CHILD_TESTS=PASS_683_OF_683
CLEAN_BUILD_RESULT=PASS
CANDIDATE_EXE_SHA256=1231B38B3EA8C241742B3735C13515DA0A0A98158F3ADE96FDBB7EA0AFB3718C
PRODUCTION_SOURCE_BYTE_IDENTICAL=YES
PRODUCTION_EXE_CHANGED=NO
ACTIVE_CONFIG_CHANGED=NO
REAL_BRIDGE_STARTED=NO
OLLAMA_ACCESSED=NO
INFERENCE_PERFORMED=NO
GAME_CHAT_SENT=NO
DEPLOYMENT_PERFORMED=NO
PHASE_C_STARTED=NO
```
