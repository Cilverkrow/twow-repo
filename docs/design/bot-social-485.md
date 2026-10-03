# Bot-Sozialverhalten: Questen, Berufe, Gruppen und Gilden (#485), Entwurf v2

- **Status:** Entwurf v2 zur Prüfung durch OB-10 und den Inhaber. Vorschlag, keine Entscheidung. Ersetzt v1 vom 02.10.
- **Issue:** Refs #485. Verwandt: #324, #333, #338, #340, #342, #343, #365, #405, #453, #471, #472, #474, #477, #478, #484.
- **Zuständig:** OB-10 prüft und übernimmt die Umsetzung. Bot-Chat und Addon: OB-15. Daten, Zählungen und DB-Jobs: OB-40. Konfiguration, Deploy und Messung: OB-30.
- **Datum:** 2026-10-03
- **Quellstände:**
  - Core `origin/main` ad5ba7f7 (8.10-Zwilling). Live v25 = `release/8.x` 14ed35c0. mod-playerbots ist auf beiden Ständen identisch mit v24 (441d62e7). Alle Zeilenangaben gelten für ad5ba7f7.
  - Repo `origin/main` 8c872fca.
- **Methode:**
  - Ausgewertet wurden nur gesicherte Dateien: die gameplay-logs der Züge 8 bis 8.9 auf Y:, die Live-Konfigurationsdateien (nur lesend) und die Dumps vom 01.10. 03:06Z.
  - Es gab keine Abfrage der Live-DB, keinen Docker-Befehl und keinen Build.
  - Primärbasis ist ein eingefrorener v24-Schnappschuss (19:28–22:08Z, 2,67 h, 180 Roster-Bots, Rosterphase v6/180) mit SHA256SUMS.
  - Jede Kernaussage haben zwei unabhängige Prüfer gegengecheckt. Widerlegte Aussagen sind gestrichen, Korrekturen eingearbeitet.
- **Evidenz** (Wurzel `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-10\cli485-bot-social\work\v2\`):
  - `snap-v24-20261002T2208Z\`: Server-Log, bot_events, perf, loot, levelup, deaths, SHA256SUMS
  - je Thema ein Ordner mit `commands.sh` und Hash-Dateien: `quest-rates`, `quest-traces`, `quest-code`, `fishing`, `gathering`, `crafting`, `guild-impl`, `groups-death`, `conventions-reset`, `synthesis-prs`, `critic-completeness`
- **Messbasis-Vorbehalt:**
  - Raten nur in gleich langen Fenstern derselben Rosterphase vergleichen. Tickwerte erst ab dem XMP-Bruch vom 02.10. 15:40Z.
  - v25 (8.10) ist als neue Basis noch nicht ausgewertet.
  - `TalkToQuestGiverAction` zählt Abgabe-Versuche. Echte Belohnung: dasselbe Event plus `XpGainAction` ohne Opfer innerhalb von 15 s (149 von 150 Fällen = RewXP). Belastbar bleibt `character_queststatus.rewarded`.

---

## 1. Entscheidungen vom 02./03.10. und was daraus folgt

Quelle sind die Kommentare von OB-00 in #485, mit dem Wortlaut des Inhabers.

| Thema | Entscheidung | Folge für den Entwurf |
|---|---|---|
| ADR-0031:127-129 | Live hat Vorrang, Bot-Gruppen laufen seit Zug 7; #324 bleibt Ziel | ADR-Text angepasst (dieser PR) |
| #343 | Zuerst „Spieler + 4 Bots“, reine Bot-Dungeons sind Phase 2 | Abschnitt 5.5 |
| Gilden-Zuschnitt | Gilden stellen eigene Gruppen-, Dungeon- und Raid-Runs, Rollen ausgewogen; Zahl wächst mit der Bot-Zahl | `BotsPerGuild` je Fraktion, Abschnitt 5.1 |
| Urkunden | Bots kaufen und gründen nur bis zur Zielzahl; danach kein Verkauf an Bots; die heutigen Urkunden werden zum Gründen genutzt, Reste später gelöscht (OB-40, Trockenlauf) | PR-5 plus DB-Job |
| Spieler | Gründen immer möglich; Bots aus anderen Gilden abwerben | Regeln in 5.1, Core-Hook Zug 10 |
| Namen | Lore-nah, ohne Markenbezug; Inhaber gibt frei | Liste in 5.1 |
| Leichenlauf | In Gruppen „korrekt“: Gruppe wartet bzw. belebt wieder | Abschnitt 5.3 |
| Gildenchat | Nur Gildenkanal, nur wenn ein echter Spieler der Gilde online ist, selten; kein Bot-Bot-Chat | Gate (OB-15), Sofort-Konfig Rang 7 |
| Auftrag v2 | Questen insgesamt, Quest-Items, Angeln, Sammel- und Herstellungsberufe | Abschnitte 2.4–2.7 |
| Bot-Reset | Erst Quest-Schleife beheben, dann bewerten | Abschnitt 6 |

---

## 2. Befunde

### 2.1 Questen: Bots stecken an Abgaben fest, nicht am Annehmen

**Raten v24** (480 Bot-h, `quest-rates`):

| Größe | Wert |
|---|---|
| Annahmen / Abwürfe | 2.308 / 2.463 (865 / 924 pro h) |
| davon grau (8.7-Regel) | 1.560 Annahmen, 1.642 Abwürfe, Median 120 s dazwischen |
| echte Abgaben | 150 (56/h, **0,31 je Bot-h**) |
| XP | **523 je Bot-h** (Kill 357, Quest 141) |
| Bots ohne XP in 160 min | **70 von 180** (40 davon schon in v23, ≥ 6,4 h) |
| Bot-Zeit an Abgeber-Zielen | **64 %** |
| Routenanfragen „nur Abgeber“ | 2.529 von 2.740 (92 %) |

**Ursachen, nach Gewicht:**

1. **Abgabe-Gate ohne Ausweg.**
   - Ein Roster-Bot mit nur einer fertigen Quest fragt ausschließlich Abgeber an (`ChooseTravelTargetAction.cpp:2005`) und sammelt nicht (`TravelValues.cpp:369-377`, Hotfix 8.5).
   - 170 von 179 Bots trugen beim letzten Request eine fertige Quest.
   - Scheitert die Abgabe, gibt die Recovery nie auf: WORK-Timeouts am Abgeber zählen nicht (`TravelMgr.cpp:1117-1142`), Routensperren dauern 120 s.
2. **Kontinentreisen kommen nie an.**
   - 859 von 1.745 Abgeberwahlen (49 %) gehen auf einen anderen Kontinent: 0 von 665 kamen an, in 20 gesicherten Versionen kein einziges BoardTransport-Event.
   - QuestRescue erzeugt weitere: 22 von 65 Rettungen landen auf dem anderen Kontinent.
   - Die Ursache im Bewegungscode ist offen und gehört zu #342.
3. **Unbenutzbare Abgeber.**
   - Quest 310 „Bitter Rivals“: Das Abgeber-GO 270 spawnt nur per Skript (`spawntimesecs < 0`). Ergebnis: 32 Bots, 594 Ankünfte, 510 WORK-Timeouts, 0 Abgaben, 59,5 Bot-h (12,6 % der Zeit). Ein game_event oder Pool spawnt es nicht (0 von 7 GUIDs im Dump).
   - Quest 5722: Der Abgeber steht in Ragefire Chasm. Die Instanzprüfung `TravelMgr.cpp:152` ist **invertiert**: `IsOverWorld` gehört zum Ziel-Quadrat und sperrt Oberwelt- statt Instanz-Abgeber. Ergebnis: 111 Wahlen nach RFC, 0 Abgaben. Die v1-Vermutung eines zweiten Pfads ist widerlegt.
4. **Unsichtbare Bewegungsschleife.** 77 Bot/Quest/Ziel-Tripel (67 Bots) kommen nie an. `MoveToTravelTargetAction.cpp:149-158` setzt nach 11 Fehlversuchen ohne Trace auf COOLDOWN. Das erzeugt 3.110 der 3.932 `status_time_exceeded_cooldown`-Zeilen.
5. **Annahme-Abwurf-Churn.** Zwei Drittel grau; 8.11 deckt ihn ab. Danach bleiben rechnerisch etwa 748 Annahmen und 656 Abwürfe. Davon sind rund 600 Grün-Abwürfe aus CleanQuestLog bei vollem Log: Das Softlimit 16 gilt nur für Reisen zu Questgebern, nicht für RPG-Annahmen.
6. **Earth Sapta (1462/1463).** Zuerst gab es echte, aber leere Mehrfachbelohnungen. Nach der Kettenquest scheitert `CanRewardQuest`: 602 von 682 Events.
7. **Quest-Items werden nicht benutzt.**
   - Es gibt keinen autonomen Pfad „Item auf Ziel benutzen“, nur „rpg item“ mit Zufall 1/21.
   - `[ItemUse]` zählt nur Öffnen und Imbue: 16 Fenster, 0 uses, 261 opens.
   - 98 der 1.691 Quests L1–25 brauchen ein Item. v24: 77 Annahmen, 118 Abwürfe, 0 Abgaben.
   - Quest-Starter-Items werden wegen `SyncQuestWithPlayer=1` nie gelootet.
8. **Messlücken.** 501 von 2.463 Abwürfen haben keine geloggte Annahme (QuestDetailsAction loggt nicht), und Retire ist bei LogLevel 1 unsichtbar.

**Tote Konfiguration:** `AutonomousLogSoftLimit`, `RejectBelowLevelDelta` und `MaxAboveLevelDelta` werden nicht ausgewertet. `quests=N` in `[Idle]` ist die Statusmap (Median 65), nicht das Questlog.

**Vergleich:** Im gleich langen Startfenster von v22 waren es 1,09 Abgaben und 995 XP je Bot-h. Seit 8.7 stieg der Cross-Map-Anteil der Abgeberwahlen von 21 % auf rund 50 %.

### 2.2 Gilden: Schlüsselfehler plus Urkunden-Karussell

- **Hauptursache (aus v1 bestätigt):**
  - `PetitionSignsValue` und `PetitionOfferAction` fragen `petition_sign` mit dem Item-GUID-Zähler der Urkunde ab (`GuildValues.cpp:1276`, `GuildCreateActions.cpp:151/160`). vmangos speichert dort die Petition-ID (`PetitionsHandler.cpp:147-154`).
  - Folge: 0 Gilden im ganzen Zug 8.
  - Ein Replay aus Dump und allen SQL-Zeilen zeigt: 57 Petitionen hatten zeitweise genau 9 Unterschriften, eine Gründung wäre also möglich gewesen.
- **Last:** 4.701 synchrone Petition-Abfragen pro Stunde im Map-Thread, Spitzen bis 24 ms; seit 01.10. 03:08Z über 70.000, keine konnte treffen.
- **Karussell:**
  - Der Core löscht bei jeder neuen Unterschrift die alte des Unterzeichners. Deshalb waren 88 % der 3.122 Unterschriften auf v24 Umzüge (≈ 1.164/h).
  - Dazu kommen 256 wirkungslose Kaufversuche: `"item count", "Hitem:5863:"` wird nie geparst.
- **Kauf-Zerstör-Schleife:** Seit 8.3 wurden 32 Urkunden gelöscht (Bots 44, 227, 877, 7), oft in derselben Sekunde wie ein Neukauf. Die 7 `[PetitionHandler] No petition exists`-Fehler auf v24 entstehen genau so (Bot 227, pid 129/130). Wer zerstört, ist nur per Korrelation belegt (SmartDestroyItemAction bei vollen Taschen; UNSICHER).
- **Bestand 02.10. 22:08Z:**
  - **82 offene Urkunden** (38 Allianz, 44 Horde), nicht 40. Am 03.10. 00:31Z waren es 84.
  - **18 Waisen** (ids 1–18) ohne Urkunden-Item, alle aus dem L1-Reset vom 26.09. Deren Besitzer können keine neue Urkunde kaufen, der Core bricht still ab.
- **Korrektur zu v1:** Gildenchat ist bei `BotChat.Direct=0` **nicht** stumm. `SayToGuild` fällt auf `BroadcastToGuild` zurück, und `GuildRepliesRate=65` lässt Bots auf Bots antworten. Dazu kommen /say-Wege (`InviteChat`, `RandomBotSayWithoutMaster=1`, `+custom::say`).
- **Hauptstadt-Bedingung (v1, Punkt 3):** In 47 von 47 `[Idle]`-Proben von Urkunden-Besitzern in Hauptstädten war ein Reiseziel aktiv. Die Bedingung blockiert praktisch immer, deshalb entfällt sie im neuen Pfad.

### 2.3 Gruppen und Tod

- **Der eigene Ad-hoc-Austritt ist ein No-op** (#365 Schritt 2).
  - `AdhocGroupAction::CheckLeave` löst „leave“ mit dem Bot selbst aus (`AdhocGroupAction.cpp:201`). `ShouldStayInGroup(…, player==bot, …)` hält ihn in der Gruppe (`LeaveGroupAction.cpp:68`, `SingletonGroupPolicy.h:16-19`).
  - Auf 1.900 Austrittsentscheidungen folgte 1 echter Austritt. Leiter 3285 traf 69 No-op-Entscheidungen in 34 min, jede mit `ai->Reset()`.
- **Echte Austritte laufen nur über LeaveFarAway.** Bei `RandomBotGroupNearby=0` gilt der Austritt sofort als nützlich (`LeaveGroupAction.cpp:123-124`), ausgelöst vom Zufallstrigger „seldom“. Die Verweildauer ist deshalb exponentiell verteilt, im Mittel 38 min.
- **Gruppen sind selten geworden:** Paare mit gleichem Ziel in 50 yd fielen von 3.671 (Zug 7, 14,8 h) auf 5 (v24). Auf v24 entstand 1 Gruppe.
- **Tod in bot-geführten Gruppen:**
  - Der Geist wird nach median 3 s freigegeben (`ReleaseSpiritAction.h:103-113`).
  - 95 % gehen zum Geistheiler (v24: 271 von 286, Leiche nur 5).
  - Heiler finden nur unfreigegebene Körper in 26 yd (`PartyMemberToResurrect.cpp:40`). In Zug 7 gab es bei 221 Gruppentoden deshalb 0 Wiederbelebungen durch Mitglieder.
- **Gefahr für D2:** Bot 27 (Nilenata) hängt seit v24 19:39:58Z mit `combat=1` in Zone 5561 fest; in v25 um 01:43:50Z idle 70 min. D2 („kein Bot ≥ 24 h ohne XP“) droht ab etwa 03.10. 19:40Z (UNSICHER, falls zwischendurch XP kam).

### 2.4 Angeln

- **Technisch funktioniert es seit 8.8:** 188 von 188 Bobber-Uses verarbeitet, 6 Sitzungen von 5 Bots, +320 Skill (Bot 301 auf 84 nach Journeyman).
- **Die Teilnahme ist winzig.** 29 Zwecke, davon 22 mit `no_spot` (79 %).
- **Ursachen:**
  1. **Phantom-Zweck:** Der Zweck wird als Nebenwirkung einer Wertberechnung gestartet (`NeedTravelPurposeValue`, alle 5 s), auch ohne Angelziel. Bei 15 von 28 Zwecken ist kein Angelziel nachweisbar.
  2. **Falsche Zeitbasis:** Die `no_spot`-Uhr (300 s) läuft ab Zweckstart. Erfolgreiche Sitzungen brauchten bis zum ersten Wurf 69–310 s.
  3. **Sammelsperre:** Fertige Quests sperren jeden Sammelzweck (2.1, Punkt 1).
- **Fang wird weggeworfen:** Von etwa 107 Fängen wurden 5 gelootet, alles Quest-Barsche. Rohfisch liegt unter 0,1 % des Botgelds, gilt deshalb als `ITEM_USAGE_NONE` und bleibt liegen. Fisch wurde in keiner Version verkauft.
- **Kochen fehlt ganz:** 174 Bots stehen auf 1. Bots kaufen Holz und Rezepte, aber es gibt keinen Koch-Pfad.
- **Weitere Fehler:**
  - 28 % Trockenwürfe, weil eine Wasserprobe fehlt.
  - `TravelMgr.cpp:748` überschattet die Zonen-Skillgrenze.
- **Balance:** Angeln belegt 0,43 % der Bot-Zeit und stiehlt keine Questzeit; alle fünf Angler hatten vorher keinen Questfortschritt.

### 2.5 Sammelberufe

**Skill pro Tag** (OB-40, 30.09.–02.10., 47,9 h):

| Beruf | pro Tag |
|---|---|
| Kräuterkunde | +14,5 |
| Erste Hilfe | +10,2 |
| Bergbau | +4,1 |
| Kürschnerei | +3,1 |

**Kürschnern (#471 noch nicht erreicht):**
- Bots lassen Schrott unter Geld/1000 liegen (`ItemUsageValue.cpp:466-475`). Die Leiche bleibt dann plünderbar, und der Core verweigert das Häuten (`Spell.cpp:6294-6306`).
- Haut-Loot meldet der Core als `LOOT_PICKPOCKETING` (`Player.cpp:9829-9836`). Die Ausnahme für Haut-Loot griff deshalb nie, Lederfetzen fielen unter die Geldregel.
- Leichen mit fremdem Loot werden zum Häutziel; der Bot nimmt sie jede Sekunde neu auf.
- Bei Leichen der Stufe 10 umgeht `reqSkillValue` 0 die Messerprüfung.
- Häutungen: v23 3 von 133 passenden Leichen, v24 0 von 37.
- Korrektur: Die v2-Aussage „Kernregel (L−10)·10 ist die Hauptursache“ ist von beiden Prüfern widerlegt. Die Formel gilt, erklärt aber den Median 1 nicht.

**Bergbau („breit, aber flach“):**
- Begegnungen je Sammler-Stunde sind 8,7× seltener als bei Kräutern.
- Knoten werden nur bis 25 y und ohne unfreundliche Einheit in 60 y abgeerntet.
- 6 von 42 Bergleuten hatten am 01.10. keine Spitzhacke.
- Aktive Bergbau-Zwecke bringen nichts: 79 Starts, 77× `no_skillup`, +9 Skill.
- Erz wird nie behalten (2 Erzzeilen in 35 h).

**Weitere Befunde:**
- **Trainer:** Die 12.055 `[PersistentRosterProfessionTraining]`-Ablehnungen sind kein Blocker, sondern Rauschen (eine Zeile je Bot und Trainer pro 300 s).
- **Rang-Cap:** Der echte Engpass ist der fehlende Trainerbesuch am Cap. 5 Kräuterkundler und 6 Erste-Hilfe-Bots stehen seit ≥ 48 h auf 75/75.
- **Kräuter:** Vom gemeldeten Knoten bis zum Öffnen kommen nur etwa 14 %. 59 % der Gather-Spuren stammen von Bots ohne den Beruf.

### 2.6 Herstellung: der item-Cheat täuscht Reagenzien vor

- **Hauptursache:**
  - Alle 180 Roster-Bots laufen mit `RndBotCheats = repair,breath,item,taxi`. Unter dem item-Cheat meldet `HasReagentsForValue` für jedes Rezept „vorhanden“ (`CraftValues.cpp:79-80`).
  - `CraftRandomItemAction` wählt deshalb ein beliebiges Rezept. Der Core verlangt echte Reagenzien, Werkzeug und Fokus (`Spell.cpp:7453-7519`) und bricht still ab.
- **Zahlen:**
  - v24: 4.791 `stage=craft state=started`, 0 `no_materials`.
  - 30.09.–02.10.: etwa 68.200 Versuche, etwa 3.150 Skillpunkte (≤ 1,5–6 % Erfolg), praktisch nur Verbände und Leinenballen.
  - `started` heißt nur „castnc in die Warteschlange gestellt“; `detail` ist die Botstufe.
  - Der Zufallspick trifft im Mittel nur in 12,7 % der Fälle ein wirklich herstellbares Rezept.
- **Material wird verkauft** (`ItemUsageValue.cpp:187-188`). v24: 89× Leinen, ≈ 45× Kräuter, 64× Edelsteine, 38× Fleisch.
- **Händler-Reagenzien werden nie gekauft:** 0 Phiolen (0 von 24 Alchemisten haben eine), 0 Kupferstäbe.
- **Rohstofflücke:** Schmiede-, Ingenieurs- und Juwelier-Startrezepte brauchen Rauen Stein; v24 lootete 0 Kupfererz und 0 Rauen Stein. Lederverarbeitung bekommt kein Leder (2.5).
- **Kochen** braucht ein Kochfeuer (Fokus). Der Trigger schließt Fokus-Rezepte aus, und das Lagerfeuer 818 ist kein Craft-Spell.
- **Keine Ursachen:**
  - `MAX_SPELL_ID`: Alle Rezepte haben IDs ≤ 58.046, 8.10 ändert hier nichts.
  - Werkzeug: meist vorhanden.
  - Rezepte: Startrezepte lernt der Bot zur Laufzeit.
- **Geplante Paare** (`ProfessionPair.h`): Kräuter+Alchemie 33, Kürschnern+Leder 29, Bergbau+Schmiede 20, Bergbau+Ingenieur 14, Bergbau+Juwelier 15, Schneiderei+Verzauberkunst 27, Kräuter+Bergbau 24.

### 2.7 Verbrauchsgüter

- `UseConsumableAction.cpp:781` schaltet Verbrauchsgüter unter dem item-Cheat ab, und `ItemUsageValue.cpp:216` führt sie zum Verkauf.
- v24: `[ItemUse]` 16 von 16 Fenstern mit uses=0, 40 verkaufte Verbände.
- Gifte und Öle (ImbueAction) sind UNSICHER.
- Ob Roster-Bots echte Verbände und Tränke nutzen sollen, entscheidet der Inhaber (Abschnitt 7).

---

## 3. Priorisierte Fix-Liste

**Leseregeln:**
- Rang = erwartete ADR-0031-Wirkung je Aufwand und Risiko.
- „Hotfix 8.x“ heißt ohne DB-Änderung, als 8.12 möglich (Zwilling auf `release/8.x`, Entscheidung OB-00).
- Basiswerte stammen aus dem v24-Schnappschuss: `synthesis-prs/baseline_v24.tsv`.
- Alle neuen Schalter haben neutrale Defaults. Profilwerte setzt ein twow-repo-PR erst nach dem Inhaberentscheid.

| Rang | Fix | Zug | Messgröße (Basis v24) | Ziel | Risiko | PT |
|---|---|---|---|---|---|---|
| 1 | **PR-1** Abgaben, die wiederholt scheitern, 60 min parken; Gate, Fetch und Sammelsperre zählen nur ungeparkte | Hotfix/9 | Abgaben 0,31/Bot-h; XP 523/Bot-h; 70 Bots ohne XP; 64 % Zeit an Abgebern | gebundene Zeit < 25 %; Bots ohne XP < 20; XP ≥ 650 | geparkte fertige Quests belegen Log-Plätze | 2 |
| 2 | **PR-2** Unbenutzbare Abgeber raus: Instanzprüfung umgedreht, Skript-GO-Abgeber übersprungen, Stall-Sperre mit Zielkarte | Hotfix/9 | Quest 310 59,5 Bot-h; 5722 111 Wahlen | 0 Reisen zu GO 270 und nach RFC | Event-GOs: 0 von 7 betroffen | 1 |
| 3 | Kontinent-Questreisen bis #342 sperren (`MinLevelForCrossMapQuestRoute`, nur Kontinente) | Konfig | 0 von 665 angekommen | 0 Cross-Map-Wahlen | nur zusammen mit Rang 1 | 0,1 |
| 4 | **PR-3** Kürschner-Kette: eigene Leiche leer plündern, Haut-Loot immer nehmen, kein Häutziel unter fremdem Loot | Hotfix/9 | Häutungen v24 1 in 2,67 h; Kürschnern +3,1/Tag | ≥ 3 Häutungen/h; ≥ 10 Skill/Tag | mehr Grauschrott | 1 |
| 5 | **PR-4** Herstellung mit echten Reagenzien: bestes Rezept, direkter Selbst-Cast, Material behalten, Händler-Reagenzien kaufen | 9 | Alchemie, Schmiede, Ingenieur, Juwelier 0/Tag | Alchemie > 0; failed < 10 % | Taschen, Gold | 2 |
| 6 | **PR-5** Gilden-Fundament: Zählung im Speicher, Ziel je Fraktion, freigegebene Namen, kein Karussell, kein /say an Bots | 9 | 0 Gilden; 4.701 Petition-SQL/h; 1.164 Umzüge/h | Ziel je Fraktion in 48 h; 0 Petition-SQL | Rollen-Füllen folgt | 2 |
| 7 | Sofort-Konfig bis PR-5 aktiv (Entwurf #495): `RandomBotFormGuild=0`, `InviteChat=0`, `RandomBotSayWithoutMaster=0`, `+custom::say` streichen | Konfig | 4.701 SQL/h; ≥ 1.165 /say/h | jeweils 0 | keins | 0,1 |
| 8 | GD-1: eigener Ad-hoc-Austritt wirksam; LeaveFarAway für registrierte Gruppen aus; Repop-Austritt geloggt | Hotfix/9 | 1 von 1.900 wirksam | ≥ 95 % in ≤ 15 s | gering | 1 |
| 9 | Messbarkeit: `QuestRewarded` nach RewardQuest, Abwurfgrund, Retire als Event, `[QuestLog]`-Delta | Hotfix | 501 Abwürfe ohne Annahme | Bilanz schließt | Logvolumen | 1 |
| 10 | Leere oder unmögliche Wiederholungs-Abgaben stoppen (Earth Sapta und 24 gleichartige) | 9 | 602 gescheiterte Abgaben | 0 | gering | 0,75 |
| 11 | Rettung aus Dauerkampf mit unerreichbaren Gegnern | Hotfix | 3 Bots ≥ 130 min combat=1 (Bot 27) | 0 Bots > 30 min | Teleport aus legitimem Kampf | 1 |
| 12 | Angeln I: Zweck erst beim Angelziel, `no_spot` ab Zielsetzung, Angelprüfung | 9 | 22 von 28 `no_spot` | ≥ 60 % mit Wurf | 8.5-Contract anpassen | 1,5 |
| 13 | Angeln II: Fang behalten, Wasserprobe, Zonen-Skill-Bug | 9 | 5 von 107 Fängen gelootet; 28 % trocken | ≥ 90 %; < 5 % | Taschen | 1,5 |
| 14 | Kochen: Lagerfeuer 818, Fokus in Reichweite | 9 | 173 von 174 auf 1 | ≥ 10/Tag bei Anglern | Feuer-GOs | 1,5 |
| 15 | Sammelzwecke nur, wenn machbar (Werkzeug, Stufenband); Werkzeug bereitstellen | 9 | Bergbau 77 von 79 `no_skillup` | < 30 % | weniger Sammelreisen | 1,5 |
| 16 | Knoten wirklich abernten (Reichweite, Feindregel, Prüfreihenfolge) | 9 | Kräuter 14 % Öffnung | ×2 | mehr Pulls | 2 |
| 17 | Trainerreise am Rang-Cap (≤ 800 y, gleiche Karte) | 9/10 | 11 Bots ≥ 48 h auf 75/75 | 0 > 24 h | Tode unterwegs | 2 |
| 18 | Quest-Items gezielt benutzen (Whitelist 10–15 Quests) | 9/10 | 77 Annahmen, 0 Abgaben | ≥ 0,25 je Annahme | Fehlanwendung | 3,5 |
| 19 | QuestRescue nur auf den Kontinent der eigenen Abgaben | Hotfix | 22 von 65 kontinentfremd | ≤ 5 | weniger Ziele | 0,5 |
| 20 | Softlimit 16 auch für RPG-Annahmen | 9, nach 8.11 | 600 Grün-Abwürfe | < 50/h | Folgequests | 0,75 |
| 21 | Fertige Quests mit dauerhaft unbenutzbarem Abgeber aufgeben (nach 3 Parks) | 9 | 310 bei 24 Bots fertig | Log-Plätze frei | RewXP verloren | 1 |
| 22 | Gruppenbildung an Elite- und Gruppenzielen (`QuestGroup.Enabled`) | 9/10 | 1 Gruppe in 2,65 h | Gruppen-Quests/Tag > 0 | Wipes | 3 |
| 23 | GD-2 bis GD-4: Freigabe für Heiler halten, Leichenlauf, Warten, Wipe-Regel | 9, nach 8 | 0 Wiederbelebungen durch Mitglieder | ≥ 50 % per Leiche/Zauber | Folgetode | 5 |
| 24 | Gilden II: Koordinator (Rollen), Gildenchat-Gate (OB-15), Abwerb-Hook (Core) | 9/10 | Rollen live 12/20/58 je Fraktion | Abweichung ≤ 1 je Rolle; Chat ≤ 4/h je Gilde | Core-Änderung | 5,7 |
| 25 | Altbestand an Urkunden bereinigen; `reset-l1.sql` behandelt Petitionen und Gildenleitung | 9/10 (DB) | 84 offen, 18 Waisen | 0 Waisen | DB-Mutation | 1,5 |
| 26 | Verbrauchsgüter für Roster-Bots (`RosterConsumables.UseReal`) | 9 | uses=0 | uses/h > 0 | Gold | 1 |
| 27 | Eskort-Quests nur in Gruppe oder per Override-Liste (Erweiterung von `SkipForRosterBot`, nach 8.11) | 10 | 52 IDs: 3 Annahmen, 0 Abgaben | Eskort-Abgaben/Tag > 0 | 8.11-Überschneidung | 1 |
| 28 | Dungeon Phase 1: `[Dungeon]`-Diagnose, DungeonClear-Konfig, Test mit dem Inhaber | 9 | 0 Läufe | 1 Endboss, 1 Wipe-Recover | Map-Pool-Crash (alt) | 1,5 |

**Risiken und Wechselwirkungen:**
- **8.11** ist nicht gepusht. Keiner der fünf PRs berührt `AcceptQuestAction.cpp`, `QuestAcceptPolicy.h` oder `DropQuestAction.cpp`. Gemeinsame Anker sind `PlayerbotAIConfig.h/.cpp`, `aiplayerbot.conf.dist.in` und `tests.cmake`; nach dem 8.11-Merge rebasen.
- **core#275 (Reiten):** ändert `TravelMgr.h/.cpp`, `ItemUsageValue.cpp`, `BuyAction.cpp`, `VendorValues.cpp` und `tests.cmake`. Fachlich kürzt `NeedMoneyFor::mount` das Geld für Berufseinkäufe; den Gold-Vorrang entscheidet der Inhaber.
- **Abhängigkeiten:**
  - Rang 2 und 3 ohne Rang 1 ersetzen Reiseschleifen nur durch Ablehnung mit Backoff.
  - PR-4 bringt Schmiede, Ingenieur und Juwelier erst etwas, wenn Erz und Stein ankommen (Rang 15/16).
  - PR-5 ohne Rang 7 lässt den Altpfad mit 4.701 SQL/h laufen.
- **Tick-Kosten** (erwartet ±0): PR-1 O(≤ 16) je Routenanfrage; PR-4 eine Rezeptbewertung je Bot und ≥ 60 s; PR-5 ein Snapshot höchstens alle 60 s ohne SQL.
- **Basis Tick v24:** Minuten-p99 im Median 129 ms, Maximum 632 ms; Tick-Maximum 2.470 ms (während eines lokalen Builds).

---

## 4. PRs dieser Nacht (Entwürfe gegen core `main`)

Alle fünf PRs sind Entwürfe mit `Refs #485`. Jeder enthält eine Policy-Headerdatei mit Unit-Test und einen Source-Contract, registriert in `modules/mod-playerbots/tests.cmake`.

**Nachweis:**
- Alle Source-Contracts liefen auf dem Host gegen einen LF-Export des Commits (`builds/cli485/build/run-contracts-commit.sh`).
- Ein lokaler Build war nicht möglich: Das Welle-2-Messfenster auf v25 (00:30–08:00Z) ist laut OB-00 in #319 build- und containerfrei. Compile-Gate ist deshalb die PR-CI „Build core (Debian trixie)“.
- OB-10 prüft fachlich. Die Spielwerte entscheidet der Inhaber.

| PR | PR (Branch) | Inhalt | neue Schalter (Default → Vorschlag) |
|---|---|---|---|
| PR-1 | core#278 (`cli485/turnin-park`) | Abgaben parken (Rang 1) | `QuestFirstProgression.TurnInParkFailures` 0 → 3, `…ParkWindowSeconds` 3600, `…ParkSeconds` 3600, `…TurnInParkCountsRouteDanger` 0 → 1 (nur mit Rang 3) |
| PR-2 | core#277 (`cli485/unusable-takers`) | Unbenutzbare Abgeber (Rang 2), Kontinent-Option für Rang 3 | `QuestFirstProgression.SkipScriptOnlyQuestTakers` 0 → 1, `…CrossMapContinentsOnly` 0 → 1 |
| PR-3 | core#279 (`cli485/skin-chain`) | Kürschner-Kette (Rang 4, #471) | `ProfessionUse.ClearCorpseForSkinning` 0 → 1 |
| PR-4 | core#280 (`cli485/craft-reagents`) | Herstellung mit echten Reagenzien (Rang 5, #333) | `ProfessionUse.RealReagents` 0 → 1, `.KeepCraftMaterials` 0 → 1, `.ReagentKeepStacks` 1, `.CraftFailBackoffSeconds` 1800, `.VendorReagents` "" → Liste |
| PR-5 | core#281 (`cli485/guild-foundation`) | Gilden-Fundament (Rang 6) | `RosterGuild.BotsPerGuild` 0 → 45, `.NamesAlliance`/`.NamesHorde` "" → Liste, `.SnapshotSeconds` 60 |

Dazu kommt der Konfig-Entwurf **#495** (Rang 7: kein Bot-Bot-/say, `RandomBotFormGuild=0` bis PR-5 aktiv ist).

**Querabgleich** (`work/v2/impl-cross.md`):
- Alle 10 PR-Paare, der Gesamtbaum und der Gesamtbaum mit core#275 laufen ohne Textkonflikt; der Gesamtbaum besteht 100 Contracts (nur die 2 Host-Artefakte scheitern).
- **Echter Konflikt:** Der 8.11-Arbeitsstand von OB-10 und PR-3 ändern beide `LootAction.cpp:441`. Die geprüfte Auflösung steht im PR-3-Text.
- **Gekoppelte Entscheidung S1:** `MinLevelForCrossMapQuestRoute=61` nur zusammen mit `CrossMapContinentsOnly=1` (PR-2) und `TurnInParkCountsRouteDanger=1` (PR-1). Sonst werden Abgaben auf dem anderen Kontinent nie geparkt.
- **Empfohlene Merge-Reihenfolge:** 8.11 → PR-2 → PR-1 (gemeinsam ausliefern) → PR-4 → PR-3 (nach 8.11, mit Auflösung) → PR-5.

---

## 5. Entwürfe

### 5.1 Gilden

**Zielzahl:**
- `Ziel je Fraktion = ceil(Roster-Bots der Fraktion / BotsPerGuild)`, berechnet aus der Rostergröße, nicht aus der Online-Zahl.
- Bei 180 Bots und 45 je Gilde: 2 je Fraktion. Mit Welle 2 (360) werden es automatisch 4.

**2×45 gegen 3×30 (je Fraktion):**

| Kriterium | 2×45 | 3×30 |
|---|---|---|
| stufengleiche 5er-Gruppen | gleich (Allianz ≈ 12, Horde ≈ 11) | gleich |
| 40er-Raid aus einer Gilde | ja | nein (nur 20er) |
| schwächste Horde-Gilde | 4–5 Gruppen | 1–2 Gruppen |
| Tank-Plätze je Gilde | 6 | 4 |

**Empfehlung: 2×45.** Rollen-Soll aus dem Live-Roster (12/20/58 je Fraktion): **6/10/29** je Gilde. Laut Vertrag (10/20/60) wären es 5/10/30; das entscheidet der Inhaber.

**Gründung (PR-5):**
- Zählung der Unterschriften im Speicher, über Core-Accessoren, die unter dem Petition-Lock kopieren. Kein SQL mehr.
- Kauf nur, wenn Gilden plus offene Bot-Urkunden unter dem Ziel liegen. Gründung nur unter dem Ziel, mit Reservierung unter Mutex: Auch bei 4 fertigen Urkunden und Ziel 2 entstehen genau 2 Gilden.
- Unterschriften wandern nur noch zur volleren Urkunde; das beendet das Karussell.
- Name aus der freigegebenen Liste. Eine fremde Urkunde wird vor der Abgabe umbenannt; das schreibt `UPDATE petition SET name` (DB-Schreibung des Spiels, im PR benannt).
- Die Hauptstadt-Bedingung entfällt für Roster-Bots im neuen Pfad.
- **Danach (Folge-PR):** Koordinator im Weltthread, der Mitglieder nach Rollenquote einlädt (Muster `ProcessQuestRescues`). Ohne ihn füllen sich Gilden nur organisch.

**Urkunden-Verfall:**
- Der Inhaber will, dass überzählige Bot-Urkunden verfallen.
- Empfehlung: im Spiel nichts löschen (jede Löschung braucht eine Einzelfreigabe). PR-5 stoppt den Neukauf.
- Nach den Gründungen löscht OB-40 alle Nicht-Gründer-Urkunden einschließlich der 18 Waisen per DB-Job: mit Trockenlauf, bei gestoppter Welt, nach Ansage durch OB-00.
- Bitte bestätigen: Gilt der Löschentscheid für alle 84 und nicht nur für „40“?

**Spieler gründen immer, Abwerben:**
- Konflikt: Bei 2×45 sind alle Roster-Bots in Gilden und können keine Spieler-Urkunde unterschreiben (Core: `ERR_ALREADY_IN_GUILD_S`).
- Vorschlag, eine Regel für Unterschreiben und Abwerben, als Core-Hook vor `ERR_ALREADY_IN_GUILD_S` (Zug 10):
  - Nur ein echter Spieler der gleichen Fraktion lädt ein.
  - Die Gilde des Spielers ist keine Bot-Gilde.
  - Der Bot ist nicht Gildenmeister einer Bot-Gilde.
  - Abklingzeit 24 h je Bot; PlayerbotSecurity bleibt.
  - Ein Bot verlässt eine Spielergilde nie von sich aus.
- Bis dahin gründen Spieler mit eigenen Unterzeichnern. Alternative: eine Reserve gildenloser Bots (z. B. `BotsPerGuild=40`).

**Namensvorschlag** (alle ≤ 24 Zeichen, nur Buchstaben und Leerzeichen; eigene Formulierungen). Ob es gleichnamige echte Gilden oder Marken gibt, kann die CLI nicht prüfen.
- **Allianz:** Wardens of Elwynn, Northshire Vigil, Lakeshire Bannermen, Westfall Harvestguard, Thelsamar Stoneguard, Ironforge Hearthguard, Gnomeregan Gearwrights, Menethil Tidewatch, Stromgarde Shieldbearers, Auberdine Moonwatch, Sentinels of Astranaar, Thalassian Spellwardens
- **Horde:** Razor Hill Bladeguard, Durotar Dustriders, Bloodhoof Drummers, Mulgore Hornbearers, Sun Rock Trailwardens, Crossroads Wayguard, Echo Isles Shadowhunters, Brill Lanternwatch, Sepulcher Gravewardens, Hammerfall Warbanner, Stonard Swampblades, Kezan Sparkwrights

**Gildenchat (OB-15, #478):**
- Gate in `PlayerbotAI::SayToGuild`, ebenso für den `BroadcastToGuild`-Rückfall: nur wenn ein echtes Mitglied online ist, höchstens 4 Zeilen je Gilde und Stunde, keine Antworten auf Bot-Zeilen.
- Bis das Gate live ist: `BotsPerGuild > 0` nur zusammen mit `EnableBroadcasts=0` (oder `BroadcastToGuildGlobalChance=0`) und `GuildRepliesRate=0`.

### 5.2 Questen

- **Grundsatz: parken statt abwerfen.** Eine fertige Quest bleibt im Log. Ihre Abgabe wird nach 3 Fehlschlägen innerhalb von 60 min für 60 min geparkt, und der Bot bekommt wieder Ziele, Geber und Sammelzwecke (PR-1).
- Fehlschläge sind: Stall, Tod auf der Route, WORK-Timeout, Bewegungs-Cooldown und „keine Route“ (Letzteres nur ohne Kontinent- oder Zonenfilter).
- Auch BotBrain-Intents laufen über `CopyTarget` und respektieren den Park.
- Kontinentreisen bleiben gesperrt, bis #342 Transporte beherrscht (Rang 3).
- Danach folgen Messbarkeit (Rang 9), Earth Sapta (Rang 10), das Softlimit für RPG-Annahmen (Rang 20), Quest-Items per Whitelist (Rang 18) und Eskort-Annahme nur in der Gruppe (Rang 27).
- **Grau-Politik:** Turtle zahlt Quest-XP voll bis Questlevel +25 (`QuestDef.cpp:184-186`); seit 8.7 sank die Quest-XP von 280 auf 141 je Bot-h. Empfehlung: vorerst die 8.11-Regel, dann ein A/B-Test mit Delta 10 nach der Messung (Inhaber).

### 5.3 Gruppen, Tod und Wipe

- **GD-1 (Hotfix):** Der eigene Austritt wird wirksam (Auslöser = Leiter bzw. eigener Disband statt No-op); LeaveFarAway gilt nicht für registrierte Ad-hoc-Gruppen; Repop-Austritte werden geloggt.
- **GD-2 bis GD-4 (Zug 9, Schalter `BotGroups.Death.Enabled = 0`):**
  - Die Freigabe wird bis 75 s zurückgehalten, solange ein Gruppenheiler in 60 yd lebt. 41 der 180 Roster-Bots können wiederbeleben.
  - Sonst läuft der Geist zur Leiche statt zum Geistheiler: bis 1.500 yd (deckt 93,4 % der v24-Leichen), höchstens 300 s.
  - Die Gruppe wartet bis 180 s. Nach 2 Wipes in 30 min löst sie sich auf, und das Paar ist 60 min gesperrt.
  - Solo-Bots gehen vorerst weiter zum Geistheiler.
  - Sicherheitsnetze für 0 verlorene Bots bleiben: Core-Auto-Release nach 6 min, Geistheiler-Rückfall, DeathLoop-Repop.
- **Gruppenbildung (Rang 22):** Paare an Elite- und Gruppenzielen, ausgelöst bei Ankunft am Ziel. Stau-Ziele mit QuestWorkTimeouts- oder Unreachable-Marke werden nicht gruppiert.
- **Tick:** O(≤ 5) je Tod. Basis v24: 951 Ticks/min, Minuten-p99 129 ms.

### 5.4 Berufe

- **Kette:** Sammeln → behalten → herstellen → nutzen oder verkaufen.
  - PR-3 liefert Leder.
  - Rang 15/16 liefern Erz und Stein.
  - PR-4 stellt mit echten Reagenzien her. Dabei bleibt der item-Cheat für alles andere; nur die Herstellung prüft echtes Material.
  - Rang 14 bringt Kochen, Rang 13 den Fisch.
- **Messgröße:** Skill pro Tag je Beruf (OB-40-Tagessnapshot). Dazu neue Traces: `stage=craft state=cast_started|failed` mit Spell-ID, `CraftCastStarted` in bot_events, `stage=skin state=looted|cleared`.
- **Schleifenschutz:** höchstens ein Cast je `CraftIntervalSeconds` (300 s), 30 min Sperre nach echtem Fehlschlag (Reagenz, Werkzeug, Fokus), Händlerkauf höchstens 1 Stapel je Reagenz.

### 5.5 Eskorte und Dungeon (aus v1, aktualisiert)

- **Eskorte:**
  - mod-playerbots kennt keine Eskorten. Der Core lässt die Quest scheitern, wenn alle Gruppenmitglieder weiter als 100 yd entfernt oder tot sind, oder wenn der NPC stirbt (`ScriptedEscortAI.cpp`).
  - Zug 10: Annahme nur in einer Gruppe ab 2 oder über eine Whitelist (Erweiterung von `SkipForRosterBot` nach 8.11), dann Strategie `escort`. Vorlage ist `DriveEscortCreature` in mod-dungeon-clear.
- **Dungeon #343, Phase 1 (Spieler + 4 Bots):**
  - mod-dungeon-clear startet mit einem echten Spieler.
  - Risiken: Wipe-Recovery (StayDead- und Loot-Roll-Overrides sind wegen eines Map-Pool-Crashs aus), `DungeonClear.*` ist live nicht gesetzt, die `[Dungeon]`-Diagnose fehlt, und nur etwa 11 % der Bots sind ≥ L17.
  - Empfehlung: Ragefire mit 1 Tank, 1 Heiler, 2 DPS plus Spieler, `DungeonClear.AsyncPathfinding = 0`, Termin mit dem Inhaber.
  - Live bindet `C:\TW\ComTW\data` (mmaps) ein; damit ist die offene Frage 9 aus v1 erledigt.
- **Phase 2 (nur Bots):** braucht einen eigenen Pfad für einen Bot-Leiter (die dc-Befehle akzeptieren nur echte Spieler und GMs), Gruppen aus Gildenrollen, Instanz-Reset (#453) und eine Begrenzung gleichzeitiger Läufe.

---

## 6. Bot-Reset: Nutzen gegen Kosten

**Kosten eines Vollresets jetzt:**
- Im Median 13,5 Stufen je Bot, rund 2.400 Bot-Stufen bzw. 143 h Fortschritt seit dem 26.09.
- Alle Berufsskills (Kräuter Median 75, Erste Hilfe 54 Bots über 75) und der Questverlauf gehen verloren.
- Das laufende 7-Tage- und Welle-2-Fenster wird abgebrochen.
- Weltstopp, Cold-Backup, rund 105 min Login-Wellen.

**Neuer Defekt:** `reset-l1.sql` löscht die Urkunden-Items, lässt `petition` und `petition_sign` aber stehen. So entstanden die 18 Waisen. Ein Vollreset jetzt würde die übrigen verwaisen lassen, und 39 Roster-Bots könnten nie wieder eine Urkunde kaufen. Gildenmitgliedschaft und -leitung behandelt das Skript ebenfalls nicht (UNSICHER).

**Nutzen ohne Reset:** Die Effizienz lässt sich auch ohne Reset messen: in gleich langen Fenstern ab v24/v25, mit der Welle-2-Kohorte (startet ohnehin auf L1) oder mit einem kleinen Kohorten-Reset (`--ordinals`, 20–40 Bots).

**Empfehlung: jetzt kein Reset.** Frühestens nach ≥ 24 h Messung von 8.11 plus PR-1/PR-2, im Hauptzug-Fenster. Vorbedingungen: `reset-l1.sql` behandelt Petitionen und Gilden, die Urkunden sind bereinigt, Einzelfreigabe liegt vor.

---

## 7. Entscheidungen für den Inhaber

Jeweils mit Empfehlung:

1. **Gilden:**
   - `BotsPerGuild` **45** (2×45 je Fraktion) oder 30.
   - Rollen-Soll 6/10/29 (live) oder 5/10/30 (Vertrag).
2. **Namensliste** (5.1) freigeben oder einzelne Namen ersetzen. Ohne freigegebene Liste gründen Bots im neuen Pfad nicht.
3. **Urkunden:**
   - kein Verfall im Spiel; nach den Gründungen DB-Job durch OB-40 für alle Nicht-Gründer-Urkunden einschließlich der Waisen;
   - bis PR-5 aktiv ist, Rang 7 (OB-00).
4. **Spielergründung und Abwerben:** Core-Hook in Zug 10 nach den Regeln in 5.1, oder eine Reserve gildenloser Bots.
5. **Gildenchat:** höchstens 4 Zeilen je Gilde und Stunde, nur mit echtem Mitglied online.
6. **Leichenlauf in Gruppen, Zeitwerte:** 75 s / 60 yd / 1.500 yd / 300 s / 180 s / 2 Wipes in 30 min / 60 min Sperre.
7. **Questen:**
   - (a) Park 3/3600/3600: ja.
   - (b) Kontinent-Questreisen bis #342 sperren: ja, nur zusammen mit PR-1.
   - (c) Grau-Politik zunächst nach 8.11, A/B-Test später.
   - (d) Fertige Quests nur aufgeben, wenn sie grau sind und ihr Abgeber nur per Skript erscheint oder in einer Instanz steht, und das erst nach 3 Parks.
   - (e) QuestRescue nur auf den eigenen Kontinent.
   - (f) Quest-Items zunächst per Whitelist.
8. **Herstellung:**
   - item-Cheat für Roster-Bots behalten; nur die Herstellung prüft echte Reagenzien.
   - Händler-Reagenzien bis 1 Stapel aus dem tradeskill-Budget; `ReagentKeepStacks=1`; 30 min Sperre nach Fehlschlag.
   - Verbrauchsgüter (Verbände, Tränke) für Roster-Bots freigeben?
9. **Angeln und Kochen:** Fisch behalten und kochen, sobald Kochen umgesetzt ist, sonst verkaufen; eigene Lagerfeuer erlaubt; Angeln als Lückenfüller; Level-Marge der Angelplätze +5.
10. **Sammeln:**
    - Werkzeug (Spitzhacke, Messer) beim Lernen zum Händlerpreis bereitstellen, auch rückwirkend für 3 Bergleute und 4 Kürschner.
    - Trainerreise am Cap bis 800 y auf derselben Karte.
    - Erste Hilfe über 150 vorerst nicht.
11. **Bot-Reset:** jetzt nicht (Abschnitt 6).
12. **Dungeon Phase 1:** Ragefire mit dem Inhaber, Termin offen.

---

## 8. Offene Punkte

- **Kontinentreisen:** Warum Cross-Map-Routen nie ankommen, ist offen (MoveTo bzw. Transport, #342).
- **Stall-Schleifen in Städten** (Sturmwind 1416/1323/5413, Unterstadt 4556, Orgrimmar 15700): mmaps, Aufzug oder Tram? Klärung im Test-Realm.
- **Restrisiken Gilden:**
  - Der Core ändert Signaturlisten ohne Lock, PR-5 liest deshalb nur Kopien unter dem Petition-Mutex.
  - Wie der ACE-Ini-Parser Namenslisten mit Kommas behandelt, ist mit dem bestehenden Listen-Muster umgesetzt, aber erst nach Deploy belegt.
- **Urkunden-Zerstörung:** Nur per Korrelation belegt; ein Destroy-Trace für Item 5863 ist vorgeschlagen.
- **Messungen nach Deploy:** v25 als neue Basis; die Wirkung von PR-1 ist nur geschätzt.
- **8.11:** Bei der Annahme-Messung klären, ob ConfirmQuestAction, UseQuestGiverItem und GuildAcceptQuestOrderAction abgedeckt sind.

---

## 9. Issue-Vorschläge (nicht angelegt)

Format wie `docs/issues`. Titel ≤ 70 Zeichen. Vor dem Anlegen nach Dubletten suchen (#405, #422/#472, #441, #324/#365).

```yaml
---
id: WS10-QUEST-TURNIN-PARK-01
title: "WS10-QUEST-TURNIN-PARK-01: Park turn-ins that keep failing"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; core PR cli485/turnin-park"
superseded_by: none
body: |
  Vertrag: PR-1 mergen, Profil 3/3600/3600. Abnahme im gleichen 160-min-Fenster:
  gebundene Zeit < 25 %, Bots ohne XP < 20, XP >= 650/Bot-h, 0 verlorene Bots,
  Minuten-p99 <= 140 ms. Owner chat: OB-10. Refs #485.
---
id: WS10-QUEST-TAKER-USABLE-01
title: "WS10-QUEST-TAKER-USABLE-01: No unusable quest takers as targets"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; core PR cli485/unusable-takers"
superseded_by: none
body: |
  Vertrag: PR-2 mergen, SkipScriptOnlyQuestTakers=1, CrossMapContinentsOnly=1 mit
  MinLevelForCrossMapQuestRoute=61 bis #342. Abnahme: 0 Ankünfte an GO 270,
  0 Wahlen nach RFC für 5722. Owner chat: OB-10. Refs #485, #342.
---
id: WS10-SKIN-CHAIN-01
title: "WS10-SKIN-CHAIN-01: Skinners clear their corpse, keep skin loot"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485, #471; core PR cli485/skin-chain"
superseded_by: none
body: |
  Vertrag: PR-3 mergen, ClearCorpseForSkinning=1. Abnahme: >= 3 Häutungen/h,
  Kürschnern >= 10 Skill/Tag (OB-40). Owner chat: OB-10. Refs #485, #471.
---
id: WS10-CRAFT-REAL-REAGENTS-01
title: "WS10-CRAFT-REAL-REAGENTS-01: Craft with real reagents"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485, #333; core PR cli485/craft-reagents"
superseded_by: none
body: |
  Vertrag: PR-4 mergen, RealReagents=1, KeepCraftMaterials=1, VendorReagents-Liste.
  Abnahme: Alchemie > 1 bei >= 5 Bots nach 24 h, failed < 10 %, Phiolen gekauft.
  Owner chat: OB-10. Refs #485, #333.
---
id: WS10-GUILD-FOUNDATION-01
title: "WS10-GUILD-FOUNDATION-01: Roster bots found capped guilds"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; core PR cli485/guild-foundation"
superseded_by: none
body: |
  Vertrag: PR-5 mergen, BotsPerGuild und Namen nach Inhaberentscheid, vorher Rang 7.
  Abnahme: Gilden je Fraktion = Ziel in 48 h, 0 Petition-SQL, Umzüge ~ 0.
  Owner chat: OB-10. Refs #485.
---
id: WS10-ADHOC-LEAVE-02
title: "WS10-ADHOC-LEAVE-02: Ad-hoc self leave works, single leave path"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; AdhocGroupAction.cpp:201, LeaveGroupAction.cpp:68,123"
superseded_by: none
body: |
  Vertrag: GD-1. Abnahme: >= 95 % der eigenen Austritte in <= 15 s, keine
  Wiederholzeilen. Owner chat: OB-10. Refs #485, #365, #324.
---
id: WS10-COMBAT-RESCUE-01
title: "WS10-COMBAT-RESCUE-01: Rescue bots stuck in endless combat"
workstream: WS-10
priority: p1
existing_ot: none
source: "#485; Bot 27 zone 5561 combat=1 since v24"
superseded_by: none
body: |
  Vertrag: Rang 11 (Hotfix). Abnahme: 0 Bots > 30 min mit combat=1 ohne
  Schaden/XP; D2 eingehalten. Owner chat: OB-10. Refs #485.
---
id: WS40-CONFIG-EVIDENCE-01
title: "WS40-CONFIG-EVIDENCE-01: Store rendered configs per deploy"
workstream: WS-40
priority: p2
existing_ot: none
source: "#485"
superseded_by: none
body: |
  Vertrag: Pro Deploy die gerenderten aiplayerbot.conf und mangosd.conf (Secrets
  geschwärzt) mit sha256 unter evidence/ws-40/ablegen. Owner chat: OB-30. Refs #485.
---
```

Weitere Kandidaten ohne Block: Rang 9, 10, 12–28. Sie werden als Issues angelegt, sobald OB-10 die Reihenfolge festlegt.
