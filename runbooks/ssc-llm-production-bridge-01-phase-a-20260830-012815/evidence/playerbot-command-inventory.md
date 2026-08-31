# Separater read-only PlayerBot-Befehlsnebenstrang

Referenz: Commit `42b8a7f742548793910fe8880463aeeb71627fb9`. Diese Inventur ist ausdrücklich kein Bestandteil des minimalen V1-Bridge-Patches und genehmigt keine Action-Allowlist.

## Statische `.bot/.rndbot`-Kommandos

Quelle: `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp:3097-3183`.

- 52 Map-Zeilen, 51 eindeutige Schlüssel; `spoof` ist doppelt aufgeführt.
- Schlüssel: `list`, `help`, `reload`, `tweak`, `self`, `group`, `create`, `spoof`, `runtest`, `add`, `login`, `remove`, `logout`, `rm`, `delete`, `gear`, `equip`, `train`, `learn`, `food`, `drink`, `potions`, `pots`, `consumes`, `consumables`, `regs`, `reg`, `reagents`, `prepare`, `prep`, `refresh`, `init`, `enchants`, `ammo`, `pet`, `levelup`, `level`, `random`, `always`, `debug`, `c`, `w`, `p`, `g`, `r`, `rl`, `do`, `cmd`, `record`, `read`, `clear`, `spoof`.
- Besonders aktionsrelevant: `debug`, `c`, `do`, `cmd`; besonders zustellrelevant: `w`, `p`, `g`, `r`.

## Dynamische Creator-Registrierungen

Gezählt wurden im Commit alle literalen `creators["..."]`-Registrierungen unter `src/modules/PlayerBots/playerbot`.

| Kategorie | Registrierungen | Eindeutige Schlüssel | Dateien |
|---|---:|---:|---:|
| Actions (`strategy/actions`) | 454 | 451 | 3 |
| Triggers (`strategy/triggers`) | 448 | 448 | 3 |
| Values (`strategy/values`) | 348 | 348 | 2 |
| Strategy/sonstige Contexts | 2,357 | 1,576 | 48 |
| **Gesamt** | **3,607** | **2,548** | **56** |

Die Werte sind eine statische Source-Inventur, nicht die Behauptung, dass jeder Schlüssel aus jedem Laufzeitkontext direkt als Spielerbefehl erreichbar ist.

## Relevante Gateways

- `PlayerbotAI.cpp:1189-1213`: queued Chattext wird an `ExternalEventHelper::ParseChatCommand` übergeben.
- `PlayerbotAI.cpp:1469-1560`: `HandleCommand`, `debug`, `do` und `DoSpecificAction`.
- `strategy/ExternalEventHelper.h:14-59,82-92`: Präfix-/Parameterauflösung und Trigger-Dispatch.
- `SayAction.cpp:355-440` sowie `RpgSubActions.cpp:551-563`: Legacy-Modelltext kann als Chat-/Emote-Paket interpretiert werden; dieser Pfad ist für External V1 verboten.

## V1-Entscheidung

`V1_ACTION_ALLOWLIST=[]`

Freier Completion-Text wird ausschließlich als privater Whisper-Payload behandelt. Es gibt keine Syntax, kein Präfix und keinen Inhalt, der Text in Botaktion, Emote, Chatkommando, `.bot/.rndbot`-Kommando oder Serverkommando umwandelt.

Ein späterer Action-Vertrag müsste separat mindestens enthalten: eigene Schema-Version, getrenntes strukturiertes `action`-Feld statt Textparsing, kleine hardcodierte Allowlist, typsichere Parametergrenzen, Berechtigungs- und World-State-Prüfung, idempotente Action-ID, Auditlog und eigene Freigabe. Nichts davon gehört in V1.
