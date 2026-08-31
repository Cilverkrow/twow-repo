# SSC-LLM-PRODUCTION-BRIDGE-01 – Phase A-R2 Implementation Closure

## Ergebnis

`PHASE_A_R2_IMPLEMENTATION_CLOSURE_RESULT=PASS`

A-R2 ist eine ausschließlich read-only Vertragskorrektur auf Basis von Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`, und dem unveränderten English-Correction-Paket. Es wurden weder Core-Source noch aktive Config geändert. Phase B wurde nicht begonnen.

## Unveränderte aktive Pins

| Artefakt | SHA-256 |
|---|---|
| English-Correction-ZIP | `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434` |
| Root-Manifest | `522D3358D28D7A8CC69DEF1D385A38399557F6E2C9BED777565C6CB4A403353C` |
| Payload-Manifest | `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B` |
| Bridge-Config | `D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902` |
| Personality V1 | `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E` |
| CLI `bridge/src/cli.mjs` | `C5D2C01DB3AEBBBF65A2ECFACC1515326334220A5F79395DF3E24550345CA611` |

Die bisherigen relevanten Deliverable-ZIPs wurden vor dieser Arbeit erneut gehasht: Phase A `A4EB4552EF029C41F61D9BF4F247332F0239A5058FC32EE7ECCF1961EAF79A9D`, A-R1 `3E76B24071B7806BF7412477EBCF9A6F6A8A9B3EC8AC31390350540553943EC1` und English-Correction wie oben. Sie werden nach der A-R2-Paketbildung erneut geprüft.

## 1. Ledger-full-Latch

Die externe Bridge speichert bei `ledger_full` keinen Request und führt keinen Attempt aus (`bridge/src/bridge.mjs:116-118`). Für den Core gilt deshalb ab der ersten syntaktisch und semantisch korrekten Submit-Antwort

```json
{"accepted":false,"code":"ledger_full","status":null}
```

ein irreversibler Latch für genau diese Child-Instanz:

- Adapterzustand wird atomar `ledger_exhausted`;
- der auslösende lokale Request wird ohne Completion retired;
- es wird kein weiteres `submit` an diese Child-Instanz geschrieben;
- neue External-LLM-Anfragen werden vor UUID-/Route-Erzeugung lokal mit `locally_rejected_ledger_exhausted` abgelehnt;
- bereits zuvor akzeptierte Keys dürfen weiter ausschließlich mit `status` gepollt und genau einmal `consume`d oder lokal verworfen werden;
- Logging erfolgt höchstens einmal pro Child-Instanz, weitere Treffer werden gedrosselt beziehungsweise unterdrückt;
- kein Retry, Resubmit, Child-Neustart, Ersatzprozess oder Fallback-LLM;
- der Latch wird nur durch einen später ausdrücklich autorisierten manuellen Neustart mit neuer Child-Instanz zurückgesetzt.

Der Latch liegt ausschließlich im External-LLM-Service. Er ändert weder Playerbot-Manager noch normale Chat-, Command- oder AI-Zustände. Ein lokales External-Reject darf bestehenden Nicht-LLM-PlayerBot-Chat nicht unterdrücken; es gibt jedoch keinen anderen LLM-Fallback.

Ein `ledger_full` in einem falschen Envelope, mit zusätzlichen/fehlenden Feldern, falschen Typen oder als Antwort auf ein anderes Kommando löst nicht den Latch aus, sondern den strengeren Zustand `protocol_failed` mit dauerhaft geschlossener Admission.

## 2. Vollständiger Wire-Vertrag

Der vollständige maschinenlesbare Vertrag steht in `bridge-contract-v1.json`. Er ist direkt aus folgenden unveränderten Artefaktstellen abgeleitet:

- Ready und CLI-Dispatch: `bridge/src/cli.mjs:76-143`;
- Admission, Status, Consume und Metrics: `bridge/src/bridge.mjs:83-249`;
- terminale Transitionen und Shutdown: `bridge/src/bridge.mjs:271-576`;
- Request-, Status- und Completion-Invarianten: `bridge/src/contracts.mjs:72-190` und `bridge/schemas/*.schema.json`;
- striktes NDJSON/JSON: `bridge/src/ndjson.mjs:3-23`, `bridge/src/strict-json.mjs:5-239`;
- Transport-/Completion-Fehler: `bridge/src/transport.mjs:9-484`, `bridge/src/prompt.mjs:24-43`.

Der Vertrag enthält:

- den exakten Ready-Datensatz mit sieben Feldern;
- normale CLI-Kommandofehler exakt `{code,message}`;
- das davon getrennte fatale Top-Level-Envelope `{result,code,message}` mit festem `result=PHASE1A_BRIDGE_ERROR`;
- exakte Request- und Response-Felder sowie kontextgebundene Resultcodes für `submit`, `status`, `consume`, `metrics`, `shutdown`;
- die zehn exakten Metrics-Felder;
- die acht exakten Status-Felder und sechs States;
- die elf exakten Completion-Felder;
- Ready-, Nonready-, Consumed- und Null-Invarianten;
- einen katalogisierten Satz zulässiger Fehlercodes pro Kontext.

Jeder unbekannte Code, jedes unbekannte oder fehlende Feld, falscher Typ, unzulässiges `null`, falsche Zustandskombination, unerwartete Antwortreihenfolge oder zweite Antwort auf ein Kommando schließt die Admission dauerhaft. Der Core hält genau ein CLI-Kommando gleichzeitig offen; die Antworten besitzen keine Korrelations-ID und werden daher streng seriell zugeordnet.

## 3. Paketzuständigkeit

Die frühere A-R1-Formulierung, der Core solle ZIP, äußeren ZIP-Hash oder Root-Manifest verarbeiten, wird aufgehoben.

Verbindliche Trennung:

1. Ein separat freizugebendes Deployment-Werkzeug prüft äußeren ZIP-Hash, doppelte/absolute/entweichende Pfade, Symlink-/Reparse-Sicherheit und Root-Manifest und extrahiert ausschließlich in ein neues, zuvor nicht vorhandenes PackageRoot.
2. Der Core enthält keinen ZIP-Parser, extrahiert nichts und erhält nur ein bereits extrahiertes absolutes PackageRoot.
3. Vor jedem Child-Start prüft der Core das Payload-Manifest gegen den aktiven Pin und anschließend jede darin referenzierte Payloaddatei. Zusätzlich müssen Config, Personality und CLI ihre Einzelpins erfüllen.
4. Der CLI-Pfad ist unveränderlich `PackageRoot/bridge/src/cli.mjs`; es gibt keine `.CliScript`-Configoption.
5. Pfadnormalisierung, Reparse-/Symlink-Escape, fehlende/zusätzliche Manifestzuordnung oder Hashfehler schließen die Admission vor Prozessstart.

Phase B deployt oder extrahiert kein Produktionspaket und ändert keine aktive Config.

## 4. Child-Lifecycle

```text
CORE_READY_TIMEOUT_MS=35000
CORE_STATUS_POLL_INTERVAL_MS=100
CORE_SHUTDOWN_OVERALL_TIMEOUT_MS=40000
CORE_STDERR_DIAGNOSTIC_CAP_BYTES=65536
```

- stdout ist ausschließlich strict-UTF-8-NDJSON-Protokoll. Leere, übergroße, ungültige oder kontextfremde Zeilen sind fatal.
- stderr wird von Beginn an separat und fortlaufend drainiert. Ein 65.536-Byte-Ringpuffer behält nur die jüngsten Diagnosebytes; ältere Bytes werden verworfen, das Drainieren läuft weiter. stderr wird nie als Protokoll oder Modelltext interpretiert.
- `CreateProcessW` erbt ausschließlich die ausdrücklich in einer Handle-Liste freigegebenen Child-Enden der drei Pipes; alle anderen Handles bleiben nicht vererbbar.
- Ready muss innerhalb von 35.000 ms nach erfolgreichem Prozessstart vollständig eintreffen.
- Nach Ready pollt der Worker ausstehende Requests mit einem globalen Mindestintervall von 100 ms, ohne je erneut zu submitten.
- EOF, Child-Abbruch, Timeout, ungültiges NDJSON oder Ready-/Response-Mismatch führen zu permanent geschlossener Admission für diese Instanz; kein Auto-Restart.
- Normaler Shutdown sendet genau einmal `{"command":"shutdown","drain":true}` und hat eine Core-Gesamtfrist von 40.000 ms für Response, Workerabschluss und Child-Ende.
- Bei Fristablauf darf ausschließlich über das bei `CreateProcessW` erhaltene, weiterhin besessene Process-Handle genau dieses Child beendet werden. Keine Namens-/PID-Suche und kein Zugriff auf fremde Node-, Ollama-, mangosd-, realmd- oder sonstige Prozesse. Danach Worker joinen und alle eigenen Handles schließen.

## 5. Phase-B-Grenze

Node-Runtime und extrahiertes PackageRoot bleiben bis zu einem gesonderten Deployment-Gate reine Referenzen. Eine später separat freigegebene Phase B darf ausschließlich umfassen:

- isolierte Sourceimplementierung des deaktivierten Adapters;
- Fake-Child-/Unit-/World-Thread-Tests ohne echte Bridge oder Ollama;
- isolierten Clean Build.

Nicht Teil von Phase B sind Deployment, Paketextraktion in den Produktivpfad, aktive Config, Prozessbetrieb, echte Bridge-Inferenz, Ollama-Zugriff oder Game-Chat.

## Abschlussblock

```text
SSC_LLM_PRODUCTION_BRIDGE_01_PHASE_A_R2_RESULT=PASS
PHASE_A_R2_IMPLEMENTATION_CLOSURE_RESULT=PASS
LEDGER_FULL_LATCH=REQUIRED
LEDGER_FULL_LATCH_RESET=MANUAL_RESTART_ONLY
WIRE_CONTRACT=COMPLETE_CONTEXT_BOUND_FAIL_CLOSED
CORE_ZIP_PARSER=NO
DEPLOYMENT_TOOL_OWNS_ZIP_AND_ROOT_MANIFEST=YES
CORE_RECEIVES_EXTRACTED_ABSOLUTE_PACKAGE_ROOT=YES
CLI_PATH=PackageRoot/bridge/src/cli.mjs
FREE_CLI_SCRIPT_OPTION=NO
CORE_READY_TIMEOUT_MS=35000
CORE_STATUS_POLL_INTERVAL_MS=100
CORE_SHUTDOWN_OVERALL_TIMEOUT_MS=40000
CORE_STDERR_DIAGNOSTIC_CAP_BYTES=65536
AUTOMATIC_RETRY_OR_RESUBMIT=NO
AUTOMATIC_CHILD_RESTART=NO
SOURCE_FILES_CHANGED=NO
ACTIVE_CONFIG_CHANGED=NO
BUILD_STARTED=NO
DATABASE_ACCESSED=NO
PROCESS_CONTROL_PERFORMED=NO
INFERENCE_PERFORMED=NO
GAME_CHAT_SENT=NO
PHASE_B_STARTED=NO
PHASE_B_SCOPE=ISOLATED_IMPLEMENTATION_FAKE_CHILD_TESTS_CLEAN_BUILD_ONLY
```
