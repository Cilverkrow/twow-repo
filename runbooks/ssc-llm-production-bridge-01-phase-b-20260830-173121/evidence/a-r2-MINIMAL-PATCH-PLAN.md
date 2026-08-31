# Vollständiger datei- und zeilengenauer Minimalpatchplan – A-R2

Alle Core-Anker beziehen sich auf Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`. Alle Bridge-Anker beziehen sich auf das unveränderte English-Correction-ZIP `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434`. Dieser Plan wurde in A-R2 nicht implementiert.

## 1. Minimaler Core-Dateisatz

| Datei / Baselineanker | Spätere isolierte Änderung | Verbindliche Grenze |
|---|---|---|
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h` | Werttypen für immutable Request, Route, Sessionfingerprint, Status und Completion; Adapterzustände `disabled`, `starting`, `ready`, `ledger_exhausted`, `protocol_failed`, `child_failed`, `shutting_down`, `stopped`; API `Start`, `TrySubmit`, `UpdateWorld`, `ObserveSession`, `InvalidateSession`, `Shutdown`. | Keine Rohzeiger über Threadgrenzen. `ledger_exhausted`, `protocol_failed` und `child_failed` schließen Admission dauerhaft für die Instanz. |
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp` | Manifestprüfung eines extrahierten PackageRoot; serialisierter strict-NDJSON-Client; genau ein joinbarer I/O-Worker mit overlapped stdin/stdout/stderr; eigener Child-Prozess; bounded Ingress/Completion/Diagnostic Buffer; Lifecycle und Latches. | Kein ZIP-Parser, kein Shellaufruf, kein direkter Ollama-/HTTP-Code, kein `.detach`, Retry, Resubmit, Auto-Restart oder Prozesswechsel. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h:439-445` | Separaten, standardmäßig deaktivierten External-Bridge-Block ergänzen. Nur `Enabled`, `NodeExecutable` und `PackageRoot`. | Keine `.CliScript`, Ollama-URL, Modell-, Digest-, Sprach- oder Actionoption. Node/PackageRoot bleiben bis Deployment-Gate Referenz. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp:705-718,772-790` | Neue Werte nur beim Prozessstart lesen; absolute kanonische Pfade verlangen. Runtime-Reload darf sie nicht aktivieren oder Child-Lifecycle auslösen. | Default `Enabled=false`; ungültiger Pfad/Pin => Adapter bleibt fail-closed. Keine aktive Configänderung in Phase B. |
| `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in:1209-1278` | Deaktivierten Referenzblock dokumentieren: `.Enabled`, `.NodeExecutable`, `.PackageRoot`. | CLI wird intern als `PackageRoot/bridge/src/cli.mjs` abgeleitet. Kein Deployment-/Runtimeversprechen. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:40-46` | Service nach Playerbot-Startup nur bei gültiger späterer Aktivierung starten. | Payload vor jedem Start vollständig prüfen; Ready binnen 35.000 ms. Jeder Fehler lässt World/Playerbots ohne External LLM weiterlaufen. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:48-55` | `UpdateWorld()` im bestehenden World-Hook aufrufen. | Nur World-Thread darf Gameobjekte neu auflösen und Whisper zustellen. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:56` | `OnShutdown()` ergänzen: Admission schließen, exakt ein `shutdown drain=true`, Core-Gesamtfrist 40.000 ms, Worker/Child/Handles vollständig abschließen. | Nach Timeout nur eigenes, über `CreateProcessW` besessenes Process-Handle terminieren. Keine Suche oder fremde Prozesssteuerung. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:209-219,222-226,231-234` | Sessiongeneration/Fingerprint bei Login beobachten; bei BeforeLogout/ReleaseToClient invalidieren. | Relog/Sessionwechsel verwirft alte Routes; nur Wertdaten gespeichert. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1686-1935`, Eignungsanker `:1796` | Getrennte External-Whisper-Eignung ergänzen; bestehendes `isAiChat` und normale Nicht-LLM-Chatlogik nicht global verändern. | Nur Bot 18281/Whisper/echter Zielspieler. Lokales `ledger_exhausted`-Reject darf den normalen Nicht-LLM-Pfad nicht unterdrücken; kein anderes LLM als Fallback. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1222-1255,8678-8682` | Vorhandene World-/AI-Thread-Grenze für kopierte Chatwerte beibehalten. | Request-Erzeugung nie im Netzwerk-/Packetthread oder Child-Worker. |
| `src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp:451-672`, Ersetzungsbereich `:512-669` | Legacy-Async-LLM-Zweig durch kleinen `TrySubmit`-Zweig ersetzen; dessen Ergebnis unterscheidet admitted, ordinary local reject und `locally_rejected_ledger_exhausted`. | Kein Promptbau, `std::async`, Packettemplate, `PlayerbotLLMInterface::Generate`, Retry oder LLM-Fallback. Normaler Nicht-LLM-Chat bleibt erreichbar. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.h:553-554` | Alte LLM-Delayed-Packet-Deklarationen nach Entfernung ihres einzigen Callers löschen. | Kein pointerhaltiger Altpfad. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:7978-8006` | Zugehörige detached Helfer nach Entfernung des Callers löschen. | Kein `WorldSession*` oder `PacketHandlingHelper*` überlebt den World-Lebenszyklus. |
| `src/game/Objects/Player.cpp:19377-19386` | **Unverändert.** Einzelner Ausgabeprimitive `Player::Whisper`. | Erst nach vollständiger World-Thread-Revalidierung, exakt einmal. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:3588-3616`, besonders `:3607-3614` | Bestehende teamabhängige Protokollsprache wiederverwenden. | Englischer Modelltext ist nicht automatisch `LANG_COMMON`; Horde bleibt `LANG_ORCISH`. |
| `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp:602-606` | GUID-basierte Botauflösung unmittelbar vor Zustellung. | Kein gespeicherter `Player*`. |
| `src/game/WorldSession.h:335-342,355-360` | Account/Joinzeit mit eigener Sessiongeneration kombinieren; `GetState()==READY` nicht allein verwenden. | Bot und Ziel müssen exakt zur Admission-Session passen. |
| `src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp:376-382` | **Unverändert.** Release-No-op wird nie aufgerufen. | Keine frühere Debug-HTTP-/Endpoint-Änderung übernehmen. |
| `src/modules/PlayerBots/playerbot/strategy/actions/RpgSubActions.cpp:409-563` und `strategy/triggers/RpgTriggers.cpp:627-639` | **Unverändert, nicht anbinden.** | Action-Allowlist leer; keine Emotes, Commands oder öffentlichen Kanäle. |
| `src/modules/PlayerBots/CMakeLists.txt:25` | **Keine Änderung.** Vorhandener GLOB erfasst die neuen Service-Dateien. | Keine historische Debug-Include-Änderung. |

## 2. Paketzuständigkeit vor einem späteren Start

### Deployment-Werkzeug – nicht Core und nicht Phase B

1. Äußeren ZIP-Hash `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434` prüfen.
2. Vor Extraktion alle ZIP-Namen kanonisieren; absolute Namen, `..`, ADS, Gerätepfade, doppelte kanonische Namen, Symlink-/Junction-/Reparse-Escape ablehnen.
3. Root-Manifest gegen `522D3358D28D7A8CC69DEF1D385A38399557F6E2C9BED777565C6CB4A403353C` und alle 77 referenzierten ZIP-Einträge prüfen.
4. Ausschließlich in ein neues, zuvor nicht vorhandenes absolutes PackageRoot extrahieren; keine In-place-Aktualisierung.
5. Erst ein späteres separates Deployment-Gate darf dieses PackageRoot und eine Node-Runtime als aktive Config referenzieren.

### Core vor jedem Child-Start

1. PackageRoot muss absolut, kanonisch und bereits extrahiert sein. Core öffnet kein ZIP und liest kein Root-Manifest.
2. `PackageRoot/bridge/sha256-manifest.txt` muss Hash `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B` besitzen.
3. Jede Manifestzeile exakt parsen: uppercase SHA-256, ein relativer kanonischer Payloadpfad, keine Duplikate; alle genannten Dateien unter `PackageRoot/bridge` hashen; fehlende, entweichende oder Reparse-Ziele ablehnen.
4. Config `PackageRoot/bridge/config/bridge-config-v1.json` zusätzlich gegen `D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902` prüfen.
5. Personality `PackageRoot/bridge/context/personality-context-profile-v1.json` zusätzlich gegen `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E` prüfen.
6. CLI-Pfad ausschließlich als `PackageRoot/bridge/src/cli.mjs` bilden und zusätzlich gegen `C5D2C01DB3AEBBBF65A2ECFACC1515326334220A5F79395DF3E24550345CA611` prüfen.
7. Keine Datei aus `bridge/phase1a-report.md` als aktive Vertrags- oder Pinquelle lesen; sie bleibt historische Evidenz.
8. Erst nach vollständigem Erfolg Child-Erzeugung zulassen. Jeder Fehler => dauerhafte geschlossene Admission, noch kein Prozessstart.

## 3. Child- und Pipe-Ownership

- Prozessstart ausschließlich über `CreateProcessW` mit direkt angegebenem Node-Executable und Argumenten `PackageRoot/bridge/src/cli.mjs --run`; kein `cmd.exe`, PowerShell, Shellquoting oder PATH-Suchen.
- Erzeuge getrennte stdin-, stdout- und stderr-Pipes. Nur die drei benötigten Child-Enden stehen in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`; `bInheritHandles=TRUE` nur zusammen mit dieser expliziten Liste. Parent-Enden und alle fremden Handles sind nicht vererbbar.
- Speichere ausschließlich `PROCESS_INFORMATION.hProcess`, `hThread`, Child-PID und Creation-Evidenz der selbst erzeugten Instanz. Threadhandle nach erfolgreichem Start schließen; Processhandle bis endgültigem Join behalten.
- Genau ein joinbarer I/O-Worker besitzt Pipezustand, Pending-Command, Queues und Childhandle. Overlapped I/O drainiert stdout und stderr ohne zweiten detached Reader.
- stdout: strict UTF-8 ohne BOM, genau ein JSON-Objekt je LF-Zeile, lokale Zeilenobergrenze 16.384 Bytes. CRLF darf nur als Zeilenabschluss normalisiert werden. Leere Zeile, NUL, invalides UTF-8, Duplicate Key, mehrere JSON-Werte oder Übergröße => `protocol_failed`.
- stderr: separat fortlaufend drainieren; 65.536-Byte-Ringpuffer behält jüngste Bytes, verwirft ältere, drainiert aber bis EOF weiter. Nie JSON parsen, nie an Game-Chat oder Modell weitergeben; bei Logausgabe Controls escapen und drosseln.
- Es ist stets höchstens ein CLI-Kommando ohne Antwort offen. Response wird anhand des einzigen Pending-Command-Typs geprüft. Unsolicited, doppelte oder verspätete Records sind fatal.

## 4. Zeitgrenzen

| Konstante | Wert | Beginn / Wirkung |
|---|---:|---|
| `CORE_READY_TIMEOUT_MS` | 35.000 | Ab erfolgreichem `CreateProcessW` bis vollständig validiertem Ready-Record. |
| `CORE_STATUS_POLL_INTERVAL_MS` | 100 | Globales Mindestintervall zwischen Status-Kommandos; Round-robin über vorhandene Keys. Kein Busy-Loop. |
| `CORE_SHUTDOWN_OVERALL_TIMEOUT_MS` | 40.000 | Ab Schreiben des einmaligen `shutdown drain=true` bis Shutdown-Response, Workerjoin, Childende und Handleabschluss. |
| `CORE_STDERR_DIAGNOSTIC_CAP_BYTES` | 65.536 | Maximal gespeicherte Diagnosebytes; Drain selbst bleibt unbegrenzt fortlaufend. |

Request-Lebensdauer bleibt separat: Wire `created_utc/expires_utc`, lokale 45.000-ms-`steady_clock`-Deadline und Bridge-monotone Deadline bei Admission. Polling, Latch oder Shutdown verlängern keine Deadline.

## 5. Ready und permanentes Admission-Close

- Innerhalb der Ready-Frist ist ausschließlich entweder der exakte Ready-Record oder das exakt validierte fatale Top-Level-Envelope zulässig.
- Ready muss byteunabhängig nach JSON-Semantik exakt sieben Felder und Werte liefern: `code=ready`, `mode=server_free_ndjson`, `active_limit=1`, `waiting_capacity=2`, `ledger_capacity=64`, `bot_guid=18281`, `model=qwen2.5:7b`.
- EOF, Child exit, Ready-Timeout, falsche/zusätzliche/fehlende Felder, falsche Werte oder jeder andere Record => Admission dauerhaft schließen, Worker/Handles kontrolliert abschließen, kein Neustart.
- Nach Ready gilt dieselbe permanente Reaktion für ungültiges NDJSON, unbekannte/contextfremde Codes, Envelope-Mismatch, EOF oder Child-Abbruch. Bereits lokale Routes werden ohne Ausgabe retired, sofern sie nicht mehr sicher poll-/consume-fähig sind.

## 6. Ledger-full-Latch – exakter Algorithmus

1. Nur bei Pending-Command `submit` die exakte Antwortfeldmenge `{accepted,code,status}` prüfen.
2. Nur Kombination `accepted=false`, `code="ledger_full"`, `status=null` ist der Latch-Trigger.
3. Auslösenden lokalen Request als `retired_ledger_full` markieren; er existiert laut Bridge nicht im Ledger und darf nie gepollt, consumed oder erneut submitted werden.
4. Adapterzustand per einmaligem atomarem Übergang `ready -> ledger_exhausted` setzen. Ein bereits strengerer Fehlerzustand wird nicht zurückgestuft.
5. In `ledger_exhausted` blockiert `TrySubmit` vor Request-ID-/Route-Erzeugung mit `locally_rejected_ledger_exhausted` und schreibt keine Childbytes.
6. Bestehende, vor dem Latch mit `queued` akzeptierte Keys bleiben in bounded Outstanding-Map; nur `status`, später `consume`, Deadline-Discard oder Shutdown sind erlaubt.
7. Ein einziges strukturiertes Warning pro Child-Instanz; wiederholte lokale Rejects nicht pro Dialog loggen.
8. Latch bleibt bis manuell autorisiertem vollständigem Shutdown und neuer Instanz bestehen. Kein automatischer Reset durch leeres Outstanding-Set, Zeitablauf oder Child-Antwort.
9. External-Latch niemals auf globale Playerbot-/Chatflags spiegeln. Bestehende Nicht-LLM-Verarbeitung läuft unverändert; kein anderes LLM wird aktiviert.

## 7. Wire-Prüfung und Zustellung

Der vollständige Feld-/Codekatalog in `bridge-contract-v1.json` ist implementierungsbindend. Ergänzende Core-Regeln:

- unbekannte Felder fehlen nie still; fehlende Pflichtfelder erhalten keinen Default; explizites `null` ist nur an den im Vertrag benannten Positionen erlaubt;
- ein bekannter Code im falschen Kommando-/Envelope-Kontext ist ebenso fatal wie ein unbekannter Code;
- `status` pollt ausschließlich bereits akzeptierte Keys; `consume` wird nur nach terminalem Status und freier lokaler Completion-Kapazität gesendet;
- `already_consumed` enthält zwingend `completion:null`; `consumed` zwingend eine terminale Completion;
- Ready-Completion muss Modellpin, Attempt 1, nicht-null Start-/Completionzeit, nichtleeren canonical sanitized Text und Raw-Bytes besitzen;
- Failed/Expired-Completion muss `text:null` und nichtleeren bekannten `error_code` besitzen; alle anderen Null-/Modell-/Attempt-Kombinationen werden anhand des Katalogprofils geprüft;
- Text erneut strict prüfen: höchstens 240 Codepoints, 240 UTF-8-Bytes und zwei maximale Terminatorläufe; niemals kürzen;
- danach Bot, Ziel und beide Sessiongenerationen im World-Thread neu auflösen; Protokollsprache aus Bot-Team, nicht aus `English`;
- Key vor genau einem `bot->Whisper(text, protocolLanguage, targetGuid)` retiren.

Modelltext darf nie `HandleCommand`, `HandleCommands`, `ExternalEventHelper::ParseChatCommand`, `DoSpecificAction`, `TellPlayerNoFacing`, `LinesToPackets`, `TextEmote`, `HandleEmoteCommand`, `.bot/.rndbot` oder Admin-/Serverhandler erreichen.

## 8. Shutdown und eigener Child-Fallback

1. Lokale Admission schließen; kein neuer Submit.
2. Falls Child/Protocol noch kontrollierbar, genau einmal `{"command":"shutdown","drain":true}` schreiben und stdin flushen; keine Signale senden.
3. Bis zur 40.000-ms-Gesamtfrist stdout/stderr drainieren, einziges Shutdown-Envelope prüfen, Childende beobachten und I/O-Worker joinen.
4. Bei Fristablauf keine PID-/Namenssuche. Nur das unverändert besessene `hProcess` aus dieser `CreateProcessW`-Operation verwenden; optional vor Terminate prüfen, dass Handle noch aktiv und gespeicherte PID konsistent ist.
5. Ausschließlich dieses Handle mit `TerminateProcess` beenden, danach auf genau dieses Handle warten, Worker joinen und alle eigenen Pipe-/Processhandles schließen.
6. Niemals andere Node-, Ollama-, mangosd-, realmd-, MariaDB- oder sonstige Prozesse öffnen oder beenden. Kein `taskkill`, keine Job-weite Fremdbeendigung, kein `GenerateConsoleCtrlEvent`.
7. Kein automatischer Neustart nach normalem, fehlerhaftem oder erzwungenem Child-Ende.

## 9. Spätere Phase-B-Tests – nicht ausgeführt

Phase B benötigt separate Freigabe und bleibt offline/isoliert:

1. Fake-Child: exaktes Ready; jedes einzelne Missing/Unknown/Null/Type/Value-Mismatch; Ready-Timeout; EOF vor/nach Ready; invalides UTF-8/NDJSON; unsolicited/doppelte Antwort.
2. Kommandomatrix: jede gültige Responsevariante für submit/status/consume/metrics/shutdown; jeder Code im falschen Kontext; unbekannter Code; fehlendes/zusätzliches Feld.
3. Ledger-Latch: erster exakter Trigger; kein weiterer Submit; bestehende Keys poll/consume; neue Requests lokal rejected; genau ein Log; Non-LLM-Chat-Harness unbeeinträchtigt; kein Reset ohne neue Instanz.
4. Pipe/Process: nur allowlistete Handles vererbt; stderr >65.536 Bytes ohne Deadlock und bounded Ring; stdout bleibt separat; Child-Abbruch; Ready 35 s; Poll 100 ms; Shutdown 40 s.
5. Timeout-Fallback: nur Fake-Child-Prozesshandle terminiert; Sentinel-Fremdprozesse bleiben am Leben; Worker und alle Handles geschlossen.
6. Queue/Envelope: 1 aktiv, 2 wartend, Ledger 64, Completion 3, monotone Deadline, Consume-once, 240 Codepoints/Bytes ohne Kürzung.
7. World-Harness: Logout/Relog/Mismatch verwirft; gültig exakt ein Whisper; Horde-Protokollsprache nicht wegen englischem Text `LANG_COMMON`.
8. Static Gate: kein ZIP-Parser, `.CliScript`, Ollama/11434/HTTP, `.detach`, Retry/Restart, Process-Enumeration oder Action-/Emote-/Command-Dispatch.
9. Danach isolierter Clean Build. Kein echtes PackageRoot, Node, Bridge, Ollama, Deployment, aktive Config oder Game-Chat in Phase B.
