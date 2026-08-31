# Datei- und zeilengenauer Minimalpatchplan

Referenz für alle Zeilen: Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`. Dieser Plan beschreibt eine spätere Phase; in Phase A wurde nichts davon umgesetzt.

## Geplanter minimaler Dateisatz

| Datei / Baselineanker | Geplante Änderung | Sicherheitsvertrag |
|---|---|---|
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h` | Werttypen für immutable Request/Route/Completion; Lebenszyklus `Start`, `TrySubmit`, `UpdateWorld`, `ObserveSession`, `InvalidateSession`, `Shutdown`; feste V1-Grenzen. | Kein Game-Rohzeiger in Queue, Worker oder Completion; `request_id + bot_guid` ist Primärschlüssel. |
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp` | Strikter NDJSON-Client; genau ein joinbarer Worker; besitzender Windows-Child-Prozess mit stdin/stdout-Pipes; Manifest-/Ready-/Envelope-Prüfung; Queue-/Deadline-/Consume-/Shutdown-Zustandsmaschine. | Kein Shell-Aufruf, kein direkter Socket/Ollama-Code, kein detached Thread, kein Retry/Resubmit/Auto-Restart. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h:439-445` | Separaten, standardmäßig deaktivierten External-Bridge-Block ergänzen; Legacy-LLM-Felder nicht wiederverwenden. | Endpoint/Modell/Digest sind keine Core-Optionen. Core erhält nur absolut zu validierende Node-, Bridge-Root- und CLI-Pfade. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp:705-718, 772-790` | Neue Keys `AiPlayerbot.ExternalLLMBridge.Enabled` (Default `false`), `.NodeExecutable`, `.BridgeRoot`, `.CliScript`; Werte nur beim Start übernehmen. Legacy-Endpoint nicht an den neuen Service übergeben. | Aktivierung ohne vollständige absolute Pfade oder ohne Payload-Manifest-Match schlägt geschlossen fehl. Runtime-Reload startet/stoppt keinen Prozess. |
| `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in:1209-1278` | Separaten Abschnitt nach dem Legacy-No-op-Block dokumentieren; Default aus; keine Ollama-URL und kein Modell im Core-Configvertrag. | Config-V1 verweist nur auf die geprüfte externe Bridge. Aktive Config wird erst in einer eigenen, späteren Freigabe geändert. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:40-46` | Nach abgeschlossenem Playerbot-Startup `ExternalLLMBridgeService::Start()` aufrufen, nur wenn External-Flag gesetzt ist. | Ready-Datensatz und Payloadintegrität müssen vollständig passen; sonst Service `failed/disabled`, World startet ohne LLM. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:48-55` | `UpdateWorld()` auf demselben World-Hook ausführen, der am Ende von `World::Update` läuft. | Completions werden nur im World-Thread aufgelöst und zugestellt. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:56` (Einfügung vor Klassenende) | `OnShutdown()` ergänzen: Admission schließen, `shutdown drain=true` senden, endliche Frist, Child und Worker vollständig joinen. | Kein Worker und kein Pipe-Handle überlebt `World::Shutdown`; kein Zugriff auf Gameobjekte beim Join. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:209-219, 222-226, 231-234` | Bei Login Session-Fingerprint/Generation registrieren; bei BeforeLogout und ReleaseToClient Generation invalidieren und betroffene ausstehende Routes verwerfen. | Relog/Sessionwechsel kann keine alte Completion erhalten. Nur GUID/Account/Joinzeit/Generation werden gespeichert. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1796` | `isAiChat` nicht für die neue Bridge wiederverwenden; eine getrennte, whisper-only External-Eignung ergänzen, damit ein gültiger Request ohne Random-Chat-Verzögerung zu `QueueChatResponse` gelangt. | Exakt Bot 18281, `CHAT_MSG_WHISPER`, echter fremder Spieler, gültiges UTF-8 und External-Flag. Andere Kanäle/Bots bleiben im bestehenden Pfad. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1222-1255, 1860-1935, 8678-8682` | Keine strukturelle Änderung; diese bestehenden World-/AI-Thread-Grenzen für kopierte Chatwerte verwenden. | Request-Erzeugung erfolgt nicht im Packet-/Netzwerkthread und nicht im Worker. |
| `src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp:512-669` | Den gesamten Legacy-Async-LLM-Zweig durch einen kleinen External-Bridge-Admission-Zweig ersetzen. Kein Promptbau, keine Paketvorlage, kein `std::async`, kein `PlayerbotLLMInterface::Generate`. | Admission nur für Whisper von neu aufgelöstem echtem Ziel an gepinnten Bot. Route erfasst UUIDv4, GUIDs, Sessionfingerprints, UTC-Evidenz und 45-s-`steady_clock`-Deadline. Queue-full/invalid/disabled => stilles Fail-closed, kein Fallback-LLM und kein Retry. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.h:553-554` | Die nach Entfernung des einzigen Aufrufers unbenutzten LLM-Delayed-Packet-Deklarationen entfernen. | Verhindert spätere Wiederverwendung des pointerhaltigen detached-Pfads. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:7978-8006` | Die zugehörigen zwei detached-Thread-Helfer entfernen, sobald `SayAction.cpp:655` entfernt ist. | Kein `WorldSession*` oder `PacketHandlingHelper*` kann in diesem LLM-Pfad einen World-Lebenszyklus überleben. |
| `src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp:376-382` | **Unverändert lassen.** Der Legacy-Einstieg bleibt Release-No-op und wird vom neuen Pfad nicht aufgerufen. | Keine Übernahme des Debug-HTTP-Clients. |
| `src/modules/PlayerBots/playerbot/strategy/actions/RpgSubActions.cpp:409-563` und `strategy/triggers/RpgTriggers.cpp:627-639` | **Unverändert und nicht anbinden.** External V1 stellt weder RPG-/NPC-Text noch Emotes bereit. | Modelltext kann keine Aktion, kein Emote und keinen öffentlichen Chat erzeugen. |
| `src/modules/PlayerBots/CMakeLists.txt:25` | **Keine Änderung.** Das vorhandene GLOB nimmt die zwei neuen `playerbot/*.cpp/.h`-Dateien auf. | Die historische Debug-Include-Änderung wird nicht benötigt. |

## Exakte interne V1-Grenzen

- `active_limit=1`, `waiting_capacity=2`, maximal drei lokal ausstehende Routes.
- lokale Ingress-Queue: zwei Wartende; lokale Completion-Queue: drei; keine dynamisch unbeschränkten Dialogcontainer.
- Bridge-Ledger bleibt unverändert 64; `ledger_full` deaktiviert den Adapter fail-closed.
- Request: maximal 16,384 JSON-Bytes, Nachricht maximal 2,048 UTF-8-Bytes, TTL 45,000 ms, absolute Obergrenze 60,000 ms, Clock-Skew maximal 5,000 ms.
- Completion: maximal 65,536 rohe Response-Bytes in der Bridge; Text maximal 240 Unicode-Codepoints und zwei maximale Terminatorläufe aus `. ! ? …`.
- Child-Start: ausschließlich `CreateProcessW` mit direkt übergebenem Executable/Argumentarray; kein `cmd.exe`, keine Shell-Expansion, kein geerbtes fremdes stdin/stdout.
- Ready muss exakt `server_free_ndjson / 1 / 2 / 64 / 18281 / qwen2.5:7b` melden.
- Payload: Manifestdatei SHA-256 `7494F26C2CBA47084691D57ED7DEA372B5E895C90F58FF86304101B48305FA8E`; jede enthaltene relative Datei wird gegen das Manifest geprüft, Pfadescape/Symlink/Reparse-Ziel abgelehnt.
- Request-ID: 16 kryptografisch zufällige Bytes, RFC-4122-Version-/Variantbits gesetzt, lowercase kanonisch formatiert; bei Kollision keine neue ID und kein Retry.
- JSON-Decoder: striktes UTF-8 ohne BOM, keine unpaarigen Surrogates, keine Duplicate Keys, exakte Feldmengen, begrenzte Tiefe/Zeilengröße.
- Worker-Polling: round-robin `status` für bereits submitted Keys; niemals erneutes `submit`.
- Consume: terminal genau einmal; erst konsumieren, wenn lokale Completion-Queue Platz hat; danach lokaler Key sofort `consumed/retired`.

## Zustellprüfung im World-Thread

In dieser Reihenfolge, bei jedem Fehler discard/retire ohne Text:

1. Exact outstanding key `request_id + bot_guid` und noch nicht retired.
2. Lokale `steady_clock`-Deadline nicht erreicht.
3. Completion hat exakte V1-Feldmenge, identische IDs, terminal `ready`, Modellpin, Versuch 1, null Error und begrenzte Raw-Bytes.
4. Text ist strict UTF-8, nicht leer, ohne verbotene Controls, höchstens 240 Codepoints und höchstens zwei Terminatorläufe; erneute Sanitizer-Anwendung ergibt bytegenau denselben Text.
5. Bot per GUID neu auflösen; registrierter Playerbot, AI vorhanden, in world, Session vorhanden, nicht im Logout, Account/Joinzeit/Sessiongeneration identisch.
6. Ziel per GUID neu auflösen; echter Spieler, nicht Bot, in world, Session vorhanden, `session->GetPlayer()==target`, nicht im Logout, Account/Joinzeit/Sessiongeneration und Name identisch.
7. External-Flag und `ai chat`-Freigabe weiterhin aktiv; feste Route weiterhin Whisper.
8. Key vor Ausgabe atomar retiren; genau ein `bot->Whisper(text, language, targetGuid)` im World-Thread.

Explizit verboten: Completion-Text an `PlayerbotAI::HandleCommand`, `HandleCommands`, `ExternalEventHelper::ParseChatCommand`, `DoSpecificAction`, `TellPlayerNoFacing`, `LinesToPackets`, `TextEmote`, `HandleEmoteCommand`, `.bot/.rndbot` oder einen Admin-/Server-Command-Handler übergeben.

## Spätere Verifikation (nicht in Phase A ausgeführt)

1. Unit-Tests für UUID, strict JSON, Queue 1+2, duplicate/mismatch/stale/expiry/consume-once, monotone Deadline bei Wallclock-Sprüngen, Sanitizer-Terminators und Sessiongeneration.
2. Fake-Child-Prozess-Tests für Ready-Mismatch, partielle/zu große NDJSON-Zeilen, Child-Abbruch, endliche Shutdown-Frist, Worker-Join und Handle-Freigabe.
3. World-thread-Harness: Logout/Relog von Bot und Ziel zwischen Admission und Completion; kein Text bei jedem Mismatch; exakt ein Whisper beim gültigen Fall.
4. Static/grep gate: im neuen Service kein `Ollama`, `11434`, `httplib`, `.detach`, `HandleCommand`, `DoSpecificAction`, `Emote`; im Produktionsdiff keine der vier historischen Debug-Hunks.
5. Erst danach separater Clean Build aus isoliertem Commitzustand. Kein Deployment oder Live-Test ohne neue Freigabe.
