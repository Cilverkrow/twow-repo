# SSC-LLM-PRODUCTION-BRIDGE-01 – Phase A

Erstellt: 2026-08-30 (Europe/Berlin)  
Arbeitsart: ausschließlich read-only Analyse; geschrieben wurden nur neue Runbook-/Evidenzdateien in diesem Verzeichnis.

## Entscheidung

`PHASE_A_RESULT=PASS`

Der unveränderte Baseline-Commit bietet einen klaren World-/Playerbot-Thread-Pfad für eine externe, strikt begrenzte Bridge. Der Minimalpatch kann ohne Übernahme der vier historischen Debugänderungen entworfen werden. Die neue Integration wird getrennt vom vorhandenen `PlayerbotLLMInterface` angelegt, verwendet genau einen joinbaren, besitzenden I/O-Worker, übergibt ausschließlich Wertdaten und stellt Modelltext nur als private Whisper-Nachricht zu.

Phase B wurde nicht begonnen. Der PASS ist keine Freigabe für Source-Änderung, Build, Deployment oder Laufzeittest.

## Verbindliche Baseline und geprüfte Artefakte

| Gegenstand | Ergebnis |
|---|---|
| Git-Commit | `42b8a7f742548793910fe8880463aeeb71627fb9` |
| Git-Tree | `b2cf4e38fd288a53f61b9f2350f74caa85d606ab` |
| Clean-Build-EXE | `2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE`, 20,378,624 Bytes, erneut `MATCH` |
| Phase-1B-Deliverable-ZIP | `020BDBA7BDE016FEACD2E484818E02BFAD8BE792AD84735BDEA845C2A2D9A5C8`, 200,585 Bytes, 93 sichere/eindeutige Einträge |
| Bridge-Payload-Manifest | `7494F26C2CBA47084691D57ED7DEA372B5E895C90F58FF86304101B48305FA8E` |
| Phase-1B-Ergebnis | Offline-/Paketprüfung PASS; Live-Lauf: genau ein Inferenzversuch, keine Wiederholung, `max_active_observed=1`, Worker beendet |

Alle Core-Fundstellen wurden mit `git show <commit>:<path>` beziehungsweise `git grep <commit>` aus dem Commitobjekt gelesen. Damit beeinflussen Working-Tree-Zeilenenden, unversionierte PDBs oder der Dirty-Tree die Baselineanalyse nicht.

## Historische vier LLM-Debugänderungen

Die vier Änderungen sind unverändert als vollständiger Diff gesichert: `evidence/historical-llm-debug-working-tree.diff`, SHA-256 `B799D4DD42EF9E0CC261419043BF889D6AFF2526CACFE156C6C465787D9492AC`. Sie umfassen zusammen 495 Einfügungen und 16 Löschungen.

| Datei | Baseline-Blob | Klassifikation | Produktionsübernahme |
|---|---|---|---|
| `src/modules/PlayerBots/CMakeLists.txt` | `43b500056fe25e0b89e0bc68008fa91765570dc6` | zusätzliches `dep/include`; nur für Debug-HTTP-Code benötigt | NEIN |
| `playerbot/PlayerbotLLMInterface.cpp` | `3b9cadb778434d48c0a5129cbe0b976fcbe9e6f7` | direkter HTTP-Client, frei konfigurierbarer Endpoint/API-Key, OpenAI-artige Antwortauswertung | NEIN |
| `playerbot/PlayerbotLLMInterface.h` | `8b17e5e3b4eab0d59fc913508545087cbfa10de3` | Singleton-Status über Mutex/Future und Account-ID statt `request_id + bot_guid` | NEIN |
| `strategy/actions/DebugAction.cpp` | `1e388d197a5a1b781711f4c3331c9924da531e18` | manuelles `llm`/`llm result`, Chat-Ausgabe und accountbezogene Zuordnung | NEIN |

Die Debugvariante hat keine strikte UUID-/Envelope-Prüfung, keine unveränderlichen keyed Envelopes, keine Bridge-Ledger-Semantik, keine monotone Lebensdauer, keine verifizierte Modell-/Kontextbindung und keine consume-once-Zustellung. Vor allem umgeht ihr direkter HTTP-Pfad die externe Bridge. `DEBUG_CHANGES_ADOPTED=0`.

## Istzustand der Baseline

- `PlayerbotLLMInterface.cpp:376-382` ist der geprüfte Release-No-op: `Generate` gibt leer zurück und führt keinen Netzwerkaufruf aus.
- `SayAction.cpp:512-669` enthält dennoch den historischen asynchronen Aufrufpfad; `PlayerbotAI.cpp:7978-8006` hält zwei detached-Thread-Helfer. Diese Konstruktion darf für die neue Integration nicht verwendet werden.
- `RpgSubActions.cpp:409-563` erzeugt Legacy-Prompts und kann Text/Emote-Pakete vorbereiten; `RpgTriggers.cpp:627-639` schaltet den Pfad über Legacy-LLM-Konfiguration. Die externe V1-Bridge wird dort ausdrücklich nicht angebunden.
- `PlayerbotAI.cpp:1189-1213`, `1469-1560` und `strategy/ExternalEventHelper.h:14-92` bilden einen umfangreichen Befehls-/Aktionspfad. Completion-Text darf diesen Pfad niemals erreichen.

## Exakter externe-Bridge-Vertrag

Das maschinenlesbare Vollbild steht in `evidence/bridge-contract-v1.json`. Maßgebliche Quellen sind die geprüften Phase-1B-Dateien `src/cli.mjs`, `src/contracts.mjs`, `src/bridge.mjs`, `src/transport.mjs`, `src/prompt.mjs`, `src/strict-json.mjs`, die vier JSON-Schemas sowie `state-and-error-contract.md`.

Transport ist ausschließlich serverfreies NDJSON über stdin/stdout eines besitzenden Child-Prozesses:

```text
mangosd World/AI thread
  -> bounded value-only ingress (max. 3 outstanding: 1 running + 2 waiting)
  -> one joinable bridge-I/O worker
  -> node <verified>/src/cli.mjs --run
  -> external bridge
  -> bridge alone may call 127.0.0.1:11434
```

Start muss genau den Ready-Datensatz mit Modus `server_free_ndjson`, `active_limit=1`, `waiting_capacity=2`, `ledger_capacity=64`, `bot_guid=18281` und Modell `qwen2.5:7b` liefern. Der Core kennt und öffnet keinen Ollama-Endpoint.

Ein Request besitzt exakt diese Felder: `schema_version`, `request_id`, `bot_guid`, `created_utc`, `expires_utc`, `message`. V1 verwendet `schema_version=1`, kanonische lowercase UUIDv4, Bot-GUID `18281`, kanonisches UTC mit Millisekunden und `Z`, eine lokale TTL von 45 Sekunden und höchstens 2,048 UTF-8-Bytes Nachricht. Zusätzliche Felder sind verboten.

Der Core erzeugt bei Aufnahme eine eigene `steady_clock`-Deadline und bewahrt die beiden UTC-Werte nur als Wire-Evidenz. Die lokale Deadline wird weder nach Queue-Wartezeit noch nach Statuspolling neu berechnet. Die Bridge bildet bei Admission ihrerseits genau eine monotone Deadline aus den Wire-Werten.

Submit erfolgt genau einmal. Erlaubte Befehle sind ausschließlich `submit`, `status`, `consume`, `metrics` und `shutdown`. Polling erzeugt keinen neuen Versuch. Es gibt keine Wiederholung, kein Resubmit, keinen Modell-Fallback, keinen Redirect und keinen automatischen Child-Neustart.

Terminale Completion-Identität ist exakt `request_id + bot_guid`. Nur `outcome=ready`, Modell `qwen2.5:7b`, `attempt_count=1`, `error_code=null`, gültige `raw_response_bytes` in `0..65536` und kanonisch sanitizter, nichtleerer Text werden zugestellt. `failed` und `expired` liefern keinen Text. Nach dem ersten erfolgreichen `consume` wird lokal endgültig retired; eine zweite Zustellung ist ausgeschlossen.

## Thread-, Identitäts- und Zustellmodell

Request-Erzeugung bleibt im World-/AI-Thread: eingehendes Chat-Paket wird in `PlayerbotAI.cpp:1686-1935` geprüft und als kopierte Werte über `QueueChatResponse` (`8678-8682`) abgelegt; `UpdateAIInternal` leert diese Queue (`1222-1255`) und ruft `ChatReplyDo` (`SayAction.cpp:451-672`) auf. Nur dort wird bei einem echten Whisper an den gepinnten Bot ein Request erzeugt.

Der Worker erhält ausschließlich:

- Request-ID, Bot-GUID, Target-GUID;
- Bot-/Target-Account-ID, Session-Join-Zeit und eine world-seitig gepflegte Session-Generation;
- feste Route `WHISPER`, UTC-Evidenz, lokale monotone Deadline und eine Kopie der Nachricht.

Er erhält niemals `WorldSession*`, `Player*`, `PlayerbotAI*`, `Unit*`, `WorldPacket*` oder Callback-/Lambda-Captures auf solche Objekte.

Vor Zustellung löst der World-Thread Bot und Ziel neu aus den GUIDs auf und prüft: exakt ausstehendes Key-Paar; lokale Deadline; Completion-Schema und Modell; Bot weiterhin der registrierte Playerbot mit AI; beide Player in der Welt; beide Sessions vorhanden und nicht im Logout; `session->GetPlayer()` identisch; Account-ID, Join-Zeit und Session-Generation unverändert; Ziel weiterhin echter Spieler; Route weiterhin Whisper; Feature/Strategie weiterhin freigegeben. `WorldSession::GetState()` allein ist ausdrücklich ungeeignet, weil die Baseline dort immer READY zurückgibt (`WorldSession.h:335-342`).

Zustellung erfolgt als eine einzige direkte `Player::Whisper`-Operation im World-Thread. Completion-Text wird nicht an `HandleCommand`, `ParseChatCommand`, `DoSpecificAction`, `TellPlayerNoFacing`, `LinesToPackets`, Emote-Parser, Paketvorlagen oder Server-/Admin-Handler weitergereicht. Sternchen, Klammern, Links oder befehlsähnliche Präfixe bleiben gewöhnlicher Text.

## Begrenzungen und Fail-closed-Verhalten

- Der geprüfte Bridge-Prozess ist auf 64 Ledger-Einträge begrenzt und evicted auch `consumed` nicht. Nach 64 gespeicherten Keys antwortet er `ledger_full`. V1 deaktiviert die Integration dann fail-closed; es erfolgt kein automatischer Neustart und kein Retry. Für einen dauerhaften Produktivbetrieb ist später entweder ein separat geprüfter Ledger-Rollover-Vertrag oder ein ausdrücklich autorisierter, nur im Leerlauf erfolgender Prozesswechsel nötig.
- Der geprüfte Personality-Kontext ist ausschließlich für Bot-GUID `18281`. Andere Bots werden in V1 nicht submitted.
- Der Core akzeptiert maximal drei ausstehende Dialoge, passend zu einer aktiven Bridge-Inferenz plus zwei Wartenden. Die lokale Completion-Queue ist ebenfalls auf drei Einträge begrenzt. Ein Overflow führt zu Fehler/Discard, niemals zu ungebundener Speicherung oder Doppelzustellung.
- Absolute Node-/Bridge-Pfade und die Integrität des extrahierten Payloads müssen vor Aktivierung separat freigegeben werden. Vorgesehen ist die Prüfung des vollständigen Payload-Manifests mit festem SHA-256 `7494F26C...`; die Phase-1B-Node-Binärdatei wurde nur als Referenz erhoben (`24.19.0`, SHA-256 `3602F2BB...`) und hier nicht als neue Produktionsinstallation freigegeben.

Diese Grenzen sind sicherheitsseitig fail-closed und blockieren den datei-/zeilengenauen Minimalpatchplan nicht; sie sind aber vor einer dauerhaften Live-Freigabe ausdrücklich zu entscheiden.

## Separater PlayerBot-Befehlsnebenstrang

`evidence/playerbot-command-inventory.md` dokumentiert read-only die Gateways und Größenordnung. 52 statische `.bot/.rndbot`-Zeilen (51 eindeutige Schlüssel) sowie 3,607 Creator-Registrierungen (2,548 eindeutige Schlüssel) belegen, dass ein implizites „Text als Aktion“-Mapping nicht prüfbar klein wäre. Für V1 ist die Action-Allowlist deshalb leer. Ein späterer Action-Vertrag braucht ein separates, strukturiertes Schema und eine eigene Freigabe; er ist nicht Teil des Minimalpatchs.

## Unverändertheitsbestätigung

Keine Source- oder Configdatei wurde verändert. Es wurde nicht gebaut oder kompiliert. Es gab keinen Datenbankzugriff, keine Migration, keine Prozesssteuerung, keinen Serverstart, keine Bridge-/Ollama-Inferenz und keinen Game-Chat. Geschrieben wurden nur dieses neue Phase-A-Runbook, Evidenzdateien, Manifest und Deliverable-ZIP.

Der datei- und zeilengenaue Plan steht in `MINIMAL-PATCH-PLAN.md`. Danach wurde gestoppt.
