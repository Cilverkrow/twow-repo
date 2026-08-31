# SSC-OLLAMA-MANUAL-SCALING-01 – Phase-1-Preflight

Erfasst am 29.08.2026 (Europe/Berlin). Umfang: ausschließlich Phase 1, read-only gegenüber Source, produktiver Config, Binärdatei und Datenbank. Phase 2 und Phase 3 wurden nicht begonnen.

## Abschluss

`SINGLE_BOT_PREFLIGHT_RESULT=ABORT`

`AUTOMATIC_BOT_COUNT_ZERO_SUPPORTED=YES`

`MANUAL_RNDBOT_ADD_WITH_ZERO_AUTOMATIC_SUPPORTED=YES`

`TEST_BOT_NAME=Meladu`

`TEST_BOT_GUID=23143`

`PRODUCTION_LLM_PATH_AVAILABLE=NO`

`PHASE_2_STARTED=NO`

Der ABORT ist erforderlich, obwohl die beiden Randombot-Prüfungen mit YES beantwortet werden können: Die aktive Produktions-EXE enthält denselben deaktivierten `PlayerbotLLMInterface::Generate`-Pfad wie der nachgewiesene HEAD-Stand. Dieser gibt ohne Netzwerkzugriff immer eine leere Antwort zurück. Die im Dirty Tree vorhandene spätere Debug-Implementierung ist weder Bestandteil der produktiven EXE noch eine freigegebene Integration der externen Bridge. Der aktive Config-Endpunkt zeigt außerdem direkt auf Ollama und nicht auf die verifizierte externe Bridge. Ein Einzelbot-LLM-Test nach Phase 2 könnte deshalb die verlangte Funktion nicht nachweisen und darf nicht gestartet werden.

## 1. Aktive Config und Identität

| Merkmal | Wert |
|---|---|
| Pfad | `C:\TW\ComTW\server\aiplayerbot.conf` |
| Größe | 283.717 Byte |
| Änderungszeit UTC | `2026-08-29T16:04:14.8193927Z` |
| SHA-256 | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` |

Der Hash war bei der ersten und abschließenden Prüfung identisch. Die Config wurde nicht verändert.

## 2. Steuernde Configwerte

| Zweck | Aktiver Wert | Bewertung |
|---|---:|---|
| Playerbot-System allgemein: `AiPlayerbot.Enabled` | `1` | System aktiv |
| Alternative Account-Bots: `AiPlayerbot.BotAutologin` | `0` | kein allgemeiner Alt-Bot-Autologin |
| Randombot-Manager: `AiPlayerbot.RandomBotAutologin` | `1` | muss für den Legacy-Randombot-Updatepfad aktiv bleiben |
| Startwert: `AiPlayerbot.RandomBotLoginAtStartup` | `1` | wird in dieser Revision geladen, aber nirgends konsumiert; kein wirksamer Schutz |
| Minimum: `AiPlayerbot.MinRandomBots` | `50` | gegenwärtige automatische Sollzahl |
| Maximum: `AiPlayerbot.MaxRandomBots` | `50` | gegenwärtige automatische Sollzahl |
| Logins pro Intervall | `30` | nur relevant, wenn Onlinezahl unter Sollzahl liegt |
| Asynchroner Login | `0` | alternativer Loginmanager aus |
| Login nur mit Spieler | nicht gesetzt, Default `0` | keine zusätzliche Sperre |
| Pinned Bots | nicht gesetzt, effektiv leer | keine Kohorte/Allowlist |
| LLM-Aktivierung: `AiPlayerbot.LLMEnabled` | `0` | LLM aktuell aus |
| Global Context | nicht gesetzt, Default `0` | aus |
| Bot-to-Bot-LLM-Chance | `0` | aus |
| RPG-LLM-Chance | `0` | aus |
| blockierte LLM-Kanäle | nicht gesetzt, effektiv leer | bei einer Aktivierung wäre kein erkannter Kanal blockiert |

Der aktive LLM-Endpunkt ist `http://127.0.0.1:11434/v1/chat/completions`. Er ist ein direkter Ollama-Endpunkt und nicht die freigegebene externe Bridge. Der konfigurierte API-Key ist leer. `AiPlayerbot.LLMDefaultPromptsFile=llm_character_card.txt`; die aufgelöste Datei `C:\TW\ComTW\server\llm_character_card.txt` existiert nicht. Damit sind auch die verlangten englischen Ollama-Prompts derzeit nicht als vorhandenes Config-Artefakt nachgewiesen.

Die vom Source erkannten Blocktokens sind:

`guild, world, general, trade, lfg, ldefence, wdefence, grecruitement, say, whisper, emote, temote, yell, party, raid`

Für eine spätere Whisper-only-Konfiguration wären – ohne `whisper` – exakt diese Tokens zu blockieren:

`guild,world,general,trade,lfg,ldefence,wdefence,grecruitement,say,emote,temote,yell,party,raid`

Die Schreibweisen `ldefence`, `wdefence` und `grecruitement` entsprechen dem Source und dürfen nicht stillschweigend korrigiert werden. `AiPlayerbot.RandomBotSayWithoutMaster=1` erlaubt unabhängig vom LLM weiterhin Legacy-Bot-Sprache ohne Master; ein späterer Nachweis „keine öffentliche LLM-Antwort“ muss diese Nicht-LLM-Ausgaben unterscheiden.

## 3. Automatische Zielzahl 0 bei funktionsfähigem manuellem Bot

Analysiert wurde der nachgewiesene HEAD-Stand:

- Repository: `C:\TW\ComTW\source`
- Commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Tree: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`

Die relevanten Steuerdateien wurden gegen HEAD verifiziert und sind unverändert. Der Dirty Tree enthält vier bekannte LLM-Debugänderungen und sechs unversionierte PDB-Dateien; sie wurden nicht als Beweis für die produktive Funktion verwendet.

Der Legacy-Ablauf in `RandomPlayerbotMgr::UpdateAIInternal` ergibt:

1. Bei `RandomBotAutologin=0` kehrt der Manager nach `UpdateSessions` sofort zurück. Diese Option ist deshalb **nicht** die geeignete Methode, einen manuell hinzugefügten RNDBOT vollständig funktionsfähig zu halten.
2. Bei `RandomBotAutologin=1`, `Enabled=1`, `MinRandomBots=0` und `MaxRandomBots=0` wird der gespeicherte globale `bot_count` auf 0 normalisiert.
3. Die Erzeugungs-/Auffülllogik läuft nur bei `availableBotCount < maxAllowedBotCount`; bei Maximum 0 ist das falsch.
4. Die automatische Login-Schleife läuft nur bei `onlineBotCount < maxAllowedBotCount`; bei Ziel 0 ist das ebenfalls falsch.
5. `.rndbot add <ExactName>` wird separat über `HandleBotAddLogin` verarbeitet. Für ein RNDBOT-Konto ruft der Pfad direkt `RandomPlayerbotMgr::AddRandomBot(guid)` auf und hat keine Min-/Max-Sollzahlprüfung.

Die quellseitig geeignete spätere Zielkonfiguration wäre daher semantisch „automatische Onlinezahl 0“, nicht „Randombot-Manager aus“:

```ini
AiPlayerbot.Enabled = 1
AiPlayerbot.BotAutologin = 0
AiPlayerbot.RandomBotAutologin = 1
AiPlayerbot.MinRandomBots = 0
AiPlayerbot.MaxRandomBots = 0
AiPlayerbot.AsyncBotLogin = 0
```

Dies ist nur eine dokumentierte Vorlage. Sie wurde nicht angewendet.

## 4. Vorhandene `owner=0/event=add`-Einträge

Die SELECT-Evidenz zeigt:

- 500 RNDBOT-Konten und 4.500 gespeicherte RNDBOT-Charaktere;
- 53 `owner=0,event=add`-Zeilen mit Wert ungleich 0;
- einen globalen `bot_count`-Eintrag;
- keine ausgegebenen `login`-Eventzeilen;
- 11 RNDBOT-Charaktere in fünf persistenten Gruppen.

`GetBots()` liest die bestehenden `owner=0,event=add`-Zeilen zwar als verfügbare Bots ein. Bei Min/Max 0 erfüllt die Haupt-Login-Schleife jedoch nicht ihre Bedingung; die 53 Einträge werden dadurch nicht automatisch eingeloggt und müssen nicht gelöscht oder verändert werden.

Es existiert ein gesonderter `AddOfflineGroupBots()`-Pfad, der außerhalb der Min-/Max-Loginbedingung einen offline befindlichen RNDBOT einer Gruppe nachladen kann, wenn ein in der Manager-`players`-Map geführter echter Spieler Gruppenleiter ist. Die aktuelle Datenbank enthält zwar 11 RNDBOT-Gruppenmitglieder, aber alle fünf Gruppenleiter sind selbst RNDBOT; kein nicht-RNDBOT-Gruppenleiter wurde gefunden. `OnPlayerLogin()` nimmt Free-/Random-Bots nicht in `players` auf. Für den **aktuellen** Datenstand ist damit kein solcher Bypass-Kandidat vorhanden. Vor Phase 2 wäre dieser flüchtige Gruppenzustand erneut read-only zu prüfen; ein später hinzugefügter echter Gruppenleiter würde die Bewertung ändern.

`PinnedBots` ist leer. Der Pinned-Pfad wird zudem nur innerhalb der bei Maximum 0 falschen Auffüllbedingung aufgerufen. `LoginFreeBots()` betrifft separat konfigurierte Free-Alt-Bots und nicht die hier ausgewählten RNDBOT-Konten.

## 5. Ausgewählter Testbot

| Merkmal | Wert |
|---|---|
| exakter Name | `Meladu` |
| Bot-GUID | `23143` |
| Konto | ID `75`, `RNDBOT79` |
| Rasse | ID `1`, Human |
| Klasse | ID `5`, Priest |
| Level | `2` |
| Online-Flag bei SELECT | `0` |
| Berufe | Alchemy (Skill 171) `1/75`; Herbalism (Skill 182) `1/75` |
| add-Status bei SELECT | Wert `1`, `validIn=10848` |
| login-Status bei SELECT | Wert `0` |
| persistente Gruppenmitgliedschaft | nein |

Meladu ist ein vorhandener, offline befindlicher RNDBOT mit zwei dokumentierbaren Berufen und ohne persistenten Gruppenpfad. Die `validIn`-Angabe ist eine Momentaufnahme der SELECT-Ausführung und keine spätere Laufzeitgarantie. Es wurde kein Bot eingeloggt und kein Event verändert.

## 6. Produktiver LLM-Gate-Befund

Die produktive `C:\TW\ComTW\server\mangosd.exe` hat SHA-256 `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` und enthält die eingebettete Revision `42b8a7f742548793910f`, lokal eindeutig auf den vollständigen Commit `42b8a7f742548793910fe8880463aeeb71627fb9` auflösbar.

Der zugehörige HEAD-Source in `PlayerbotLLMInterface.cpp:376-383` dokumentiert und implementiert ausdrücklich:

- Netzwerkclient entfernt;
- optionaler Debughinweis `LLM generation disabled in this build`;
- Rückgabe einer leeren Zeichenkette.

Das Literal `LLM generation disabled in this build` wurde zusätzlich direkt in der produktiven EXE gefunden. Die produktive EXE entspricht nicht dem späteren Dirty-Debug-Build. Damit ist `PRODUCTION_LLM_PATH_AVAILABLE=NO` belegt.

Eine Freigabe von Phase 2 setzt mindestens einen separat freigegebenen, zur externen Bridge integrierten und nachweisbar gebauten/deployten Source-/EXE-Stand voraus. Dessen Configschema, Endpoint, Promptdatei, Timeoutgrenzen und Whisper-only-Kanäle müssten anschließend neu validiert werden. Dieser Arbeitsauftrag autorisiert keine solche Integration, keinen Build und kein Deployment.

## 7. Unverändertheits- und Sicherheitsbestätigung

- keine produktive Config- oder Sourceänderung;
- keine Datenbankschreiboperation und keine Migration; alle SQL-Aufrufe waren SELECT-only;
- kein Bot-Login, kein Game-Chat und keine Änderung von `add`-/`login`-Events;
- keine Prozesssteuerung;
- keine Ollama-Inferenz;
- keine Übernahme der Dirty-Debugänderungen;
- Phase 2 und Phase 3 nicht begonnen.

Die einzigen neu erzeugten Dateien liegen im separaten Runbook-Verzeichnis `C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352` und bestehen aus Bericht, Hilfsskripten und Evidenz.

## 8. Evidenzindex

- `evidence/active-aiplayerbot-config-evidence.json`: Configidentität, Werte, Defaults, Kanal-Tokens und Promptdateiprüfung
- `evidence/source-identity.json`: Commit, Tree, vollständiger Status und Hash-/Blobprüfung relevanter Dateien
- `evidence/source-control-flow-excerpts.txt`: zeilennummerierte HEAD-Auszüge für Config, Queue/Login, CLI-Add und Chatkanäle
- `evidence/source-group-login-gate.txt`: zeilennummerierte HEAD-Auszüge für den Offline-Gruppenpfad und `OnPlayerLogin`
- `evidence/llm-path-gate.json`: HEAD-No-op, produktiver EXE-Hash/Literal und Endpunktbewertung
- `evidence/db-discovery-selects.*`: unveränderte SQL-Datei, vollständige Ausgabe, leeres stderr und Metadaten
- `evidence/bot-candidate-selects.*`: Gruppen-Bypass- und Kandidatenprüfung
- `evidence/active-add-candidate-select.*`: reproduzierbare Auswahl von Meladu und Berufen
- `evidence/phase1-readonly-integrity.json`: erste/letzte Configidentität und Negativnachweise
- `evidence/final-readonly-verification.json`: abschließender Config-/EXE-Hash, HEAD und vollständiger Git-Status

Nach diesem Bericht wird gestoppt. Es erfolgt keine nächste Phase.
