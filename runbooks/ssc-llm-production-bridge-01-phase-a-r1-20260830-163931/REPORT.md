# SSC-LLM-PRODUCTION-BRIDGE-01 – Phase A-R1 Contract Refresh

## Ergebnis

`PHASE_A_R1_CONTRACT_REFRESH_RESULT=PASS`

Die Delta-Aktualisierung ist vollständig read-only erfolgt. Die geprüfte Stable-Source-Baseline bleibt Commit `42b8a7f742548793910fe8880463aeeb71627fb9` mit Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`. Der aktive externe Bridge-Vertrag ist jetzt ausschließlich auf das English-Correction-Paket und dessen neue Manifest-, Config- und Personality-Hashes gepinnt. Phase B wurde nicht begonnen.

Dieser PASS bestätigt den aktualisierten Entwurf und die Artefaktprovenienz. Er ist keine Freigabe für Source-Änderung, Config-Aktivierung, Build, Deployment oder Laufzeitbetrieb.

## Verifizierte aktive Artefaktkette

| Ebene | Aktiver SHA-256 | Verifikation |
|---|---|---|
| English-Correction-ZIP | `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434` | Datei erneut gehasht; 112.411 Bytes; 78 eindeutige ZIP-Einträge |
| Root-Manifest `SHA256SUMS.txt` | `522D3358D28D7A8CC69DEF1D385A38399557F6E2C9BED777565C6CB4A403353C` | 77 Manifestzeilen; alle 77 referenzierten ZIP-Einträge stimmen |
| Payload-Manifest `bridge/sha256-manifest.txt` | `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B` | Gegen Root-Manifest und ZIP-Inhalt verifiziert |
| Config `bridge/config/bridge-config-v1.json` | `D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902` | Gegen Manifest und ZIP-Inhalt verifiziert |
| Personality `bridge/context/personality-context-profile-v1.json` | `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E` | Gegen Config-Pin, Manifest und ZIP-Inhalt verifiziert |

Die unveränderte ältere Phase-A-Auslieferung wurde vor und nach dieser Arbeit mit SHA-256 `A4EB4552EF029C41F61D9BF4F247332F0239A5058FC32EE7ECCF1961EAF79A9D` bestätigt. Das English-Correction-ZIP wurde ebenfalls nicht verändert und behielt den oben angegebenen Hash.

Der vor der English-Correction verwendete Payload-Pin ist aufgehoben und erscheint in diesem A-R1-Paket nicht als aktiver Wert. Es gibt genau einen aktiven Payload-Manifest-Pin: `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B`.

## Aktualisierter V1-Vertrag

### Identität und Transport

- Der Core startet ausschließlich das gepinnte externe Child über `src/cli.mjs --run` und kommuniziert über genau eine NDJSON-stdin/stdout-Verbindung. Der Core enthält keinen Ollama-Client und spricht niemals direkt mit `127.0.0.1:11434`.
- Die Request-Identität ist das unveränderliche Paar `request_id + bot_guid`; `request_id` ist eine neue kanonische lowercase UUIDv4, `bot_guid` ist fest `18281`.
- Submit, Status und Consume entsprechen `bridge/src/cli.mjs:118-143`. Status-Polling erzeugt keine Inferenz. Ein Request wird exakt einmal submitted und eine terminale Completion exakt einmal consumed.
- Der Ready-Datensatz muss exakt Modus `server_free_ndjson`, aktiv `1`, wartend `2`, Ledger `64`, Bot `18281` und Modell `qwen2.5:7b` melden (`bridge/src/cli.mjs:76-84`).

### Request und Lebensdauer

Der Request besitzt ausschließlich `schema_version`, `request_id`, `bot_guid`, `created_utc`, `expires_utc` und `message`. `created_utc` und `expires_utc` bleiben Wire-Evidenz. Bei lokaler Request-Erzeugung wird gleichzeitig eine 45-Sekunden-Deadline aus `steady_clock` gebildet; die Bridge leitet bei Admission ihre interne monotone Deadline aus der akzeptierten Wire-Lebensdauer ab (`bridge/src/bridge.mjs:93-126`). Weder Wallclock-Sprünge noch Polling dürfen die Lebensdauer verlängern oder verkürzen.

### Kapazitäten und Fail-closed-Verhalten

- genau eine aktive Inferenz;
- genau zwei wartende Bridge-Requests;
- Ledger-Kapazität 64;
- maximal drei lokal ausstehende Core-Routen und eine begrenzte Completion-Queue mit Kapazität drei;
- `ledger_full` ist fail-closed: keine Speicherung, kein Versuch, kein Evict und kein Fallback (`bridge/src/bridge.mjs:116-118`);
- `queue_full`, Duplicate, Identity-Mismatch, Stale Result, Expiry und Consume-once bleiben unverändert;
- keine Retries, Resubmits, Modell-Fallbacks oder automatischen Child-Neustarts.

### Output und Wirkung

- Die gepinnte Systemregel und Personality-Regel verlangen immer englischen Dialog, unabhängig von der Eingabesprache (`bridge/config/bridge-config-v1.json:36`, `bridge/context/personality-context-profile-v1.json:20`). Das ist die semantische Ausgabesprachenregel des Modells, keine WoW-Protokollsprache.
- Der bereinigte Text darf höchstens 240 Unicode-Codepoints und höchstens 240 UTF-8-Bytes besitzen. Beide Grenzen gelten gleichzeitig. Bei Überschreitung wird der gesamte Text verworfen; es gibt kein Abschneiden und damit kein Zerschneiden eines UTF-8-Zeichens (`bridge/src/prompt.mjs:35-43`, `bridge/state-and-error-contract.md:58-60`).
- Die Satzgrenze bleibt zwei maximale zusammenhängende Terminatorläufe aus `.`, `!`, `?` und `…`, auch ohne nachfolgendes Whitespace.
- V1 liefert ausschließlich genau einen Whisper an den bereits geprüften Zielspieler. Die Action-Allowlist ist leer. Modelltext wird niemals als Botaktion, Emote, Chat-/Serverbefehl, Toolaufruf oder alternativer Zustellkanal interpretiert.

### Englisch ist nicht `LANG_COMMON`

Die natürliche Ausgabesprache `English` darf nicht in einen festen WoW-Protokollwert übersetzt werden. Die Baseline verwendet in `PlayerbotAI.cpp:3607-3614` eine fraktionsabhängige Whisper-Sprache: Alliance `LANG_COMMON`, Horde `LANG_ORCISH`. Bot 18281 ist durch den gepinnten Context als Undead/Horde beschrieben. Eine spätere Zustellung muss deshalb nach erneuter Bot-/Sessionprüfung die bestehende teamabhängige Protokollwahl anwenden; sie darf nicht wegen englischem Text blind `LANG_COMMON` setzen. Der Bridge-Vertrag führt kein Feld für die WoW-`Language`-Enum ein.

### Zustellgrenze

Completion-Text darf den World-Thread erst nach erneuter Prüfung von Outstanding-Key, lokaler monotone Deadline, Completion-Schema, Modellpin, Versuchszähler, Byte-/Codepoint-/Satzgrenzen sowie Bot-, Ziel- und Sessiongeneration erreichen. Queues speichern nur Werttypen: UUID, GUIDs, Account-/Sessionfingerprints, Zeiten, State und Text. Kein `WorldSession*`, `Player*`, Bot-, AI- oder Packet-Rohzeiger überlebt den World-/AI-Thread.

## Historische Evidenz

`bridge/phase1a-report.md` im unveränderten Correction-Paket ist ausschließlich `historical_evidence_only`. Insbesondere seine Aussagen zu einem früheren Personality-Profil und früheren Runtime-/Context-Hashes in den Zeilen 25, 30 und 32 sind historische Phase-1A-Aussagen, keine aktiven A-R1-Pins. Die Datei wird weder als aktive Config noch als Vertragsquelle geladen. Ihre Bytes bleiben wegen der unveränderten, manifestierten Paketprovenienz erhalten.

## Source-Delta

Es wurde kein Source-Diff erzeugt. Der aktualisierte, datei- und zeilengenaue Plan steht in `MINIMAL-PATCH-PLAN.md`. Die vier früheren LLM-Debugänderungen bleiben lediglich klassifizierte historische Vergleichsevidenz; keine davon wird in den Produktionspatch übernommen. `PlayerbotLLMInterface.cpp:376-382` bleibt Release-No-op, die detached Helfer `PlayerbotAI.cpp:7978-8006` werden nur in einer später separat autorisierten Implementierungsphase entfernt, und RPG-/Emote-Pfade werden nicht angebunden.

## Grenzen dieser Phase

- Core-Source geändert: nein
- aktive Config geändert: nein
- Build oder Kompilierung: nein
- Datenbankzugriff: nein
- Prozesssteuerung oder Listenerprüfung: nein
- Bridge-/Ollama-Inferenz: nein
- Game-Chat: nein
- Phase B begonnen: nein

## Abschlussblock

```text
SSC_LLM_PRODUCTION_BRIDGE_01_PHASE_A_R1_RESULT=PASS
PHASE_A_R1_CONTRACT_REFRESH_RESULT=PASS
BASELINE_COMMIT=42b8a7f742548793910fe8880463aeeb71627fb9
BASELINE_TREE=b2cf4e38fd288a53f61b9f2350f74caa85d606ab
ACTIVE_CORRECTION_ZIP_SHA256=36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434
ACTIVE_ROOT_MANIFEST_SHA256=522D3358D28D7A8CC69DEF1D385A38399557F6E2C9BED777565C6CB4A403353C
ACTIVE_PAYLOAD_MANIFEST_SHA256=814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B
PRE_CORRECTION_PAYLOAD_PIN_ACTIVE=NO
ACTIVE_CONFIG_SHA256=D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902
ACTIVE_PERSONALITY_SHA256=386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E
PERSONALITY_FILE=personality-context-profile-v1.json
OUTPUT_LANGUAGE=ENGLISH_REGARDLESS_OF_INPUT
MAX_OUTPUT_CODEPOINTS=240
MAX_OUTPUT_UTF8_BYTES=240
OVERLIMIT_BEHAVIOR=REJECT_WHOLE_TEXT_NO_TRUNCATION
PINNED_BOT_GUID=18281
V1_DELIVERY_CHANNEL=WHISPER_ONLY
V1_ACTION_ALLOWLIST=EMPTY
ACTIVE_INFERENCE_LIMIT=1
WAITING_CAPACITY=2
LEDGER_CAPACITY=64
LEDGER_FULL_BEHAVIOR=FAIL_CLOSED
AUTOMATIC_RETRY_OR_RESUBMIT=NO
AUTOMATIC_BRIDGE_RESTART=NO
ENGLISH_EQUALS_LANG_COMMON=NO
HISTORICAL_PHASE1A_REPORT_ACTIVE_CONTRACT=NO
HISTORICAL_PHASE1A_REPORT_CLASSIFICATION=HISTORICAL_EVIDENCE_ONLY
SOURCE_FILES_CHANGED=NO
CONFIG_FILES_CHANGED=NO
BUILD_STARTED=NO
DATABASE_ACCESSED=NO
PROCESS_CONTROL_PERFORMED=NO
INFERENCE_PERFORMED=NO
GAME_CHAT_SENT=NO
PHASE_B_STARTED=NO
PHASE_B_GATE=AWAIT_SEPARATE_AUTHORIZATION
```
