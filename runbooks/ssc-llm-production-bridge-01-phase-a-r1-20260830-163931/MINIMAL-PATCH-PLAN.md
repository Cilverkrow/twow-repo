# Aktualisierter datei- und zeilengenauer Minimalpatchplan

Referenz für alle Core-Zeilen: Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, Tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`. Referenz für die externe Bridge: unverändertes English-Correction-Paket mit ZIP-SHA-256 `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434`. Dieser Plan beschreibt ausschließlich eine mögliche spätere Phase B; in A-R1 wurde nichts umgesetzt.

## Aktive Bridge-Anker

| Artefakt / Zeile | Verbindliche Bedeutung für einen späteren Patch |
|---|---|
| `bridge/config/bridge-config-v1.json:4-5` | `waiting_capacity=2`, `ledger_capacity=64`; Core-Grenzen dürfen diese Werte nicht erweitern. |
| `bridge/config/bridge-config-v1.json:12-14` | maximal 240 Codepoints, 240 UTF-8-Bytes und zwei Terminatorläufe. |
| `bridge/config/bridge-config-v1.json:24-32` | einziges erlaubtes Modell `qwen2.5:7b` mit gepinntem Digest; Modell/Endpoint bleiben alleinige Verantwortung der externen Bridge. |
| `bridge/config/bridge-config-v1.json:34-36` | Personality-Datei V1, Personality-Pin und englische Systemregel. |
| `bridge/context/personality-context-profile-v1.json:3-5,20` | Profilversion 1, Bot-GUID 18281 und englische Dialogregel. |
| `bridge/src/cli.mjs:27-28,39-45` | einziger Startweg `src/cli.mjs --run`; Instance-Lock gehört dem Child und wird im `finally` freigegeben. |
| `bridge/src/cli.mjs:76-84` | exakter Ready-Vertrag `server_free_ndjson / 1 / 2 / 64 / 18281 / qwen2.5:7b`. |
| `bridge/src/cli.mjs:118-143` | exakte NDJSON-Kommandos `submit`, `status`, `consume`, `shutdown`, `metrics`; exakte Feldmengen. |
| `bridge/src/bridge.mjs:83-169` | Admission, UUID+GUID-Identität, Duplicate/Mismatch, monotone Deadline, Ledger-/Queue-Fail-closed. |
| `bridge/src/bridge.mjs:172-206` | Status ist read-only; Consume ist genau einmal und liefert beim zweiten Aufruf keinen Text. |
| `bridge/src/bridge.mjs:223-236` | bounded Metrics und Worker-Ownership. |
| `bridge/src/bridge.mjs:368-446` | Stale-/Expiry-Entscheidungen benutzen die monotone Deadline, einschließlich `ready` vor Consume. |
| `bridge/src/prompt.mjs:24-43` | Sanitizer verwirft unzulässige Ausgabe; Codepoint-, Byte- und Satzgrenze schneiden niemals Text ab. |
| `bridge/state-and-error-contract.md:49,55-65` | `ledger_full`, Completion-Mismatch, UTF-8-Grenze, Englischregel, keine Action-/Emote-Wirkung und maximal ein Attempt. |
| `bridge/phase1a-report.md:1,25,30,32` | nur historische Evidenz; niemals aktive Pins oder aktive Context-Version daraus lesen. |

## Geplanter minimaler Core-Dateisatz

| Datei / Baselineanker | Spätere Änderung | A-R1-Sicherheitsvertrag |
|---|---|---|
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h` | Immutable Werttypen `RequestRoute`, `PendingRequest`, `Completion`; API `Start`, `TrySubmit`, `UpdateWorld`, `ObserveSession`, `InvalidateSession`, `Shutdown`; feste V1-Grenzen. | Kein Game-Rohzeiger in Ingress, Worker oder Completion; Primärschlüssel `request_id + bot_guid`; Action-Allowlist ist leer. |
| **NEU** `src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp` | Strikter NDJSON-Child-Client; genau ein joinbarer Worker; besitzender Windows-Child-Prozess mit stdin/stdout-Pipes; Paket-/Manifest-/Ready-/Envelope-Prüfung; begrenzte Queues und Zustandsmaschine. | Kein Shell-Aufruf, kein direkter Socket-/Ollama-Code, kein `.detach`, kein Retry/Resubmit/Auto-Restart. Überlange Completion wird vollständig retired, ohne Whisper. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h:439-445` | Separaten, standardmäßig deaktivierten External-Bridge-Block ergänzen; Legacy-LLM-Felder nicht wiederverwenden. | Core-Config enthält keine Ollama-URL, kein Modell und keinen Digest. Nur absolute Node-, Paketroot- und CLI-Pfade. |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp:705-718,772-790` | Keys `AiPlayerbot.ExternalLLMBridge.Enabled=false`, `.NodeExecutable`, `.PackageRoot`, `.CliScript` nur beim Startup lesen. | Unvollständige/relative Pfade oder Pin-Mismatch deaktivieren fail-closed. Runtime-Reload startet oder stoppt kein Child. |
| `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in:1209-1278` | Separaten External-Bridge-Abschnitt nach dem Legacy-No-op-Block dokumentieren; Default aus. | Keine aktive Configänderung in A-R1; keine Ollama- oder Sprachprotokolloption. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:40-46` | Nach Playerbot-Startup `ExternalLLMBridgeService::Start()` nur bei gesetztem External-Flag. | Vor Child-Start ZIP/Root-/Payload-/Config-/Personality-Kette gegen die A-R1-Pins prüfen. Exakte Ready-Werte; sonst Service disabled/failed, World ohne LLM. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:48-55` | `UpdateWorld()` im vorhandenen World-Hook aufrufen. | Completions werden nur im World-Thread aufgelöst und zugestellt. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:56` | Vor Klassenende `OnShutdown()` ergänzen: Admission schließen, `shutdown drain=true`, endliche Frist, Child/Worker joinen. | Keine detached Threads, Pipe-Handles oder Child-Prozesse nach Shutdown; kein Gameobjektzugriff beim Join. |
| `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:209-219,222-226,231-234` | Bei Login Sessiongeneration/Fingerprint registrieren; bei BeforeLogout und ReleaseToClient invalidieren und passende Routes retire. | Relog oder Sessionwechsel kann keine alte Completion empfangen. Gespeichert werden ausschließlich GUID, Account, Joinzeit und Generation. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1686-1935` mit Eignungsanker `:1796` | Getrennte External-Eignung für Whisper ergänzen; `isAiChat` und Random-Chat-Verzögerung nicht wiederverwenden. | Nur Bot 18281, `CHAT_MSG_WHISPER`, echter fremder Spieler, gültiges UTF-8 und External-Flag. Keine weiteren Kanäle/Bots. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:1222-1255,8678-8682` | Bestehende World-/AI-Thread-Grenze für kopierte Chatwerte beibehalten. | Request entsteht im World-/AI-Thread, nicht im Netzwerk-/Packetthread oder Worker. |
| `src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp:451-672`; Ersetzungsbereich `:512-669` | Legacy-Async-LLM-Zweig vollständig durch kleinen External-Admission-Zweig ersetzen. Kein Promptbau, keine Packetvorlage, kein `std::async`, kein `PlayerbotLLMInterface::Generate`. | Route erfasst UUIDv4, Bot-/Ziel-GUID, Sessionfingerprints, Wire-UTC und 45-s-`steady_clock`-Deadline. Queue-/Ledger-full oder Fehler => stilles Fail-closed, kein Fallback. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.h:553-554` | Nach Entfernung des einzigen Callers die alten LLM-Delayed-Packet-Deklarationen entfernen. | Verhindert Wiederverwendung des pointerhaltigen detached-Pfads. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:7978-8006` | Zugehörige detached Helfer entfernen, sobald `SayAction.cpp:655` entfällt. | Kein `WorldSession*`/`PacketHandlingHelper*` überlebt einen World-Lebenszyklus. |
| `src/game/Objects/Player.cpp:19377-19386` | **Nicht ändern.** `Player::Whisper` bleibt der einzelne Ausgabeprimitive nach World-Thread-Revalidierung. | Target wird durch GUID übergeben; kein alternatives Delivery-System. |
| `src/modules/PlayerBots/playerbot/PlayerbotAI.cpp:3588-3616`, besonders `:3607-3614` | Bestehende teamabhängige Protokollsprachenwahl als Referenz verwenden: Alliance `LANG_COMMON`, Horde `LANG_ORCISH`. | Englischer Inhalt ist kein Grund für `LANG_COMMON`. Die WoW-`Language`-Enum wird erst aus dem frisch aufgelösten Bot-Team bestimmt; kein Language-Feld aus dem Child akzeptieren. |
| `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp:602-606` | Bestehende GUID-basierte Botauflösung verwenden. | Kein gespeicherter `Player*`; Bot unmittelbar vor Zustellung neu auflösen. |
| `src/game/WorldSession.h:335-342,355-360` | `GetState()==READY` nicht als alleinigen Sessionbeweis verwenden; Account/Joinzeit mit lokaler Generation kombinieren. | Bot und Ziel müssen dieselbe beobachtete Sessiongeneration wie bei Admission besitzen. |
| `src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp:376-382` | **Unverändert lassen.** Release-No-op wird vom External-Pfad nie aufgerufen. | Keine Übernahme früherer Debug-HTTP-/Endpoint-Änderungen. |
| `src/modules/PlayerBots/playerbot/strategy/actions/RpgSubActions.cpp:409-563` und `strategy/triggers/RpgTriggers.cpp:627-639` | **Unverändert und nicht anbinden.** | Keine Aktion, kein Emote, kein öffentlicher Chat und kein Command aus Modelltext. |
| `src/modules/PlayerBots/CMakeLists.txt:25` | **Keine Änderung.** Vorhandener GLOB erfasst die zwei neuen Service-Dateien. | Keine historische Debug-Include-Änderung übernehmen. |

## Paket- und Startup-Prüfung

1. Vor Verwendung das bereitgestellte Correction-ZIP gegen `36485E409BEBD3A9ECD5B85EE5CB58D1EC39CEB5661AA079559BCD2E76777434` prüfen.
2. Sicher in ein neu bestimmtes Paketroot extrahieren; absolute Pfade, `..`, Symlink-/Reparse-Escape und doppelte kanonische Namen ablehnen.
3. Root-Manifestdatei gegen `522D3358D28D7A8CC69DEF1D385A38399557F6E2C9BED777565C6CB4A403353C` prüfen, anschließend jeden darin genannten Eintrag.
4. Payload-Manifest gegen `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B` und jeden Payload-Eintrag prüfen.
5. Config und Personality gegen `D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902` beziehungsweise `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E` prüfen.
6. `bridge/phase1a-report.md` nicht als Runtime-Eingabe oder Pinquelle lesen; Klassifikation `historical_evidence_only`.
7. Child ohne Shell mit direkt übergebenem Executable und Argumentarray `src/cli.mjs --run` starten. Kein geerbtes fremdes stdin/stdout.
8. Ready exakt auf Modus, Kapazitäten, Bot und Modell prüfen; jeder Mismatch beendet/joint das Child und deaktiviert den Adapter ohne Auto-Restart.

## Exakte lokale V1-Grenzen

- Ingress: höchstens zwei wartend und einer aktiv; Completion: höchstens drei; Outstanding-Map höchstens drei; Bridge-Ledger unverändert 64.
- Request: höchstens 16.384 JSON-Bytes, Nachricht höchstens 2.048 UTF-8-Bytes, TTL lokal 45.000 ms, absolute Bridge-Obergrenze 60.000 ms, maximal 5.000 ms Clock-Skew.
- UUIDv4: 16 CSPRNG-Bytes, RFC-4122-Version-/Variantbits, lowercase kanonisch. Eine Kollision führt zu lokalem Fail-closed, nicht zu einer neuen ID oder einem Resubmit.
- JSON/NDJSON: striktes UTF-8 ohne BOM, keine Duplicate Keys oder unpaarigen Surrogates, exakte Feldmengen, begrenzte Tiefe und Zeilengröße.
- Polling: nur `status` für bereits submitted Keys; niemals ein zweites `submit`.
- Consume: terminal genau einmal; nur bei freier lokaler Completion-Kapazität; danach Key lokal sofort `consumed/retired`.
- Completiontext: strict UTF-8, nicht leer, keine verbotenen Controls, höchstens 240 Codepoints, höchstens 240 UTF-8-Bytes und zwei Terminatorläufe. Jede Übergrenze verwirft den gesamten Text; keine Substring-, Byte- oder Codepoint-Kürzung.

## Zustellprüfung im World-Thread

Bei jedem Fehler wird die Route ohne Text retired:

1. Exact outstanding key `request_id + bot_guid`; noch nicht retired oder consumed.
2. Lokale `steady_clock`-Deadline nicht erreicht.
3. Completion mit exakter V1-Feldmenge, identischen IDs, `outcome=ready`, gepinntem Modell, `attempt_count=1`, null Error und begrenzten Raw-Bytes.
4. Sanitizer-Kanonizität bytegleich; strict UTF-8; Codepoint-, UTF-8-Byte- und Satzgrenze erneut prüfen. Überlänge nicht abschneiden.
5. Bot per GUID neu auflösen; gepinnter Playerbot, AI/in-world/Session gültig, kein Logout, Account/Joinzeit/Generation identisch.
6. Ziel per GUID neu auflösen; echter Spieler, kein Bot, in world, Session vorhanden, `session->GetPlayer()==target`, kein Logout, Account/Joinzeit/Generation und Name identisch.
7. External-Flag, Bot-Pin und feste Route Whisper weiterhin aktiv.
8. WoW-Protokollsprache aus dem aktuell aufgelösten Bot-Team bestimmen (`LANG_COMMON` nur Alliance, `LANG_ORCISH` Horde); niemals aus der natürlichen Sprache `English` ableiten.
9. Key vor Ausgabe atomar retiren; genau ein `bot->Whisper(text, protocolLanguage, targetGuid)` im World-Thread.

Explizit verboten bleibt die Übergabe von Modelltext an `PlayerbotAI::HandleCommand`, `HandleCommands`, `ExternalEventHelper::ParseChatCommand`, `DoSpecificAction`, `TellPlayerNoFacing`, `LinesToPackets`, `TextEmote`, `HandleEmoteCommand`, `.bot/.rndbot` oder Admin-/Server-Command-Handler.

## Spätere Verifikation – nicht ausgeführt

1. Unit-Tests: UUID, strict JSON, 1+2 Queue, Ledger 64 fail-closed, Duplicate/Mismatch/Stale/Expiry/Consume-once, monotone Deadline bei Wallclock-Sprüngen, exakte 240-Codepoint-/240-Byte-Grenzen einschließlich Multibyte-UTF-8 und No-Truncation.
2. Fake-Child-Tests: Paket-/Manifest-/Ready-Mismatch, partielle/zu große NDJSON-Zeilen, Child-Abbruch, kein Auto-Restart, endliche Shutdown-Frist, Worker-Join und Handle-Freigabe.
3. World-Harness: Logout/Relog von Bot und Ziel zwischen Admission und Completion; kein Text bei Mismatch; genau ein Whisper im gültigen Fall; Horde-Bot verwendet nicht wegen englischem Inhalt `LANG_COMMON`.
4. Static Gate: im Service kein `Ollama`, `11434`, HTTP-Client, `.detach`, Action-/Emote-/Command-Dispatch; im Produktionsdiff keine der vier historischen Debug-Hunks.
5. Erst nach separater Phase-B-Freigabe implementieren und anschließend aus isoliertem Baseline-Commitzustand bauen. Kein Deployment oder Live-Test ohne weitere Freigabe.
