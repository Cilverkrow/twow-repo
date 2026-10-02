# Bot-Sozialverhalten: Gilden, Quest-Abschluss, Gruppen-, Eskort- und Dungeon-Quests (#485)

- **Status:** Entwurf zur Prüfung durch den Inhaber. Das Dokument ist ein Vorschlag, keine Entscheidung.
- **Issue:** Refs #485. Verwandte Issues: #324, #365, #343, #453, #340, #405, #422, #474, #478, #484, #241.
- **Zuständiger Chat:** OB-10. Chat und Addon liegen bei OB-15, Daten und Zählungen bei OB-40, Konfigurations- und Log-Evidenz bei OB-30.
- **Datum:** 2026-10-02/03
- **Quellstände:**
  - Core `origin/main` e368599e. Live läuft `release/8.x` 441d62e7. Beide Commits haben einen identischen Tree (b4eae646, `git diff` leer). Zeilenangaben gelten deshalb für main und live gleichermaßen.
  - Repo `origin/main` 048788cf. Es pinnt core auf 441d62e7 (#476).
- **Live-Stack:** `ws50-roster-v24-180-048788cf`. Laut Smoke-Test vom 02.10. 19:30Z: Roster v6, 180/180 Bots online.
- **Methode:**
  - Ausgewertet wurden nur gesicherte Logs und Dumps auf Y: sowie Code über Git-Refs. Es gab keine Live-Abfragen, keine DB-Verbindung, keine Builds und kein Docker.
  - Die Live-Konfiguration ist nachgebaut: Core-Vorlage, darauf das compose-Overlay, darauf das Profil `funserver-test`, analog zu `deploy/compose/render-config.sh:262-307`. Auf Y: liegt keine gesicherte v24-Datei.
  - Dass live das Profil `funserver-test` läuft, ist nur indirekt belegt (UNSICHER, aber sehr wahrscheinlich).
- **Evidenz** (Wurzel `Y:\backup twwow\workspace-relocation-20260902\evidence\`):
  - `ws-60/ob00-train8b-window/live/pre-dump/tw_char.sql`: Stand 01.10. 03:06Z, sha256 `23fddf67…64af`
  - `ws-60/ob00-train8b-window/live/pre-dump/tw_world.sql`: sha256 `cac2d36a…4d43`
  - `ws-60/longrun-7d/*/{bot_events,deaths}.csv, perf.log`: 26.09. bis 30.09.
  - Ergänzend `builds/ob30-*/gameplay-logs` bis 02.10. 21:08Z
  - Arbeitsausgaben unter `ws-10/cli485-bot-social/work/{gilden,quest-logs,quest-classify,quest-join,quest-code,groups-death-tick,escort-dungeon,live-config}/`, mit `SHA256SUMS` bzw. `*sha256*.txt`
- **Vorbehalt zur Messgröße:** Das Log-Event `TalkToQuestGiverAction` wird vor `CanRewardQuest` geschrieben (`TalkToQuestGiverAction.cpp:87` gegenüber `:113/:135`). Es zählt also Abgabe-**Versuche**. Belastbar ist nur `character_queststatus.rewarded`.

---

## 1. Gilden

### 1.1 Ist-Stand (Dump 01.10. 03:06Z, vor Zug 8b)

| Größe | Wert |
|---|---|
| Zeilen in `guild` / `guild_member` / `guild_rank` | 0 / 0 / 0 |
| `petition` (gekaufte Urkunden, Item 5863) | 40. Besitzer: 39 aus Roster v6. Fraktion: 23 Allianz, 17 Horde |
| `petition_sign` | 168 Zeilen von 110 Unterzeichnern, davon 107 aus Roster v6, verteilt auf 29 Petitionen |
| Unterschriften pro Petition | 0 Unterschriften: 11 · 1–8: 21 · genau 9: 4 (IDs 6, 20, 23, 39) · mehr als 9: 4 (IDs 10:10, 22:14, 31:12, 59:10) |
| Sofort abgabefähig, Urkunde noch im Inventar | 3: Besitzer 18 (pid 39), 310 (pid 20), 328 (pid 23) |
| Verwaiste Petitionen (Urkunde nicht mehr im Inventar) | pid 6 (Besitzer 34) und pid 10 (Besitzer 9) |
| Unterzeichner auf mehreren Petitionen | 39 (22 auf 2, 15 auf 3, 2 auf 4) |

Die Bots kaufen also Urkunden und sammeln Unterschriften, schließen die Gründung aber nie ab. **OB-40 zählt den aktuellen Stand am 03.10.** mit einer leichten Abfrage ohne Joins: `COUNT(*)` je Tabelle für `guild`, `guild_member`, `petition` und `petition_sign`.

### 1.2 Ursachen

1. **Hauptursache ist ein Schlüsselfehler aus der Portierung cmangos→vmangos.**
   - `PetitionSignsValue` sucht in `petition_sign.petitionguid` nach dem **Item-GUID-Zähler der Urkunde** (`GuildValues.cpp:1276`). In vmangos steht in dieser Spalte aber eine eigene Petition-ID. Sie entsteht in `GeneratePetitionID`, liegt im Enchantment-Slot 0 und wird in `PetitionsHandler.cpp:147-154` sowie `GuildMgr.cpp:509` verwendet.
   - Im Dump liegen die Petition-IDs bei 1..61, die Urkunden-GUIDs bei 69546..193342. Die Abfrage findet deshalb nie eine Zeile, und „petition signs“ ist immer 0.
   - Folge 1: `PetitionTurnInAction::isUseful` (`GuildCreateActions.cpp:320`) und `GuildValues.h:265` verlangen `>= MinPetitionSigns` (laut Rekonstruktion aus Vorlage und Overlays 9, ohne Live-Abzug, siehe offene Frage 2). Die Bedingung wird nie wahr, der Bot reicht also nie ein.
   - Derselbe Fehler steckt in `PetitionOfferAction` (`GuildCreateActions.cpp:151` und `:160-163`). Die Prüfung „schon unterschrieben“ greift nie, und `isUseful` von „offer petition nearby“ (`GuildCreateActions.h:32`) bleibt dauerhaft wahr.
   - Folge 2: Die Bots bieten endlos an, ausgelöst über den Trigger „random“ (`GuildStrategy.cpp:8-10`). Pro gildenlosem Kandidaten in Sichtweite laufen dabei **2 synchrone `CharacterDatabase.PQuery`** im Update-Thread des Bots.
2. **Zweiter Blocker im Core: Altlast.**
   - `Petition::IsComplete()` prüft `size == MinPetitionSigns` (`GuildMgr.h:134`). `LoadPetitions` übernimmt Unterschriften beim Laden ohne Obergrenze (`GuildMgr.cpp:215, 261-262`). Bei mehr als 9 Unterschriften lehnt `HandleTurnInPetitionOpcode` die Abgabe ab (`PETITION_SIGN_NEED_MORE`, `PetitionsHandler.cpp:529`).
   - Die Petitionen 10, 22, 31 und 59 bleiben deshalb auch nach Fix 1 blockiert.
   - Sehr wahrscheinlich sind das Altzeilen aus dem `DeleteFromDB`-Fehler, der mit #241/06262d6d am 30.09. behoben wurde. Der Fix räumt diese Zeilen nicht auf.
   - Die Blockade ist nicht absolut: Die Zahl sinkt, wenn ein Unterzeichner einer Gilde beitritt, gelöscht wird oder die Urkunde zerstört wird.
3. **Dritte Hürde nach Fix 1: Ort und Reise.** `PetitionTurnInAction::isUseful` (`GuildCreateActions.cpp:298-320`) verlangt außer `petition signs >= MinPetitionSigns` auch: Strategie `travel`, `ChooseTravelTargetAction::isUseful`, eine Zone mit `AREA_FLAG_CAPITAL` und `!travel target traveling`. Quest-first-Roster-Bots kommen selten in Hauptstädte. Auch nach Fix 1 ist deshalb UNSICHER, ob die 3 abgabefähigen Bots (18, 310, 328) zeitnah einreichen. Abhilfe: Der `[Guild]`-Trace aus S4 loggt den `isUseful`-Grund; optional wird eine Reise zur Hauptstadt eingeplant, sobald die Unterschriften reichen (Zug 9, Spielentscheidung, Abbruch nach N Versuchen).
4. **Der klassische Weg über die Fabrik ist abgeschaltet, und das ist gewollt.**
   - `InitGuild` und `CreateRandomGuilds` sind der einzige Code, der `RandomBotGuildCount` liest (`PlayerbotFactory.cpp:360-364, 5037-5038`). Für Roster-Bots läuft dieser Weg im Normalbetrieb nie:
     - `randomizeProgression=false` (`PersistentActiveRoster.cpp:355`, gelesen in `RandomPlayerbotMgr.cpp:2917`)
     - Rücksprung in `RandomizeFirst` (`:3855-3858`)
     - `OnBotLoginInternal` ruft kein `InitGuild` auf (`:4576-4591`)
   - `DisableRandomLevels=1` ist dabei **keine** eigene Sperre (`PlayerbotFactory.cpp:191-214`).
   - Der Weg bleibt über GM-Befehle erreichbar (`.bot random`, `.bot levelup`, `.bot init=`, `rndbot upgrade`) und theoretisch über InstaRandomize beim ersten Login, wenn ein Bot über Startlevel noch keine Spielzeit hat.
5. **Was nicht die Ursache ist:**
   - **Strategie:** Die Strategie `guild` haben freie Bots ohne Gruppe oder als Gruppenleiter (`AiFactory.cpp:1098/1109`) sowie Bots in einer Gruppe mit Bot-Master (`:1136-1141`). `rpg guild`, also der Urkundenkauf, kommt über `rpg` dazu (`RpgStrategy.cpp:30`).
   - **Schalter:** Laut Rekonstruktion sind live `RandomBotFormGuild=1`, `GuildCount=12`, `GuildNearby=1`, `AllowGuildBots=1` und `DeleteRandomBotGuilds=0` gesetzt.
   - **Weitere Module:** BotBrain (twow-repo) enthält keinen Gildencode. `PlayerbotGuildMgr` in mod-dungeon-clear ist nur ein Stub. `BeginnersGuilds` (Gilde 126) schließt RNDBOT-Konten aus und ist für Bots wirkungslos.
6. **Voraussetzungen für den Urkundenkauf** (`GuildCreateActions.cpp:80-112`): GuilderType und GrouperType dürfen nicht SOLO sein (je etwa 20 % der Bots). Außerdem nötig sind mindestens 1000 Kupfer freies Gildenbudget und ein Urkunden-NPC in Reichweite. Im Dump halten 39 von 180 Roster-v6-Bots (22 %) eine offene Petition, dazu 1 Nicht-Roster-Charakter. Die Petition-IDs reichen bis 61, frühere Urkunden sind also verschwunden; die Zahl ist eine Untergrenze der Käufe (UNSICHER).

### 1.3 Vorschlag

| Punkt | Vorschlag |
|---|---|
| **Fix** (Hotfix, keine DB) | `PetitionSignsValue` und `PetitionOfferAction` zählen im Speicher statt per SQL: `sGuildMgr.GetPetitionByCharterGuid(...)->GetSignatureCount()` bzw. `GetSignatureForAccount(accountId)`. `SingleCalculatedValue` wird zu einem `CalculatedValue` mit etwa 10 s Lebensdauer. Contract-Test: Kein Treffer für `petition_sign` in `mod-playerbots/strategy`. |
| **Altlast** (Hotfix, Core, keine DB) | `IsComplete` prüft `>=` statt `==`. `LoadPetitions` übernimmt je Unterzeichner nur eine Unterschrift und je Petition höchstens `MinPetitionSigns`. Überzählige Zeilen werden nur geloggt und nicht gelöscht. Wer die Daten lieber per SQL bereinigt, braucht dafür eine Einzelfreigabe (DB-Mutation, Hauptzug, OB-40). |
| **Anzahl** | `RandomBotGuildCount` begrenzt die Gründung per Urkunde **nicht**. Ohne Obergrenze entstehen theoretisch bis zu etwa 18 Gilden à 10 Bots. Vorschlag: In `BuyPetitionAction::canBuyPetition` gilt Bot-Gilden plus offene Urkunden der eigenen Fraktion < `RandomBotGuildCount/2`, also 6 je Fraktion. Empfehlung: 4–6 je Fraktion. |
| **Größe** | Start mit etwa 10–15 Mitgliedern, Wachstum über `GuildManageNearby` (`GuildManagementActions.cpp:67-238`). Zielgröße 12–20 Mitglieder. `AiPlayerbot.GuildMaxBotLimit=30` (Default 1000) aktiviert „leave large guild“. |
| **Neutrale Namen** | Die 400 Stock-Namen in `ai_playerbot_guild_names` sind in Repo und live identisch. Mindestens zu entfernen: „Iron Blizzard“, „Midnight Norrathians“, „Grammaton Collective“, „Illuminati“. Variante A: Konfigurationsschlüssel mit Ausschlussliste (hotfixfähig). Variante B: Migration (Hauptzug, Einzelfreigabe). Keine Texte aus dem Wiki kopieren. |
| **Leiter** | Leiter wird ganz organisch der Besitzer der Urkunde. Die Rangrechte nach der Gründung regelt `GuildCreateActions.cpp:253-268`. |
| **Beitritt nach Region und Stufe** | Optional für Zug 10: Angebot und Einladung nur bei \|ΔStufe\| ≤ 5 und gleicher Zone. Die Sichtdistanz und der regionale Quest-Hub der Roster-Bots erzeugen diese Nähe schon weitgehend. Fallback, falls das organisch zu langsam geht: ein deterministischer `RosterGuildPlanner`, einmal pro Admission und asynchron. Das ist eine Spielentscheidung und braucht eine Einzelfreigabe. **`CreateRandomGuilds` darf keinesfalls reaktiviert werden**, weil es synchron `SELECT account,guid FROM characters` scannt (`RandomPlayerbotFactory.cpp:1240`). |
| **Tick-Kosten** | Nach dem Fix fallen die 2 synchronen DB-Abfragen pro Kandidat weg, das ist ein Gewinn für ADR-0024. Neu kommen nur Schleifen mit O(≤ 9) im Speicher dazu. Die Gründung kostet einmalig `Guild::Create` mit asynchronen `PExecute`-Aufrufen. Wie oft der Trigger „random“ feuert, ist nicht gemessen (UNSICHER). |
| **Rollback** | Code: Hotfix zurücknehmen oder `RandomBotFormGuild=0`. Dann werden keine Urkunden mehr gekauft oder eingereicht, bestehende Gilden bleiben. Daten: Auflösen nur per `Guild::Disband` bzw. GM, nur mit Einzelfreigabe und nach einem Dump von `guild*` und `petition*`. Gildenzugehörigkeit ändert keine Roster-Mitgliedschaft, ADR-0010 ist nicht berührt. |
| **Chat** | Gildenchat ist bei `BotChat.Direct=0` (#478, live 0) stumm. Gilden sind dann nur im Gildenfenster sichtbar. Ob sich das ändert, entscheidet der Inhaber, umgesetzt wird es mit Mengenbegrenzung durch OB-15. |

Direkt nach dem Fix können bis zu 3 Bots sofort einreichen, mit Altlast-Fix kommen weitere dazu. Die Gilden tragen dann Stock-Namen der Urkunden, zum Beispiel „Vanguard of the Left“. Sollen bestehende Urkunden vorher aufgeräumt werden, ist das eine DB-Mutation mit Einzelfreigabe.

---

## 2. Quest-Abschluss: wo die Bots hängen

Datengrundlage:
- 21 kanonische, zeitlich getrennte `bot_events`-Segmente vom 24.09. bis 02.10. Teilmengen wurden per `comm` als vollständig enthalten geprüft und auf Segmentebene entfernt. Ein zeilenweises `sort -u` hätte 41.482 echte Ereignisse in derselben Sekunde gelöscht.
- Klassifikation aus dem World-Dump mit einem eigenen Tuple-Parser (6708 Quests mit je 129 Spalten).

### 2.1 Abschluss je Quest-Kategorie

Kategorien schließen sich gegenseitig aus. Rangfolge: Eskorte > Dungeon (Type 81 oder Dungeon-Zone) > Raid/PvP/Sonstige (Type 62/41/64/82) > Gruppe/Elite (Type 1 oder SuggestedPlayers > 1) > Elite-Ziel (Type 0) > Solo.

| Kategorie | Quests angenommen | Annahme-Paare (Bot + Quest) | Abgabe/Paar | Abwurf/Paar | Reisen zum Ziel |
|---|---|---|---|---|---|
| normal_solo | 712 | 8.564 | **0,476** | 0,367 | 42.976 |
| group_elite | 9 | 87 | **0,011** (nur 2499 Oakenscowl) | 0,736 | 5 |
| dungeon | 18 | 91 | **0,000** | 0,780 | 1 |
| escort | 4 | 5 | **0,000** | 1,000 | 0 |
| elite_objective | 2 | 9 | 0,000 (Heuristik UNSICHER, z. B. 8513) | 0,778 | 0 |
| raid_pvp_other | 6 | 82 | 0,390 (nur 50315 Gadgetzan Times) | 0,671 | – |

Quelle: `work/quest-join/quest_category_funnel.tsv` (sha256 `888b5098…14aa`), `quest_join.tsv` (`dd38736d…`).

### 2.2 Hängepunkte

| Nr. | Befund | Zahl | Ursache (Code) | Sicherheit |
|---|---|---|---|---|
| H1 | Schleife aus Annehmen und Abwerfen grauer Quests seit Hotfix 8.7/8.8 | 8.7-Segment (3,76 h): 2.195 graue Annahmen, 2.308 graue Abwürfe. Etwa 870 Annahmen/h, Abgaben pro Annahme 0,06 (8.3: 0,30). Beispiel Cointooth/750 mit 88 Annahmen, Zyklus 2–3 min | Abwurf nach XP-Graustufe (`DropQuestAction.cpp:53-72`, `QuestSearchPolicy.h:252-270`). `AcceptAllQuestsAction::ProcessQuest` filtert aber nur rote Quests (`AcceptQuestAction.cpp:36-40`) | hoch. Zuordnung Segment↔Version über Ordnernamen UNSICHER |
| H2 | Gruppen-, Dungeon- und Eskort-Quests werden angenommen, aber nie bearbeitet | 183 Annahme-Paare in group_elite + dungeon + escort, 1 Abgabe | Der Annahmepfad hat keinen Typfilter (`AcceptQuestAction.cpp:9-50`). Die Typfilter greifen erst bei der Reiseplanung (`TravelMgr.cpp:143, 150, 295-301, 307, 311-315`) und verlangen `can fight elite/boss`, also eine Gruppe (`MaintenanceValues.h:148/155`) | hoch |
| H3 | Abgabe-Schleife der wiederholbaren Quest 1463 „Earth Sapta“ | 26.–30.09.: 621 von 2.364 Abgabe-Events (26,3 %). Über alle Segmente 24.09.–02.10.: 629 für 1463, dazu 53 für 1462 | Pfad NONE + IsAutoComplete (`TalkToQuestGiverAction.cpp:53-57`). Mechanismus UNSICHER | hoch (Zahl) |
| H4 | Reiseschleifen zum Abgeber | 310 Bitter Rivals: 1.835 × TravelToTaker, 0 Abgaben. 5722: 362/0, Abgeber Maur Grimtotem steht **in RFC**. 1097: 337 | UNSICHER. `TravelMgr.cpp:149-154` sperrt die Abgabe von ELITE/DUNGEON in der **Overworld**, der Kommentar sagt „in instances“; geprüft wird `IsOverWorld(info.GetPosition())`. Bei 5722 liegt der Abgeber in RFC, ein Solo-Bot in der Oberwelt müsste also gesperrt sein. Dass trotzdem 362 TravelToTaker entstehen, deutet auf einen zweiten Pfad ohne diese Sperre hin (z. B. `ChooseTravelTargetAction`, UNSICHER). Bei 310/384/413 fehlt eventuell ein Kaufgegenstand (Prüfung durch OB-50) | mittel |
| H5 | Reiseschleifen zu Questzielen ohne Fortschritt | 789: 6.324 Reisen bei 109 Fortschritten. 794: 4.413/14. 41216: 1.528/10 | Ziel nicht erreichbar oder GO-Rotation (#405) | hoch (Zahl) |
| H6 | Fertig, aber nicht abgegeben (DB) | 580 Bot-Quest-Zeilen mit `status=1, rewarded=0` in 178 verschiedenen Quests, dazu 1.844 unfertige (186 Log-Bots, Dump 01.10. 03:06Z). Im Schnitt 13,0 aktive Quests je Bot (Maximum 18) | Vor allem Liefer- und Bericht-Quests mit Abgeber in einer anderen Zone oder Hauptstadt (310, 80300, 8792, 1097) | mittel |
| H7 | Eskort-, Erkundungs- und Event-Quests ohne Bot-Ziel | Erkundung/Event (SpecialFlags&2): 103 Annahmen, 7 Abgaben (26.–30.09.) | `EntryQuestRelationMapValue` kennt keine Areatrigger- und Eskort-Ziele (`QuestValues.cpp:32-105`). Bei Quests ohne ReqItem/ReqCreature ist `NeedQuestObjective` immer false (`:655-675`) | hoch |
| H8 | `HasProgress` stuft Quests mit `ObjectiveText` immer als „in Bearbeitung“ ein | 295 von 6708 Quests betroffen, 20 der angenommenen | `DropQuestAction.cpp:196` | mittel |
| H9 | Quest-Teilen von Bot zu Bot ist wirkungslos | – | Das Paket an Bot-Mitglieder geht ohne Divider raus (`ShareQuestAction.cpp:170-180`), `AcceptQuestShareAction` lehnt ab (`AcceptQuestAction.cpp:117-165`) | mittel |
| H10 | Gründe für `QuestDropped` sind nicht unterscheidbar | 943 Abwürfe (26.–30.09.) | `PlayerbotAI::DropQuest` loggt keinen Grund. `RetireOneSafeStaleQuest` und das Chat-Drop loggen gar kein Event | hoch |

Phasenvergleich (Abgaben pro Annahme-Paar, ohne wiederholbare Quests): vor dem 26.09. 0,46 · P0 0,36 · P1 (Zug 6) 0,48 · P2 (Zug 7) 0,52 · P3 (Zug 8.x) 0,42. Annahme bis Abgabe im Median 36–61 min, p90 in Zug 7/8 jedoch 49–72 h. Vergleiche nur innerhalb derselben Roster-Phase und ab v24 (XMP-Wechsel am 02.10.).

Hashes der Eingaben:
- `quest_funnel.tsv`: `1433d7ae4fa0…9b94`
- Segmente, Beispiele: 2026-09-27 `992896d1…c457`, train8-7 `c4012fbd…14e4c`, train8-8 `bfe82381…35db`. Diese Datei wächst noch, der Hash gilt für den Lesezeitpunkt.
- Vollständig in `work/quest-logs/input_sha256.txt`

---

## 3. Entwurf Gruppen-Quests (Gruppe, Elite, Eskorte)

### 3.1 Ausgangslage

- **Ad-hoc-Questgruppen aus #365 Schritt 2 sind seit Zug 7 live.** Konfiguration: `BotGroups.Enabled=1`, `MaxBots=5`, `LevelWindow=3`, Radius 50 yd, Scan 10 s, Paar-Cooldown 600 s. Code in `AiFactory.cpp:1170-1173` und `AdhocGroupAction.cpp`.
- **Messung 26.09. bis 30.09.:**
  - 926 Beitritte zu Bot-Gruppen, 102 Bots, 88 Leiter. 64 % der Gruppen hatten 2 Mitglieder.
  - Mitgliedsdauer im Median 22 min (p90 89 min).
  - Bots verbringen 6,9 % ihrer Zeit in Gruppen.
  - Tode pro Bot-Stunde: in Gruppen 0,36, solo 0,61. Das ist eine reine Korrelation, nicht bereinigt.
- **Henne-Ei-Problem:** Gruppen bilden sich nur um das *aktuelle* Reiseziel (`AdhocGroupAction.cpp:65-83`). Solo-Bots wählen Elite- und Dungeon-Ziele nie als Reiseziel. Deshalb entstehen für diese Ziele nie Gruppen.
- **Konkurrierender Austrittspfad:** Bei `RandomBotGroupNearby=0` gibt `LeaveFarAwayAction::isUseful` sofort **true** zurück (`LeaveGroupAction.cpp:123`). Die Bedingungen: kein aktiver Spieler-Master, ein Gruppenmaster existiert, alle Mitglieder sind auf derselben Map. Ausgelöst wird das über „seldom“ und die Dead-Engine (`GroupStrategy.cpp:17-23, 32-38`). Ad-hoc-Gruppen sind davon nicht ausgenommen.
  - Laut bot-groups.md enden Ad-hoc-Gruppen mit `objective_done` 6× und `idle` 104× (Zug 7.1c).
  - Für die Austrittsgründe sind keine `[BotGroup]`-Logs auf Y: gesichert, die Verteilung bleibt UNSICHER.
- **Wipe-Logik fehlt völlig.** Ohne Spieler-Master geben tote Bots ihren Geist sofort frei (`ReleaseSpiritAction.h:103-113`). Ab 27.09. werden ≥ 94 % am Geistheiler wiederbelebt (28.09.: 2.510 von 2.630; 26.09.: 3.414 von 3.843 = 89 %). Die meisten Tode passieren nicht am Questziel, sondern auf der Abgabe-Route, beim Angeln oder ohne Reiseziel („kill“ nur 132 von 12.677).

### 3.2 Zusammenfinden

1. **Bedarf statt Henne-Ei.** `AdhocGroupAction::CurrentObjective` liefert auch ein *gesuchtes* Ziel: eine Elite- oder Gruppenquest im Log, deren Ziel nur wegen `can fight elite` inaktiv ist. Radius, LevelWindow und Paar-Cooldown bleiben wie bisher.
2. **Matchmaking-Raster (Zug 10, falls nötig).** Alle 30 s ein Bucket-Index `(team, map, zone, questId, objective)` in O(n) aus Snapshots, die jeder Bot in seinem eigenen Map-Tick schreibt (POD unter kurzem Mutex). Ergebnis ist nur eine *Absicht* im Eingangskorb des Leiters. Die Einladung führt der Leiter in seinem eigenen Map-Update aus, wenn beide auf derselben Map sind. Es gibt keine Gruppenoperationen aus dem World-Thread (ADR-0024 Inv. 6, #351).
3. **Obergrenzen:**
   - Gruppengröße 3–5 für Elite/Gruppe, 2–3 für Eskorte. Höchstens 30 Ad-hoc-Gruppen.
   - Höchstens 3 Einladungen/s serverweit und höchstens 1 je Bot pro 30 s.
   - Stufenfenster ≤ 3. Elite nur, wenn die niedrigste Stufe in der Gruppe ≥ Questlevel − 1 ist.
4. **Wartezeit auf eine Gruppe:** höchstens 15 min, danach wird das Ziel über den vorhandenen QuestWorkTimeouts-Pfad (#405) zurückgestellt.

### 3.3 Gemeinsam erledigen

- **Kill-Credit** verteilt der Core (Loot/XP-Distanz, `MaxGroupXPDistance=74`). Den Bedarf aggregiert der Bot-Code bereits über `group or::{following party, need quest objective}` (`ChooseTravelTargetAction.cpp:406-427, 1906-1975`). Loot muss laut `docs/design/bot-groups.md:200-230` nicht geändert werden.
- **`can fight elite`** verlangt eine Gruppe. Alle Mitglieder brauchen `can fight equal` und `following party`, und niemand darf `should sell` haben. **`can fight boss`** verlangt zusätzlich mehr als 3 Mitglieder.
- **`following party`** ist wahr für den Leiter oder bei Strategie `follow`/`wander` (`GroupValues.cpp:28-38`). In Ad-hoc-Gruppen ist für Mitglieder `wander` aktiv, weil der Master ein Bot ist. Ob `ResetStrategies` beim Beitritt das Reiseziel zurücksetzt, ist UNSICHER.
- **Quest-Teilen von Bot zu Bot reparieren (H9).** Für Bot-Mitglieder wird der Core-Pfad `HandlePushQuestToParty` genutzt, der den Divider setzt. Die bestehende Drossel bleibt (freeSlots < 15, 1/6).

### 3.4 Trennen

- **Ein einziger Austrittspfad.** `LeaveFarAwayAction::isUseful` gibt für registrierte Ad-hoc-Mitglieder false zurück. Austritt nur über `DecideLeave`, jeweils mit `[BotGroup] reason=`.
- **Gründe:** `quest_turned_in`, `objective_done`, `instance`, `out_of_range` (2×Radius für 60 s), `level_window`, `idle` (10 min), neu `max_age` (60 min), `wipe`, `deaths`, `repop`.
- **Registry:** `Forget` beim letzten Austritt bzw. Disband aufrufen, nicht erst bei ≤ 2 Mitgliedern. Repop und RemoveMember ebenfalls loggen.

### 3.5 Tod und Wipe

- **Wipe** heißt: Alle lebenden Mitglieder sterben innerhalb von 30 s. Geprüft wird beim Tod jedes Bots, mit Aufwand O(Gruppengröße).
- **Einzeltod in der Gruppe:** Leichenlauf statt Geistheiler, solange keine Wiederbelebungskrankheit besteht und die Leiche ≤ 150 yd vom Leiter entfernt liegt. Die Gruppe wartet höchstens 90 s, `idle` pausiert in dieser Zeit. Das ist eine **Spielentscheidung des Inhabers** (Haltbarkeit, Wiederbelebungskrankheit).
- **Nach einem Wipe:** Regroup an der Leiche, höchstens 120 s Wartefenster. Nach 2 Wipes am selben Ziel innerhalb von 30 min: Disband mit `reason=wipe`, Ziel für die ganze Gruppe 60 min sperren (DestinationDeathPolicy), Paar-Cooldowns setzen.
- **Mitglied mit Todesserie:** Wer ≥ 3 Tode hat oder im Cautious-Modus ist (#422), tritt mit `reason=deaths` aus. Repop bleibt der harte Ausweg.
- **Kein `follow` im Tot-Zustand** für Ad-hoc-Mitglieder (Dead-Engine `AiFactory.cpp:1271`). Das vermeidet Folgeketten über einen hängenden Leiter (#324).

### 3.6 Eskorte

- **Core-Verhalten** (`ScriptedEscortAI.cpp`):
  - Geprüft wird alle 5 s, nur außerhalb des Kampfs und nur ohne QUESTGIVER-Flag (`:302-322`).
  - In einer Gruppe scheitert die Eskorte erst, wenn **alle** Mitglieder tot sind, weiter als 100 yd entfernt sind oder die Quest nicht INCOMPLETE haben (`:214-238`). Ohne Gruppe zählt nur der Spieler selbst.
  - Stirbt der NPC, lässt `GroupEventFailHappens` die Quest für alle Mitglieder unabhängig von der Distanz scheitern (`:168-177`, `Player.cpp:16132-16147`).
  - Credit geht über `GroupEventHappens` an alle Mitglieder in XP-Distanz.
- **Bot-Seite:**
  - mod-playerbots kennt keine Eskorten (0 Treffer für `escort`).
  - Bots starten Eskorten unbeabsichtigt, weil der Annahme-Opcode `OnQuestAccept` auslöst. Belegt ist das mit 435 Escorting Erland: Annahme und Abwurf 2:12 min später, Grund UNSICHER.
  - Bei PARTY_ACCEPT bestätigen Mitglieder automatisch über „confirm quest“.
  - Fehlgeschlagene Quests verwirft `CleanQuestLog` gelegentlich über den Trigger „random“ und nicht bei aktivem Spieler-Master. Das passiert *nicht* sofort.
  - Dass Eskorten „regelmäßig scheitern“, ist nicht gemessen (UNSICHER).
- **Inventar:** 24 Eskorten in Stufe 1–30 (Heuristik, Override-Liste nötig). Es gibt kein Eskort-Bit, Type 84 kommt nicht vor.
- **Kurzfristig:** Eskorten für Bots ohne Gruppe sperren (siehe S3).
- **Zug 10: Strategie `escort`.**
  - Erkennung über `Player::GetEscortingGuid()` des Leiters.
  - Die Strategie hat Vorrang vor allem anderen. Mitglieder folgen dem NPC in ≤ 15–20 yd und greifen seine Angreifer an. Vorlage dafür ist `DriveEscortCreature` in mod-dungeon-clear (`DcEngageActions.cpp:1236`). Heiler nehmen den NPC als Ziel.
  - Start mit einer Whitelist aus 5–10 geprüften Eskorten (z. B. 435, 309, 863, 898).
  - Bei FAILED: höchstens 2 Neuversuche nach dem Respawn, danach Sperre für 24 h. Diagnosezeile `[Escort] start|fail reason=…|done`.
  - Aufwand etwa 5–7 Personentage.

### 3.7 Tick-Kosten

- **Ad-hoc-Scan heute:** 180 Bots / 10 s, k̄ ≈ 5–20 Nachbarn. Das ergibt etwa 0,3–1 ms CPU pro Sekunde, also < 0,1 ms pro Tick (< 0,3 % von p50 = 40 ms). Im Worst Case (90 Bots in einem Startgebiet) etwa 2,4 ms/s. Alles geschätzt, ohne Profiler (UNSICHER).
- **Beitritt/Austritt:** `ResetStrategies`, Gear und Raids kosten geschätzt 1–5 ms, bei etwa 22–32 Beitritten/h vernachlässigbar.
- **Budget** (ADR-0031 D1): max ≤ 3000 ms, Ziel p99 ≤ 1000 ms pro Tag. Strenger ist das Welle-2-Kriterium von OB-30: Ticks/min ≥ 900 und p99 ≤ 200 ms. v23 lag bei 978–1051 Ticks/min und p99 114–137 ms. Die gemessenen max-Ausreißer bis 21 s hängen an Starts und Stalls (#416), nicht an Gruppen.
- Die Tages-Mediane von p99 lagen am 28./29.09. (Zug 7) bei 212–227 ms, also über 200 ms; erst v23 lag darunter. Gruppen-Features werden deshalb nur ab v24 und im gleichen Roster-Fenster gemessen. Eine Verschlechterung von p99 um mehr als 10 % ist ein Rollback-Grund.
- **Gefährlich sind nur unbegrenzte Fehlerpfade:** Einladeschleifen und Reset-Stürme. Abnahme deshalb mit „kein Paar öfter als 6×/h“.

### 3.8 Abgrenzung zu #324 und #365

- Das Vorhaben ist eine **Erweiterung von #365 Schritt 2**, kein Parallelsystem. Ad-hoc-Gruppen bleiben auf Roster-Bots beschränkt, ohne Spieler und ohne Instanzen. Das Questlog wird nicht verändert. Schritt 3 von #365 (Gruppen-Questlog, Journal in `cv_bots`) bleibt dort.
- `RandomBotGroupNearby` bleibt 0, das upstream-Feature `invite nearby` bleibt aus. Das kanonische compose-Overlay steht auf 1, das Profil `funserver-test:16` auf 0.
- **Widerspruch, der gemeldet werden muss:** ADR-0031:127-129 sagt „Gruppen zwischen Bots bleiben aus bis #324“. Live sind aber seit Zug 7 Ad-hoc-Gruppen aktiv, und #324 ist offen. OB-00 entscheidet, ob #324 neu zugeschnitten oder ADR-0031 nachgezogen wird.

---

## 4. Minimaler Weg zu Dungeon-Quests (RFC, DM, WC) – Bezug #343

### 4.1 Ist-Stand

- **Instanzzugang:** 5er-Instanzen haben keinen Gruppenzwang (`MapManager.cpp:211-249`). Die Mindeststufe prüft `MiscHandler.cpp:873-935`: RFC 8, DM 10, WC 10.
- **Portale:** Bots können Instanzportale schon heute benutzen. Der Travel-Graph legt areaTrigger-Kanten an, `AreaTriggerAction` leitet `CMSG_AREATRIGGER` weiter, und der Leiter wartet vor einem Dungeon-Ziel (`MoveToTravelTargetAction.cpp:235`).
- **LFG:** Im Vanilla-Build gibt es eine LFG-Warteschlange (Meeting Stones, `sLFGMgr`, `LfgActions.cpp:92-181`). Im Roster-Modus läuft `CheckLfgQueue` jedoch nie, weil der Roster-Zweig in `RandomPlayerbotMgr.cpp:1006` mit `return` endet. `LfgDungeons` bleibt deshalb leer, und `LfgJoinAction::isUseful` liefert immer false (`:1200-1202`). `RandomBotJoinLfg=1` ist für #343 also wirkungslos.
- **mod-playerbots** hat Dungeon-Strategien nur für Raids (MC, BWL, Onyxia, Karazhan, Naxx).
- **mod-dungeon-clear** ist gebaut und statisch gelinkt. Es bringt Routen für DM (9), WC (9) und RFC (3) sowie Event- und Eskort-Treiber mit, etwa für den Disciple of Naralex. Starten lässt es sich nur, wenn ein echter Spieler in der Gruppe ist oder ein GM es startet (`DungeonClearChatActions.cpp:62-83`). Es gibt keinen Enable-Schalter.
- **mod-solo-dungeon** lässt KI-Bots, die in einem Dungeon sterben, immer lebend am Eingang innen wiederauferstehen (`mod_solo_dungeon.cpp:31-65`). Das ist der vorhandene Schutz vor verlorenen Bots nach einem Wipe.
- **LFT-Bot-Fill** ist live aus und braucht ohnehin einen wartenden echten Spieler.
- **mmaps für 36/43/389** sind in `C:\TW\ComTW\data` vorhanden (25/6/4 Tiles). Ob der Live-Container genau dieses Verzeichnis einbindet, ist UNSICHER und muss OB-30 prüfen.

### 4.2 Eingänge und Quests

| Dungeon | Eingang (Trigger) | Mindeststufe | Ausgang | Quests (Auswahl) | Annahme-Paare im Log |
|---|---|---|---|---|---|
| RFC (389), Horde | 2230 Map 1 (1818.4, −4427.3) | 8 | 2226 | 5723, 5725, 5728, 5761, 5722→**5724 (Abgeber/Geber innen)** | RFC-Paket ≈ 38 |
| WC (43) | 228 Map 1 (−753.6, −2212.8) | 10 | 226 | 914, 962/60125, 1486, 1487, 41363, 41367. 959 liegt im **Außenbereich** | WC/Brachland ≈ 31 |
| DM (36), Allianz | 78 Map 0 (−11208.5, 1685.3) | 10 | 119 (hinten 121) | 166, 214, 2040, 40396, 40478, 41392. 167/168 liegen in der **Oberwelt** (Jangolode) | gering |

Type 81 heißt nicht automatisch Instanz. 167, 168 und 959 lassen sich als „Gruppe über Land“ erledigen. Mutanus (3654) und Sneed (643) haben keinen Spawn und werden durch Events erzeugt.

### 4.3 Minimaler Pfad (RFC zuerst für Horde, DM für Allianz)

| Schritt | Inhalt | Aufwand |
|---|---|---|
| 0 | Voraussetzung #324 bzw. erweiterte Ad-hoc-Gruppen: 5 Roster-Bots (Tank, Heiler, 3 Schaden) im passenden Stufenband (RFC 13–16, WC 15–21, DM 16–22). Rollen aus dem Roster (#308/#341) | 3–5 PT |
| 1 | Typ-81-Quests für Gruppen mit `can fight boss` freigeben. Pro Dungeon eine gepflegte Questliste | 1–2 PT |
| 2 | Anreise zum Entrance-Trigger. Der Leiter wartet, Eintritt über das Relay (beides vorhanden) | 1–2 PT |
| 3 | Serverseitiger Starter für mod-dungeon-clear: „Bot-Gruppe in Dungeon und Leiter ist Tank-Bot → dc on“. Das ist eine Autorisierungs-Ausnahme und eine **Inhaberentscheidung**. Ob Quest-Items zuverlässig gelootet werden, ist UNSICHER | 3–4 PT |
| 4 | Watchdog: höchstens 90 min und höchstens 2 Wipes, danach Teleport zum Ausgang, Quests behalten, Gruppe auflösen | 2 PT |
| 5 | Ausgang (erst `dc off`, weil das Relay während des Laufs unterdrückt ist) und Abgabe über die normale Questreise. Sonderfall: 5722/5724 innerhalb von RFC | 1–2 PT |
| 6 | Diagnosezeile `[Dungeon] enter\|mode\|pull\|wipe\|recover\|leave reason=…` | – |

- **Summe:** etwa 12–17 PT, davon 3–5 PT für #324.
- **Abnahme nach #343:** 1 Lauf bis zum Endboss, 1 sauberer Wipe-Recover, 0 verlorene Bots. Für den Dungeon-Reset durch den Bot-Leiter gilt #453 (Kandidat für Zug 9).
- **Achtung, Vertragsabweichung:** Der #343-Vertrag verlangt „Spieler + 4 Roster-Bots“. Der hier skizzierte Pfad mit reinen Bot-Gruppen ist eine **Erweiterung** von #343, keine Erfüllung. Entweder bekommt #343 einen neuen Vertrag (Inhaber/OB-00), oder WS10-DUNGEON-QUEST-01 läuft als eigenes Issue mit `Refs #343`. Der Spieler-Pfad (mod-dungeon-clear mit echtem Spieler) ist heute schon möglich und sollte zuerst abgenommen werden.
- **Tick-Kosten:** Eine Instanz-Map pro Gruppe, bearbeitet in 4 Instanz-Threads. Die Bots entlasten dabei Map 1, den Engpass bei den langsamen Updates (51.390 Zeilen, bis 212 ms). Leere Instanzen bleiben 30 min geladen. Zum Start höchstens 2 Bot-Dungeongruppen gleichzeitig.
- **Ad-hoc-Gruppen** sind laut Inhabervertrag in Instanzen verboten. Für Dungeons braucht es deshalb einen eigenen Gruppentyp, den der Inhaber entscheidet.

---

## 5. Priorisierte Schritte für Zug 9 und Zug 10

Release-Regel Ä15: DB- und Client-Änderungen nur in Hauptzügen (9, 10). Hotfix-Züge (8.x bzw. 9.x) enthalten nur Code und Konfiguration, ohne DB. Hotfixes laufen als PR gegen `release/8.x` plus Zwilling auf main. Neue Konfigurationsschlüssel bekommen einen neutralen Default in `*.dist.in` und werden im Profil `funserver-test` eingeschaltet (ADR-0024 Inv. 4).

| # | Schritt | Zug | Messgröße (ADR-0031) | Risiko | Aufwand | Zuständig |
|---|---|---|---|---|---|---|
| S1 | Gilden: Unterschriften im Speicher zählen statt per SQL, SQL im World-Thread entfernen | Hotfix 8.x | Gilden > 0 innerhalb 72 h (OB-40 `COUNT(*) guild`) ODER `[Guild] turnin_blocked reason=not_in_capital\|traveling` belegt den Restblocker. Tick unverändert oder besser | niedrig. Gründungen sofort mit Stock-Namen | 1–2 PT | OB-10 |
| S2 | Core: `IsComplete >=`, `LoadPetitions` begrenzen (ohne DB-Mutation) | Hotfix 8.x | 4 blockierte Petitionen werden abgabefähig | niedrig. Core-Änderung mit Upstream-Drift | 1 PT | OB-10 |
| S3 | Annahmefilter für Roster-Bots ohne Spieler-Master: graue Quests sowie ohne Gruppe ELITE/DUNGEON/RAID/PvP, SuggestedPlayers > 1 und Eskorten (Liste) ablehnen. Dieselbe Bedingung wie `TravelMgr.cpp:143` | Hotfix 8.x | Annahmen/h, Abwürfe/h, Abgaben pro Annahme ≥ Stand 8.3 (0,30). Schleifen D3 | mittel. Folgequests fehlen, deshalb Ketten zunächst nur loggen | 2 PT | OB-10 |
| S4 | Diagnose: `QuestDropped` mit Grund, Abgabe-Event erst nach `RewardQuest`, fehlende Annahmewege loggen, `[Guild]`-Trace mit Begründung von `isUseful` (Rate-Limit 300 s) | Hotfix 8.x | Zuordnung der Abwürfe ≥ 95 % | niedrig. CSV-Spaltenzahl bleibt gleich | 1–2 PT | OB-10 |
| S5 | Ein einziger Austrittspfad: `LeaveFarAway` überspringt Ad-hoc-Mitglieder, Gründe werden geloggt. Diagnostics für 48 h, Logs auf Y: sichern | Hotfix 8.x | `objective_done`+`turned_in` ≥ 60 % der Austritte. Median-Dauer ≥ 10 min | niedrig | 1 PT | OB-10, OB-30 (Logs) |
| S6 | Earth-Sapta-Schleife: Cooldown oder Sperre für wiederholbare Autocomplete-Quests. `HasProgress`-Fehler `DropQuestAction.cpp:196` | Hotfix 8.x | Anteil von 1463 an den Abgaben < 2 % | niedrig | 1 PT | OB-10 |
| S7 | Konfigurations-Evidenz: gerenderte `aiplayerbot.conf` und `mangosd.conf` pro Deploy mit Hash und geschwärzten Secrets ablegen. Snapshot von `bot_events` 8.8 einfrieren | ab sofort | D4 Evidenz vollständig | keins | 0,5 PT | OB-30 |
| S8 | Gildenanzahl und -größe (Obergrenze pro Fraktion, `GuildMaxBotLimit`), Ausschlussliste der Namen per Konfiguration | Hotfix 9.x (Code und Config, Default aus, Profil an); Namensmigration nur als S11 im Hauptzug | Gilden je Fraktion 4–6, Mitglieder 12–20 | mittel (Spielentscheidung) | 2 PT | OB-10, Inhaber |
| S9 | Elite-Gruppen ohne Henne-Ei: gesuchtes Ziel in `AdhocGroupAction`, Quest-Teilen von Bot zu Bot | 9 | Abgabe pro Paar group_elite > 0,2 (Basis 0,011). Tode/Bot-h in Gruppe ≤ solo. Tick p99 ±10 % | mittel (Wipes) | 4–5 PT | OB-10 |
| S10 | Erkundungsziele (`areatrigger_involvedrelation`) beim Laden. Abgeber in der Instanz (5722) klären bzw. reparieren | 9 | Abgaben bei SpecialFlags&2 > 7/103. TravelToTaker für 5722 → 0 | mittel | 3 PT | OB-10, OB-50 (Klassifikation) |
| S11 | Neue Namensliste bzw. Bereinigung der Altlast-Petitionen per Migration (nur falls gewünscht) | 9 (Hauptzug) | – | mittel (DB, Einzelfreigabe) | 1 PT | OB-40 |
| S12 | Wipe- und Tod-Regeln für Gruppen | 10 | Wipes pro Ziel ≤ 2. 0 verlorene Bots | mittel | 3 PT | OB-10 |
| S13 | Eskort-Strategie mit Whitelist | 10 | Eskort-Abgaben > 0. Keine Schleifen aus Abbruch und Wiederannahme | mittel–hoch | 5–7 PT | OB-10 |
| S14 | Minimaler Dungeon-Pfad RFC/DM/WC (#343, #453) | 10 | 1 Endboss-Lauf, 1 Wipe-Recover, 0 verlorene Bots. Abgaben Typ 81 > 0 | hoch | 12–17 PT | OB-10, OB-30 (mmaps) |

Reihenfolge: S7 → S1+S2 → S3+S4 → S5+S6 im nächsten Hotfix. Danach S8–S11 in Zug 9 und S12–S14 in Zug 10.

**Messgröße „Gruppen-Quests abgegeben pro Tag“:** Abnahme für S3, S6, S9, S10, S13 und S14 erfolgt zusätzlich über `character_queststatus.rewarded`: Zuwachs je Tag und Bot-Stunde für die Quest-ID-Listen der Kategorien aus `work/quest-join/quest_join.tsv` (group_elite, dungeon, escort). Die Zählung macht OB-40 leicht, ohne Joins, in einer Wegwerf-DB aus Dumps. ADR-0031 kennt diese Messgröße bisher nicht; OB-00 trägt sie per Doku-PR nach. Event-Quoten aus `bot_events` gelten nur als Frühindikator.

**Schleifen-Definition:** ADR-0031 D3 definiert eine Schleife nur über Tode bzw. „no destination“. Die Schleifen H1, H3, H4 und H5 brauchen eine eigene Messdefinition, als Vorschlag: „gleiches Paar Bot+Quest mehr als 3× angenommen pro 6 h“, „mehr als 50 TravelToTaker ohne Abgabe pro Bot+Quest und Tag“, „wiederholbare Quest mehr als 5 Abgaben pro Bot und Tag“. Aufnahme in ADR-0031 nur per Doku-PR und Entscheidung von OB-00.

---

## 6. Issue-Vorschläge im Repo-Format (nicht angelegt)

Gedacht für eine neue Datei `docs/issues/60-bot-social.md`. Hinweis: Der Importer vergibt für neue Dateinamen das origin-Label `refactor` (`import-issues.sh:169-173`). Angelegt wird nur nach Trockenlauf (Aufruf ohne Argumente) mit `--apply --only <ID>`.

Vor dem Anlegen offene und geschlossene Issues durchsuchen (Overlay §8). Bekannte Überschneidungen: H5 → #405 (GO-Rotation), Tode auf der Abgabe-Route → #422/#472, Credit-Fixes → #441, Leiter-/Gruppen-Vertrag → #324/#365. Dort passende Teile als Kommentar ergänzen statt ein neues Issue anzulegen. Titel ≤ 70 Zeichen inklusive Präfix (`docs/issues/README.md:29`).

```yaml
---
id: WS10-GUILD-PETITION-KEY-01
title: "WS10-GUILD-PETITION-KEY-01: Count petition signatures in memory"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; evidence/ws-10/cli485-bot-social/work/gilden/"
superseded_by: none
body: |
  Vertrag: PetitionSignsValue (GuildValues.cpp:1276) und PetitionOfferAction
  (GuildCreateActions.cpp:151,160-163) zählen Unterschriften über sGuildMgr statt per SQL
  mit Item-GUID. Core: Petition::IsComplete >= statt ==, LoadPetitions begrenzt
  (überzählige Zeilen nur loggen, keine DB-Mutation). Contract-Test: kein petition_sign
  in mod-playerbots/strategy. Hotfix ohne DB.
  Abnahme: guild > 0 innerhalb 48 h (OB-40-Zählung); Tick p99 nicht schlechter als v24.
  Owner chat: OB-10. Refs #485, #241.
---
id: WS10-QUEST-ACCEPT-FILTER-01
title: "WS10-QUEST-ACCEPT-FILTER-01: Skip grey/group quests for solo bots"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; work/quest-logs/segments.tsv, work/quest-join/quest_category_funnel.tsv"
superseded_by: none
body: |
  Vertrag: AcceptAllQuestsAction::ProcessQuest (AcceptQuestAction.cpp:36-40) lehnt für
  Roster-Bots ohne Spieler-Master graue Quests ab (gleiche Ausnahmen wie DropGrey) und
  ohne 'can fight boss/elite' Type 1/81/62/41, SuggestedPlayers>1, Eskort-Liste.
  Ketten-Vorquests zuerst nur loggen ([QuestAccept] skip=…).
  Abnahme: Abgaben/Annahme >= 0,30 im gleichen Roster-Fenster; Grau-Zyklen pro Paar <= 1/h.
  Owner chat: OB-10. Refs #485.
---
id: WS10-QUEST-DIAG-01
title: "WS10-QUEST-DIAG-01: Log drop reasons and real turn-ins"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485"
superseded_by: none
body: |
  Vertrag: DropQuest(reason) für grey|red|log_pressure|failed|failed_timer|guild_order|
  chat|retire; TalkToQuestGiver-Event erst nach RewardQuest, sonst QuestTurnInFailed;
  ConfirmQuest/Share/Item-Start loggen. CSV-Spaltenzahl unverändert. [Guild]-Trace mit
  isUseful-Grund (Rate-Limit 300 s). Abnahme: >= 95 % Drops mit Grund. Owner chat: OB-10. Refs #485.
---
id: WS10-ADHOC-LEAVE-01
title: "WS10-ADHOC-LEAVE-01: Single leave path for ad-hoc quest groups"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; LeaveGroupAction.cpp:123"
superseded_by: none
body: |
  Vertrag: LeaveFarAwayAction::isUseful = false für registrierte Ad-hoc-Mitglieder;
  alle Austritte [BotGroup] reason=…; Forget beim letzten Austritt; Repop geloggt.
  Diagnostics 48 h, Logs nach Y:. Abnahme: objective_done+turned_in >= 60 % der Austritte.
  Owner chat: OB-10. Refs #485, #365, #324.
---
id: WS10-QUEST-LOOPS-01
title: "WS10-QUEST-LOOPS-01: Stop Earth Sapta turn-in and HasProgress loops"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485; work/quest-logs/qe_sorted.tsv"
superseded_by: none
body: |
  Vertrag: Cooldown/Sperre für wiederholbare Autocomplete-Quests (1462/1463) bei
  Roster-Bots; DropQuestAction.cpp:196 (ObjectiveText => Fortschritt) korrigieren.
  Abnahme: 1463-Anteil an Abgaben < 2 %. Owner chat: OB-10. Refs #485.
---
id: WS10-GUILD-SHAPE-01
title: "WS10-GUILD-SHAPE-01: Cap bot guild count, size and names"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485"
superseded_by: none
body: |
  Vertrag (nach Inhaberentscheidung): Obergrenze Bot-Gilden+Urkunden je Fraktion
  < RandomBotGuildCount/2; GuildMaxBotLimit 30; Namens-Ausschlussliste per Config
  (Migration nur in Hauptzug, Einzelfreigabe). Optional |ΔStufe|<=5 bei Angebot/Einladung.
  Abnahme: 4–6 Gilden je Fraktion, 12–20 Mitglieder, 0 verlorene Bots. Owner chat: OB-10. Refs #485.
---
id: WS10-GROUPQUEST-ELITE-01
title: "WS10-GROUPQUEST-ELITE-01: Group bots for wanted elite objectives"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485; AdhocGroupAction.cpp:65-83"
superseded_by: none
body: |
  Vertrag: CurrentObjective liefert auch gesuchte Elite-/Gruppenziele; Bot-zu-Bot-
  Questteilen über HandlePushQuestToParty; Wartezeit <= 15 min. Abnahme: Abgabe/Paar
  group_elite > 0,2; Tode/Bot-h in Gruppe <= solo; Tick p99 ±10 %; kein Paar > 6 Einladungen/h.
  Owner chat: OB-10. Refs #485, #365.
---
id: WS10-ESCORT-01
title: "WS10-ESCORT-01: Add whitelisted escort strategy for bot groups"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485; work/escort-dungeon/escort_quest_ids.txt"
superseded_by: none
body: |
  Vertrag: Strategie 'escort' (GetEscortingGuid), Follow <= 20 yd, NPC-Angreifer angreifen,
  Whitelist 5–10 Quests, max. 2 Retries, [Escort]-Diagnose. Abnahme: Eskort-Abgaben > 0,
  keine Abbruch-/Wiederannahme-Schleifen. Owner chat: OB-10. Refs #485.
---
id: WS10-DUNGEON-QUEST-01
title: "WS10-DUNGEON-QUEST-01: Minimal bot dungeon path for RFC, DM, WC"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485; #343"
superseded_by: none
body: |
  Vertrag: 5er-Rostergruppe, Typ-81-Freigabe mit 'can fight boss', Anreise Entrance-Trigger,
  serverseitiger dungeon-clear-Starter (Inhaberentscheidung), Watchdog 90 min/2 Wipes,
  Ausgang+Abgabe, [Dungeon]-Diagnose, max. 2 Gruppen gleichzeitig.
  Abnahme: 1 Endboss-Lauf, 1 Wipe-Recover, 0 verlorene Bots. Owner chat: OB-10. Refs #485, #343, #453.
---
id: WS10-QUEST-EXPLORE-01
title: "WS10-QUEST-EXPLORE-01: Give bots areatrigger objectives"
workstream: WS-10
priority: p2
existing_ot: none
source: "#485; QuestValues.cpp:32-105,655-675"
superseded_by: none
body: |
  Vertrag: EntryQuestRelationMapValue lädt areatrigger_involvedrelation beim Laden,
  NeedQuestObjective berücksichtigt Erkundungsziele; Abgeber in Instanz (5722)
  nicht als Solo-Reiseziel. Abnahme: rewarded-Zuwachs SpecialFlags&2 > Basis 7/103;
  TravelToTaker 5722 → 0/Tag. Owner chat: OB-10. Refs #485.
---
id: WS40-CONFIG-EVIDENCE-01
title: "WS40-CONFIG-EVIDENCE-01: Store rendered configs per deploy"
workstream: WS-40
priority: p1
existing_ot: none
source: "#485; work/live-config/README.txt"
superseded_by: none
body: |
  Vertrag: pro Deploy gerenderte aiplayerbot.conf + mangosd.conf (Secrets geschwärzt)
  mit sha256 unter evidence/ws-40/ob30-release-train-<zug>/config/; bot_events-Snapshot
  8.8 einfrieren. Abnahme: D4 vollständig für v25+. Owner chat: OB-30. Refs #485.
---
```

---

## 7. Risiken und offene Fragen

**Risiken**
- **ADR-0031-Veto:** Kein Schritt darf einen Bot gefährden oder den World-Thread blockieren. Das betrifft vor allem S12–S14: Instanzen, Leichenlauf, Wipes. mod-solo-dungeon und Repop sind der Schutz.
- **Sofort-Gründungen nach S1/S2:** Es entstehen Gilden mit Stock-Namen und ohne Obergrenze, solange S8 fehlt. Bei `AllowTwoSide.Interaction.Guild=1` (Vorlagenwert, live nicht geprüft) könnten Gilden mit beiden Fraktionen entstehen (`PetitionsHandler.cpp:312`).
- **S3:** Kann gewollte Kettenquests unterdrücken.
- **Gruppen-Wipes:** Gruppen ohne Heiler sterben. Deshalb Boss- und Dungeon-Inhalte erst ab 4 Mitgliedern.
- **`ResetStrategies` beim Beitritt** setzt möglicherweise das Reiseziel zurück (UNSICHER).
- **#478:** Erst `BotChat.Direct=1` macht Gildenleben im Chat sichtbar. Damit werden aber alle Broadcast-Quellen auf einmal hörbar (Spam).
- **Kapazität von OB-10:** #484 läuft parallel. Die Overlay-Regel „ein Issue in Arbeit“ wird verletzt, und es gibt gemeinsame Merge-Anker (`tests.cmake`, Index in `docs/README.md`). OB-00 legt die Reihenfolge fest.

**Offene Fragen**
1. Wie viele Gilden und Petitionen gibt es live aktuell? Zählt OB-40 am 03.10.
2. Live-Werte von `MinPetitionSigns` und `AllowTwoSide.Interaction.Guild`: nur aus der Vorlage rekonstruiert (9 bzw. 1, UNSICHER).
3. Sind die Petitionen mit mehr als 9 Unterschriften vollständig vor dem Deploy von #241 entstanden? Dafür fehlt ein Dump-Vergleich (UNSICHER).
4. Wie oft feuert der Trigger „random“ für „offer petition nearby“? Danach richtet sich, wie viele synchrone Abfragen pro Minute heute verschwendet werden.
5. Wie verteilen sich die Ad-hoc-Austritte (LeaveFarAway gegenüber `objective_done`/`idle`)? Es sind keine `[BotGroup]`-Logs gesichert.
6. `TravelMgr.cpp:149-154`: Ist die Abgabesperre in der Overworld vertauscht? Davon hängt die Ursache der Schleife bei 5722 ab.
7. Mechanismus der Schleife bei Earth Sapta: Gibt es eine echte Mehrfachbelohnung, oder schlägt `CanRewardQuest` fehl?
8. Rufen alle relevanten Eskort-Skripte die Basis-Implementierung `JustDied` (FailQuest) auf? Die Eskort-Liste (24 bzw. 52) ist heuristisch.
9. Bindet live genau `C:\TW\ComTW\data` (mmaps) ein? Prüfung durch OB-30.
10. Werden Quest-Items in mod-dungeon-clear zuverlässig gelootet? Test in einer Wegwerf-Umgebung.
11. Entscheidungen des Inhabers:
    - Gildenanzahl (Vorschlag 4–6 je Fraktion) und Zielgröße
    - organische oder deterministische Gründung
    - eigene Namensliste
    - Umgang mit den 40 bestehenden Urkunden
    - Leichenlauf statt Geistheiler in Gruppen
    - Öffnung von mod-dungeon-clear für reine Bot-Gruppen
    - eigener Gruppentyp für Instanzen
12. Widerspruch ADR-0031:127-129 gegenüber den live aktiven Ad-hoc-Gruppen bei offenem #324: wird an OB-00 gemeldet.
13. Fehlende Log-Segmente (30.09. 00:34–16:58, 02.10. 04:11–15:42) und der weiter wachsende Snapshot von 8.8: Soll OB-30 sie einfrieren und mit Hash ablegen?