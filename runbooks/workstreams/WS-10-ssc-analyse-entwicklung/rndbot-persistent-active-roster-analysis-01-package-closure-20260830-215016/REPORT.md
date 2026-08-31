# RNDBOT-PERSISTENT-ACTIVE-ROSTER-ANALYSIS-01

## Entscheidung

`RNDBOT_PERSISTENT_ROSTER_ANALYSIS=PASS`

Die Ursache und der erforderliche Lösungsweg sind auf dem freigegebenen Baseline-Commit vollständig nachvollziehbar. Der aktuelle Mechanismus besitzt **keinen persistenten aktiven GUID-Roster**. Er benutzt zeitlich ablaufende `add`-Events in `ai_playerbot_random_bots` zugleich als Auswahlmenge und Login-Lease. Nach Ablauf entfernt `RandomPlayerbotMgr::ProcessBot` die GUID aus `currentBots`, löscht das `add`-Event und loggt den Bot aus. Der nächste Auffülllauf wählt anhand einer pro Lauf gemischten Accountreihenfolge, einer ungeordneten Charakterabfrage und Klassen-/Rassenquoten neu aus. `MinRandomBots=50` und `MaxRandomBots=50` halten daher nur die Zielanzahl bei 50; sie fixieren keine Identitäten.

Die spätere Umsetzung benötigt eine neue, versionierte und GUID-basierte Soll-Roster-Persistenz, eine strikte Trennung von Sollbestand und Onlinezustand sowie gezielte Source-, Config- und Character-DB-Änderungen. Die vorhandenen `PinnedBots`, `always`-Events und `add`-Rows erfüllen den Vertrag nicht.

## Scope und Baseline

- Analysemodus: ausschließlich offline/read-only gegenüber Source, Git, Config und vorhandener Evidenz.
- Repository: `C:\TW\ComTW\source`
- Commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Tree: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`
- Aktive Config: `C:\TW\ComTW\server\aiplayerbot.conf`
- Config SHA-256: `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`
- Die untersuchten RNDBOT-Dateien sind im vorhandenen Dirty-Tree unverändert. Die bereits vorgefundenen Änderungen betreffen vier LLM/Build-Dateien und sechs unversionierte PDB-Dateien; sie wurden weder verändert noch bereinigt.
- Keine Datenbankabfrage, kein Server-/Prozesszugriff und keine Config- oder Sourceänderung wurde durchgeführt.
- Die stabile Laufzeitevidenz `SSC-SOURCE-BASELINE-02C-R1-PASS-20260830-010122.zip` wurde erneut verifiziert: ZIP SHA-256 `BCACFFB731B9D3C6B5446993B0DC80DA4FC50E15B2034795A990CEA60FDCB6AB`, Größe `7806779`, acht interne Manifest-Einträge vollständig passend.

## Effektive Konfiguration

Auskommentierte Werte sind nicht aktiv; dann gilt der Default aus `PlayerbotAIConfig.cpp`.

| Einstellung | Effektiver Wert | Bedeutung |
|---|---:|---|
| `AiPlayerbot.RandomBotAutologin` | `1` | aktiviert den RNDBOT-Manager und dessen Login-/Rotationspfad |
| `AiPlayerbot.RandomBotLoginAtStartup` | `1`, aber ohne Verbraucher | wird geladen, im Kandidaten-Source danach nicht verwendet |
| `AiPlayerbot.RandomBotAutoCreate` | `1` | darf beim Start RNDBOT-Accounts/Charaktere ergänzen; Factory führt außerdem Löschmarker aus |
| `AiPlayerbot.MinRandomBots` | `50` | untere Zielanzahl, keine Identitätsfixierung |
| `AiPlayerbot.MaxRandomBots` | `50` | obere Zielanzahl, keine Identitätsfixierung |
| `AiPlayerbot.RandomBotTimedLogout` | `true` (Default) | abgelaufenes `add`-Event macht einen Bot ungültig |
| `AiPlayerbot.RandomBotTimedOffline` | `false` (Default) | nach Logout wird derzeit normalerweise keine Offline-Sperrfrist erzeugt |
| `AiPlayerbot.MinRandomBotInWorldTime` | `1800 s` (Code-Default) | Untergrenze der `add`-Lease |
| `AiPlayerbot.MaxRandomBotInWorldTime` | `21600 s` (Code-Default) | Obergrenze der `add`-Lease |
| `AiPlayerbot.RandomBotCountChangeMinInterval` | `1800 s` | Untergrenze der `bot_count`-Gültigkeit |
| `AiPlayerbot.RandomBotCountChangeMaxInterval` | `7200 s` | Obergrenze der `bot_count`-Gültigkeit |
| `AiPlayerbot.RandomBotUpdateInterval` | `500 ms` | Manager-Intervall |
| `AiPlayerbot.RandomBotsMaxLoginsPerInterval` | `30` | begrenzt Loginversuche pro Intervall, nicht den Soll-Roster |
| `AiPlayerbot.RandomBotsPerInterval` | `0` (Default) | unbegrenzte Zahl von Roster-/Maintenance-Prüfungen pro Intervall |
| `AiPlayerbot.AsyncBotLogin` | `0` | aktuell synchroner Pfad; der asynchrone Pfad muss trotzdem für einen späteren Modus abgesichert werden |
| `AiPlayerbot.RandomBotLoginWithPlayer` | `false` (Default) | aktueller Betrieb hängt RNDBOTs nicht von realen Spielern ab |
| `AiPlayerbot.DisableRandomLevels` | `1` | verhindert im normalen Managerpfad Level-Neurandomisierung, nicht die Identitätsrotation |
| `AiPlayerbot.EnableRandomTeleports` | `true` (Default) | kann denselben Bot versetzen; ist keine Identitätsrotation |
| `AiPlayerbot.PinnedBots` | leer | kein aktiver Pin; vorhandene Implementierung ist zudem kein persistenter GUID-Roster |
| `AiPlayerbot.DefaultLoginCriteria` | `maxbots,spareroom,offline` (Default) | asynchrone Auswahl-/Abmeldekriterien |
| `AiPlayerbot.LoginCriteria.*` | Source-Defaults | gruppiert, Arena, BG und Gilde werden zunächst bevorzugt; spätere Versuche enthalten `logoff` |

Die Kommentare in der aktiven Config nennen für die auskommentierten In-World-Zeiten `3600` und `1209600`, der tatsächlich verwendete Source-Default ist `1800` und `21600`. Maßgeblich ist der Code, weil beide Configschlüssel auskommentiert sind.

## Gegenwärtiger Ablauf und Rotation

```text
Start/Update
  -> GetBots(): alle owner=0/event='add'-Zeilen werden currentBots
  -> add.validIn läuft ab
  -> ProcessBot(): Bot ungültig
  -> bei Gruppe nur neue 120-Sekunden-Lease
  -> danach add löschen + currentBots entfernen + LogoutPlayerBot
  -> availableBotCount < bot_count
  -> AddRandomBots(): Accountreihenfolge mischen, Charaktere ohne ORDER BY lesen
  -> Quotenauswahl + neue add-Lease
  -> eine andere GUID kann den freien Platz übernehmen
```

### Auswahl eines RNDBOT-Charakters

- `RandomPlayerbotMgr::UpdateAIInternal` liest den zeitlich gültigen `bot_count`, erzeugt ihn bei Ablauf/Abweichung neu und vergleicht ihn mit der Größe von `GetBots()` (`RandomPlayerbotMgr.cpp:644-704`). Bei `50/50` bleibt die Anzahl 50, aber der Timer wird weiterhin erneuert.
- `AddRandomBots` mischt die Liste der RNDBOT-Accounts bei jedem Auswahlpass mit `std::shuffle` (`:1195-1208`).
- Die Charakterabfragen haben kein `ORDER BY` (`:1214-1243`).
- Auswahl und Ausschluss berücksichtigen Level, Klasse, Rasse, bestehendes `add`, `logout`, Onlinezustand und `currentBots` (`:1249-1300`).
- Der ausgewählte Charakter erhält `add=1` mit einer zufälligen Laufzeit von effektiv 1800 bis 21600 Sekunden (`:1298-1300`).

Folge: Weder Reihenfolge noch Identität sind deterministisch. Das Ziel `50` beschreibt eine Anzahl, nicht dieselben 50 GUIDs.

### Persistente Roster-Mitgliedschaft

Nicht vorhanden. `GetBots()` lädt `SELECT bot ... event='add'` ohne `DISTINCT` und ohne `ORDER BY` in eine In-Memory-Liste (`RandomPlayerbotMgr.cpp:3456-3473`). Die Tabelle besitzt nur einen Auto-ID-Primary-Key und nicht eindeutige Indizes; auch der zusammengesetzte Index `(owner,bot,event)` ist nicht eindeutig. Doppelte `add`-Zeilen sind daher strukturell möglich, können den Zähler aufblasen und werden beim Laden nicht als Fehler erkannt.

### Loginsteuerung

- Im aktiven synchronen Pfad verarbeitet `UpdateAIInternal` Offline-GUIDs aus der `add`-Liste bis Zielanzahl und Loginlimit (`:742-770`).
- `AddRandomBot` validiert den RNDBOT-Account, beseitigt einen stale `login`-Marker, startet `AddPlayerBot`, setzt anschließend `add`, `login` und `update` und hängt die GUID an `currentBots` (`:2232-2282`).
- Bei Loginfehler entfernt `OnPlayerLoginError` ausdrücklich `add`, `login` und die GUID aus `currentBots` (`:3892-3896`); der nächste Top-up kann eine andere GUID einsetzen.
- Der derzeit deaktivierte Async-Pfad lädt alle RNDBOT-Charaktere und entscheidet per Login-Kriterien über Login/Logout (`PlayerbotLoginMgr.cpp:396-457, 502-550, 609-704`). Auch dieser Pfad ist populations- und timergetrieben, nicht rostergetrieben.

### Logoutsteuerung und Rotationsauslöser

- Bei aktiviertem `RandomBotTimedLogout` wird ein abgelaufenes `add` im synchronen Pfad ungültig (`RandomPlayerbotMgr.cpp:2321-2328`).
- Ist der Bot zu diesem Zeitpunkt in einer Gruppe, wird nur eine neue 120-Sekunden-Lease geschrieben (`:2338-2341`). Das ist eine wiederholbare Schonfrist, keine Invariante.
- Andernfalls werden `currentBots` und `add` entfernt und `LogoutPlayerBot` ausgeführt (`:2344-2367`).
- Im Async-Pfad erzeugt `logoff` bei abgelaufenem `add` ein Logoutkriterium (`PlayerbotLoginMgr.cpp:520-529`); der Queue-/Kapazitätsausgleich kann ebenfalls Logouts einreihen (`:609-704`).
- Ein Spielerbefehl `logout` setzt unabhängig von der Rotation `shouldLogOut`, und `PlayerbotHolder::UpdateSessions` führt den Logout aus (`PlayerbotAI.cpp:1587-1607`; `PlayerbotMgr.cpp:333-395`). Ein persistenter Roster muss diesen Befehl für Rosterbots auf ausdrücklich autorisierte administrative Aufrufe begrenzen.

### AI-Aktivitätsdrosselung

`ScaleBotActivity` passt nur den Aktivitätsprozentsatz anhand der World-Diff an (`RandomPlayerbotMgr.cpp:794-872`). `PlayerbotAI::AllowActivity` reduziert mit Prioritätsklassen und einem 5-Sekunden-Cache die AI-Arbeit (`PlayerbotAI.cpp:6226-6370`). Gruppen mit realem Spieler, sichtbare Bots, Instanzen und Kampf erhalten hohe Priorität. Dieser Mechanismus kann unverändert als Performanceinstrument dienen, sofern er weder Soll-Mitgliedschaft noch Loginstatus oder Gruppe verändert.

### Gruppen- und Masterbindung

Es bestehen mehrere voneinander unabhängige Risiken:

1. Die 120-Sekunden-Grace in `ProcessBot` schützt nur solange `botsAllowedInWorld`, ein live auflösbarer `Player*` und `GetGroup()` zugleich wahr sind. Sie ist kein dauerhafter Schutz.
2. Der Quellkommentar in `RandomPlayerbotMgr.h:232-238` dokumentiert bereits einen realen Fehlerfall: Ein extern verwalteter Gruppenbot wurde nach der zweiminütigen Schonfrist durch den Random-Manager entfernt.
3. `RandomizeFirst` ruft für einen Bot ohne realen Master `RemoveFromGroup()` auf (`RandomPlayerbotMgr.cpp:3351-3355`). Im aktiven normalen Pfad wirkt `DisableRandomLevels=1`, doch die Funktion bleibt über andere Pfade erreichbar.
4. Bei normalem Logout eines realen Spielers entfernt `WorldSession::LogoutPlayer` in einer Nicht-Raid-Gruppe zuerst alle nicht auflösbaren beziehungsweise maschinengesteuerten Mitglieder und danach den Spieler (`WorldSession.cpp:802-835`). Das ist eine direkte, separate Bot-Gruppenentfernung.
5. Würde nur die Bot-Eviction entfallen, disbandet `Group::RemoveMember` eine Gruppe mit höchstens zwei Mitgliedern beim Entfernen eines Mitglieds (`Group.cpp:444-524`). Für einen strikten Erhalt einer Zweiergruppe bei Master-Logout muss deshalb der gesamte automatische Gruppenabbau dieses Logoutpfads für Gruppen mit persistentem Rosterbot unterdrückt werden; nur die Eviction-Schleife zu ändern genügt nicht.

Die saubere spätere Lösung ist ein generischer, modulneutraler Script-Veto-Hook am WorldSession-Logout: enthält die Gruppe einen gewünschten Rosterbot, bleibt die Gruppenmitgliedschaft beim normalen Sessionlogout bestehen und der Spieler wird lediglich offline markiert. Zusätzlich dürfen Rotations-, Populations-, `RandomizeFirst`- und nicht-administrative Logoutpfade Rosterbots nicht ausloggen oder aus Gruppen entfernen. Explizites Verlassen/Kicken durch einen Spieler und ausdrücklich autorisierte Roster-Administration müssen als getrennte Policies getestet werden.

### Charakterpersistenz

Level, Ausrüstung, Inventar, Berufe, Quests und übriger Charakterzustand liegen in den normalen Character-DB-Tabellen unter der Charakter-GUID. `LogoutPlayerBot` und `WorldSession::LogoutPlayer` speichern den Charakter. Die heutige Rotation löscht diese Daten normalerweise nicht, sie wechselt lediglich die online geführte GUID. Eine dauerhafte GUID-Liste erhält deshalb den Fortschritt derselben Charaktere.

Automatische Factory-/Delete-Pfade sind davon getrennt: `RandomPlayerbotFactory::CreateRandomBots` wertet beim Start `bot_delete` aus und kann RNDBOT-Charaktere oder Accounts löschen (`RandomPlayerbotFactory.cpp:548-712`). `PlayerbotHolder::DeleteBot` löscht einen Charakter aus der DB (`PlayerbotMgr.cpp:2851-2865`). Eine spätere Rosterimplementierung muss solche Löschungen für gewünschte Roster-GUIDs fail-closed ablehnen, bis ein expliziter, protokollierter Remove-/Replace-Vorgang abgeschlossen ist. Wird eine GUID außerhalb dieser Schutzschicht gelöscht, bleibt sie im Soll-Roster und der Zustand wird `DEGRADED`; sie wird nicht automatisch ersetzt.

## Bedeutung der Eventzeilen

| Event | Erzeuger / Verbraucher | Rolle | Darf künftig Roster-Mitgliedschaft ändern? |
|---|---|---|---|
| `add` | Auswahl, `AddRandomBot`, `ProcessBot`, Async-Login | heutige temporäre Auswahl- und Login-Lease | nein; für persistenten Modus nicht als Mitgliedschaft verwenden |
| `bot_count` | `UpdateAIInternal` | zeitlich gültige Zielanzahl | nein; der persistente Targetwert stammt aus der Roster-Version |
| `current_time` | `SaveCurTime`, `SyncEventTimers` | speichert Serverzeit; beim Start werden Eventzeiten um Downtime verschoben | nein |
| `login` | `AddRandomBot`, `ProcessBot`, Konstruktor, Login-Hooks | Login-in-progress/stale marker | nein |
| `logout` | Timed-offline und Auswahlprüfung | optionale Offline-Cooldown | nein |
| `update` | Login und `ProcessBot` | kurze Maintenance-/Revive-Taktung | nein |
| `teleport` | `ScheduleTeleport`, Maintenance | Zeitpunkt einer Weltversetzung derselben GUID | nein |
| `change_strategy` | Schedule/Maintenance | Strategiewechsel derselben GUID | nein |
| `randomize` | Randomize-/Gearpfade | Character-Maintenance derselben GUID | nein |
| `always` | Free-alt/selfbot-Verwaltung | Always-online-Status für Nicht-RNDBOT-Free-Alts | nein; RNDBOT-Accounts werden beim Laden ausdrücklich ausgeschlossen |
| `temporary` | temporäre Bot-Factory | temporärer Charakter-Lifecycle | nein; gewünschte Rosterbots dürfen nie in diesen Pfad fallen |
| `bot_delete` | manuelle SQL-Skripte und Factory-Start | destruktiver RNDBOT-Löschauftrag | nein; Roster-Mitglieder müssen vor Ausführung geschützt werden |

`GetEventValue` setzt abgelaufene Werte auf null, ausgenommen `specNo`, `specLink`, `init`, `current_time`, `always` und `selfbot` (`RandomPlayerbotMgr.cpp:3496-3531`). `add` ist nicht ausgenommen. `SyncEventTimers` verschiebt beim Start alle Bot-Eventzeiten um die Downtime (`:2112-2128`); Timer pausieren dadurch über einen Neustart, werden aber nicht zu dauerhafter Mitgliedschaft.

## Schreib- und Löschpfade auf `ai_playerbot_random_bots`

- `RandomPlayerbotMgr::SyncEventTimers`: `UPDATE ... SET time=time+...` für alle Bot-Events.
- `RandomPlayerbotMgr::SetEventValue`: `DELETE` der vorhandenen Owner/Bot/Event-Zeilen, danach bei Wert ungleich null `INSERT` einer neuen Zeile (`RandomPlayerbotMgr.cpp:3558-3580`). Außerhalb eines umgebenden Transaktionspfads sind das getrennte Statements; die Tabelle erzwingt keine Eindeutigkeit.
- `RandomPlayerbotMgr::Remove`: `DELETE` aller Events für eine GUID und Logout (`:4290-4301`).
- `RandomPlayerbotMgr::HandleConsoleReset`: löscht alle nicht-temporären Events (`:4715-4721`).
- `RandomPlayerbotFactory`: löscht Orphan-Events, Events temporärer Bots und alle `temporary`-Zeilen (`RandomPlayerbotFactory.cpp:684, 702, 712`).
- `sql/other/delete_randombots.sql` und `delete_all_randombots.sql`: ersetzen den `bot_delete`-Marker.
- `sql/other/database_merge_{classic,tbc,wotlk}.sql`: kopieren die komplette Tabelle.
- `sql/other/reset_randombots.sql`: erstellt die Tabelle neu.
- `sql/tools/playerbot_fix_collation.sql` und `sql/character_updates/20260708055500_ai_playerbot_random_bots_index.sql`: Schemaänderungen, kein Laufzeit-Rostervertrag.

Die vollständige maschinenlesbare Fundstellenliste steht in `evidence/SOURCE-MATRIX.tsv`.

## Vorhandene Persistenz-, Pin- und Always-online-Funktionen

### `add` und `currentBots`

Das sind die aktuelle Rotationsmenge und ein In-Memory-Cache, kein Soll-Roster. Ablauf, Loginfehler, Reset und Delete entfernen Mitglieder automatisch.

### `PinnedBots`

- Config akzeptiert Namen, keine GUIDs (`PlayerbotAIConfig.cpp:294-307`).
- Namen werden einmalig per DB-Abfrage in ein In-Memory-Set aufgelöst (`RandomPlayerbotMgr.cpp:2173-2200`).
- `EnsurePinnedBotsOnline` wird nur innerhalb des Top-up-Blocks aufgerufen, wenn die aktuelle `add`-Anzahl unter dem Ziel liegt (`:691-704, 2203-2215`). Bei voller Zielanzahl kann ein fehlender Pin unbeachtet bleiben.
- `AddRandomBot` erzeugt auch für Pins eine zeitlich begrenzte `add`-Lease.
- Der Timed-Logoutpfad prüft `IsPinnedBot` nicht.
- Der Pin schützt nur einen späteren Relocation-Pfad (`:2489-2494`).

Damit widerspricht die Implementierung dem Kommentar „kept logged in“ und eignet sich nicht als Vertragsbasis.

### `always`

`ToggleAlwaysOnlineAccounts`, `ToggleAlwaysOnlineChars` und das `always`-Event gelten für Free-Alt-/Selfbot-Verwaltung. `loadFreeAltBotAccounts` schließt Konten mit RNDBOT-Präfix ausdrücklich aus (`PlayerbotAIConfig.cpp:1009-1064`).

### Extern verwaltete GUIDs

`m_externallyManaged` schützt eine Testharness-GUID vor dem Random-Manager, ist jedoch nur ein flüchtiges In-Memory-Set eines externen Besitzers. Es ist kein versionierter Produktionsroster.

## Vorgeschlagenes persistentes Speichermodell

Eine neue Character-DB-Migration soll vier getrennte Tabellen anlegen; `ai_playerbot_random_bots` bleibt ausschließlich Event-/Maintenance-Speicher.

### `ai_playerbot_active_roster_version`

- `version_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY`
- `previous_version_id BIGINT UNSIGNED NULL`
- `operation_id CHAR(36) CHARACTER SET ascii NOT NULL UNIQUE`
- `operation_type` mit geschlossener Menge `INITIALIZE`, `EXPAND`, `ADD`, `REMOVE`, `REPLACE`, `ROLLBACK`
- `target_count INT UNSIGNED NOT NULL`
- `actor`, `reason`, `created_utc`
- `before_sha256 BINARY(32)`, `after_sha256 BINARY(32)` über eine kanonische, ordinal sortierte GUID-Liste

### `ai_playerbot_active_roster_member`

- `version_id BIGINT UNSIGNED NOT NULL`
- `ordinal INT UNSIGNED NOT NULL`
- `bot_guid INT UNSIGNED NOT NULL`
- `PRIMARY KEY(version_id, ordinal)`
- `UNIQUE(version_id, bot_guid)`
- FK nur auf die unveränderliche Version mit `ON DELETE RESTRICT`
- bewusst **kein** FK auf `characters.guid`: eine gelöschte oder vorübergehend fehlende GUID muss als Soll-Evidenz erhalten bleiben und `DEGRADED` erzeugen, nicht per Cascade verschwinden

### `ai_playerbot_active_roster_current` und Change-Audit

- Singleton-Pointer `id=1, current_version_id` auf die freigegebene immutable Version.
- Separate Change-Tabelle je Version mit `change_type`, betroffener GUID, optional ersetzter GUID und altem/neuem Ordinal. Damit sind betroffene GUIDs direkt und nicht nur als Snapshot-Diff protokolliert.

### Transaktions- und Idempotenzvertrag

Jeder administrative Vorgang muss:

1. eine neue kanonische UUID als `operation_id` erhalten;
2. Transaktion starten und den Singleton-Pointer `FOR UPDATE` sperren;
3. bei bereits vorhandener `operation_id` das gespeicherte identische Ergebnis zurückgeben, bei abweichendem Payload fail-closed abbrechen;
4. die aktuelle Version vollständig in `ordinal`-Reihenfolge laden und Hash/Ziel/Unique-Invarianten prüfen;
5. den expliziten Delta-Vorgang anwenden;
6. bei Expansion den alten Vektor bytegenau als Präfix bewahren und ausschließlich neue, validierte, eindeutige GUIDs anhängen;
7. Header, vollständigen neuen Snapshot und Change-Audit einfügen;
8. Zielanzahl, lückenlose Ordinals, Eindeutigkeit und SHA-256 erneut prüfen;
9. den Current-Pointer mit erwarteter Altversion aktualisieren und committen.

Bei irgendeinem Fehler erfolgt Rollback ohne Teiländerung. Ein Rollback ist selbst eine neue auditierte Version, die einen früheren Snapshot reproduziert; alte Versionen werden nie gelöscht oder überschrieben. Das liefert Vorher-/Nachher-Sicherung, überprüfbare Wiederherstellung und Idempotenz.

Character- und Login-DB können nicht in einer gemeinsamen atomaren Transaktion validiert werden. Account-/Ban-/Lock-Prüfungen sind daher Preflight plus erneute Laufzeitvalidierung. Das ändert die Soll-GUID nicht.

## Laufzeitmodell

Der Service hält vier voneinander getrennte Wertdatenstrukturen:

- `desiredRoster`: immutable GUID-Vektor der aktuellen DB-Version in festem Ordinal;
- `availability`: pro Soll-GUID `AVAILABLE` oder ein genauer Grund wie `CHARACTER_MISSING`, `ACCOUNT_MISSING`, `ACCOUNT_BANNED`, `NOT_RNDBOT_ACCOUNT`, `DUPLICATE`, `LOGIN_ERROR`;
- `onlineRoster`: Schnittmenge der gewünschten GUIDs mit tatsächlich online und gültig geladenen Bots;
- `rosterState`: `HEALTHY` nur bei vollständig gültigem und online erreichtem Soll, sonst `DEGRADED` beziehungsweise bei ungültiger Version fail-closed.

Startablauf:

1. aktuelle Version konsistent laden und Target, Anzahl, Ordinals, GUID-Eindeutigkeit und Hash prüfen;
2. jede GUID gegen Charakter und RNDBOT-Account validieren;
3. ausschließlich diese verfügbaren GUIDs deterministisch in Ordinalreihenfolge einloggen;
4. Loginfehler an derselben GUID protokollieren, Soll-Mitgliedschaft unverändert lassen und keinen Ersatz auswählen;
5. `AddRandomBots` und Async-Login-Kriterien dürfen im persistenten Modus keine Identitäten wählen oder abmelden;
6. normaler Shutdown loggt Sessions aus, löscht aber nie Soll-Rosterzeilen.

Beispiel des vorgeschriebenen fehlenden Mitglieds:

```text
ROSTER_TARGET=50
ROSTER_AVAILABLE=49
ROSTER_ONLINE=49
ROSTER_STATE=DEGRADED
AUTOMATIC_REPLACEMENT=NO
```

Gelöschte Charaktere, Accountfehler oder Bans führen genau zu diesem Prinzip. Doppelte GUIDs in einer Version sind durch die DB-Unique-Regel verhindert; werden sie durch Alt-/manuelle Daten dennoch beobachtet, ist die Version ungültig und fail-closed/degraded. Es gibt kein stilles Deduplizieren und kein Top-up.

## Append-only-Erweiterung und Administration

- Initialisierung: ein ausdrücklich autorisierter Adminvorgang erfasst einmalig exakt 50 GUIDs, beispielsweise die kontrolliert erfasste aktuelle 50er-Menge. Erst dieser Commit bildet die dauerhafte Sollmenge.
- `50 -> 100`: neue Version mit exakt demselben Präfix der alten 50 GUIDs in identischer Reihenfolge plus genau 50 neue GUIDs. Sind nicht alle 50 validierbar, wird die gesamte Transaktion abgebrochen.
- Add/Remove/Replace: nur explizite administrative Befehle mit Operation-ID, Actor, Reason, Vorher-/Nachher-Hash und GUID-Deltalog. Kein Timer, Loginfehler oder Populationsalgorithmus darf sie aufrufen.
- Replace nennt zwingend alte und neue GUID; Remove reduziert den Targetwert ausdrücklich; eine fehlende GUID wird nicht implizit als Remove behandelt.
- Wiederholte identische Operation ist idempotent. Gleiche Operation-ID mit anderem Inhalt ist ein Fehler.
- Jeder Vorgang erzeugt einen vollständigen immutable Snapshot; dadurch sind Backup, Vergleich und auditierter Rollback möglich.

## Abgrenzung von `validIn` und organischem Botverhalten

`validIn` darf weiter Laufzeit-/Maintenancezustände für `update`, `teleport`, `change_strategy`, `randomize`, Cooldowns und Diagnostics beschreiben. Es darf niemals `desiredRoster` verändern. `bot_count` wird im persistenten Modus nicht als Identitätsquelle verwendet.

Autonome Bewegung, Quests, Kämpfe, Gruppenrollen, AI-Ticks und zulässige Maintenance bleiben bestehen. Performance-Drosselung darf lediglich AI-Arbeit verzögern. Sie darf keinen Rosterbot ausloggen, ersetzen, aus einer Gruppe entfernen oder aus dem Sollbestand löschen.

Bei gleicher Onlineanzahl ist die Basiskostenstruktur für Sessions, Maps, Movement und AI ungefähr gleich wie heute. Stabile Identität reduziert eher Login-/Logout-Spitzen, DB-Saves, Charakterloads, Neuinitialisierung und Gruppenchurn. Eine dauerhaft online gehaltene 50er-Menge verbraucht weiterhin Speicher und minimale Tickzeit; `ScaleBotActivity`, `AllowActivity` und `RandomBotsPerInterval` bleiben geeignete, identitätsneutrale Stellschrauben.

## Erforderliche spätere Änderungen

### Source

- `src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp/.h`: Roster-Repository/-State, Start-Load, exakte Loginmenge, kein `add`-Ablauf als Mitgliedschaft, kein Top-up-Ersatz, Status/DEGRADED, Schutz von Logout/Remove/Reset/RandomizeFirst.
- `src/modules/PlayerBots/playerbot/PlayerbotLoginMgr.cpp/.h`: im Async-Modus nur exakte Soll-GUIDs; keine populationsbasierte Abmeldung von Rosterbots.
- `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp/.h` und `aiplayerbot.conf.dist.in`: opt-in `AiPlayerbot.PersistentActiveRoster.Enabled`; fail-closed, wenn aktiviert aber keine gültige aktuelle Version existiert. Der Targetwert bleibt in der DB-Version, nicht in einer konkurrierenden Configliste.
- `src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp`: Startup/World-Update, Status und der modulare Gruppenerhalt-Hook.
- `src/modules/PlayerBots/playerbot/RandomPlayerbotFactory.cpp`: automatische Account-/Character-Löschung für gewünschte GUIDs sperren.
- `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp/.h` und die vorhandene Commandregistrierung: explizite `initialize/expand/add/remove/replace/rollback/status`-Administration; gewöhnliches `logout` für Rosterbots nicht als implizite Bestandsoperation akzeptieren.
- `src/game/WorldSession.cpp`, `src/game/ScriptObjects.h`, `src/game/ScriptMgr.h/.cpp`: generischer Hook, der den automatischen kompletten Gruppenabbau beim normalen Spielerlogout für Gruppen mit persistentem Rosterbot vetoen kann, ohne den Core vom PlayerBots-Modul abhängig zu machen.
- `src/game/Group/Group.cpp` muss im Testumfang enthalten sein. Bei Veto des gesamten WorldSession-Blocks ist keine direkte Änderung zwingend; ein bloßes Überspringen der Bot-Eviction wäre wegen des Zweiergruppen-Disbands unzureichend.
- neue unit-/integrationnahe Tests unter dem bestehenden PlayerBots-Testaufbau für Persistenz, Neustartidentität, Timerablauf, Gruppenpfade, fehlende GUIDs, Duplikate, Accountfehler, Idempotenz, Transaktionsrollback und Append-only-Prefix.

### Datenbank

Neue Character-DB-Migration für die versionierten Roster-, Member-, Current- und Change-Audit-Tabellen. Bestehende `ai_playerbot_random_bots`-Zeilen werden nicht zur permanenten Mitgliedschaft umgedeutet.

### Config

Neue explizite Enable-Option, standardmäßig aus/fail-closed. Die spätere aktive Configänderung ist ein eigenes Gate und gehört nicht zu dieser Analyse.

## Abnahmetestplan für die spätere Umsetzung

1. Initialisierung erzeugt exakt 50 eindeutige GUIDs und einen verifizierten Snapshot-Hash.
2. Vor Shutdown: gewünschte, verfügbare und online GUID-Mengen getrennt erfassen.
3. Nach Neustart: dieselbe Roster-Version und exakt dieselbe gewünschte 50er-Menge; bei vollständiger Verfügbarkeit auch dieselbe Online-50er-Menge.
4. Alle früheren `add`, `bot_count`, `update`, `teleport`, `randomize` und Login-Kriterien über ihre maximalen Zeitfenster laufen lassen; gewünschte GUID-Menge bleibt bytegleich.
5. Gruppenbot über den alten `add`-Ablauf hinaus beobachten; kein rotationsbedingter Logout und keine Gruppenentfernung.
6. Realen Master normal ausloggen; für die beschlossene strikte Policy bleibt die Gruppe über den Veto-Hook erhalten und der Rosterbot online.
7. Eine Soll-GUID künstlich nicht verfügbar machen: `50/49/49/DEGRADED`, kein Ersatz.
8. Expansion auf 100: alte 50 bilden exakt das unveränderte Präfix, neue 50 sind eindeutig und nur angehängt.
9. Wiederholung derselben Operation-ID liefert dasselbe Ergebnis; gleiche ID mit anderem Payload schlägt fehl.
10. Fehler in der Mitte einer Admintransaktion hinterlässt Current-Pointer und alten Snapshot unverändert.
11. Explicit Remove/Replace protokolliert Actor, Reason, betroffene GUIDs sowie Vorher-/Nachher-Hash; Rollback erzeugt eine neue Version.
12. Performancevergleich bei gleicher Onlinezahl: Tickzeit, aktive AI-Anteile, Login-/Logoutanzahl, DB-Saves und Startlatenz; Identitätsstabilität wird unabhängig von AI-Vollaktivität geprüft.

## Risiken und offene Implementierungsentscheidungen

- Die Initialmenge von 50 GUIDs existiert noch nicht als Soll-Evidenz und muss in einem separaten autorisierten Initialisierungsgate festgelegt werden.
- Character- und Login-DB-Validierung ist nicht atomar über beide Datenbanken; Laufzeit-DEGRADED bleibt zwingend.
- Das Beibehalten einer Gruppe beim normalen Masterlogout ändert die derzeit ausdrücklich programmierte Cleanup-Semantik. Es benötigt gezielte Tests für Zweiergruppen, Offline-Leader, LFG, Instanzen, Raids, Server-Shutdown und erneuten Login.
- Administrative Delete-/Reset-/Factory-Pfade dürfen Rosterinvarianten nicht umgehen. Direkte externe SQL-Eingriffe können Source-Schutz umgehen und müssen als Betriebsverstoß erkannt werden.
- Der existierende Dirty-Tree enthält historische LLM-/Debugänderungen. Eine spätere Umsetzung muss wieder in einem isolierten Worktree auf dem freigegebenen Commit erfolgen.
- `PinnedBots` und `RandomBotLoginAtStartup` enthalten dokumentarische/operative Widersprüche; sie dürfen nicht als Beweis für persistentes Verhalten verwendet werden.

## Ergebnisblock

```text
RNDBOT_PERSISTENT_ROSTER_ANALYSIS=PASS
CURRENT_SELECTION_MECHANISM=Timed add-event rotation; target count from bot_count; per-pass shuffled RNDBOT accounts; unordered character queries; class/race/level filters; non-persistent currentBots cache
ROTATION_TRIGGER=add.validIn expiry with RandomBotTimedLogout; ProcessBot/async logoff clears membership and logout; target deficit invokes random reselection
GROUPED_BOT_LOGOUT_ROOT_CAUSE=Only a renewable 120-second group grace protects expired add leases; no persistent-roster invariant exists; separate WorldSession normal-logout code evicts machine-driven group members, and RandomizeFirst can remove an unmastered grouped bot
VALIDIN_ROLE=Wall-clock event lease/maintenance interval, paused across server downtime by SyncEventTimers; it must never define or terminate desired-roster membership
EXISTING_PERSISTENCE_MECHANISM=ai_playerbot_random_bots event rows plus currentBots cache; PinnedBots is name-based/in-memory and incomplete; always excludes RNDBOT accounts; no durable versioned GUID roster exists
PROPOSED_ROSTER_STORAGE=Character-DB immutable version snapshots plus unique ordered GUID members, singleton current-version pointer, explicit change audit, operation UUID idempotency, SHA-256 before/after hashes, transactional CAS, and no FK/cascade to characters.guid
DATABASE_MIGRATION_REQUIRED=YES
SOURCE_CHANGE_REQUIRED=YES
CONFIG_CHANGE_REQUIRED=YES
AUTOMATIC_REPLACEMENT_ALLOWED=NO
APPEND_ONLY_EXPANSION_POSSIBLE=YES
GROUPED_BOT_PROTECTION=Roster GUIDs bypass timer/population logout and RandomizeFirst removal; async criteria cannot log them off; a module-neutral WorldSession veto preserves the complete group on normal master logout; explicit administrative policy remains separate
IMPLEMENTATION_FILES=src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp/.h; PlayerbotLoginMgr.cpp/.h; PlayerbotAIConfig.cpp/.h; PlayerbotScripts.cpp; RandomPlayerbotFactory.cpp; PlayerbotMgr.cpp/.h; aiplayerbot.conf.dist.in; src/game/WorldSession.cpp; src/game/ScriptObjects.h; src/game/ScriptMgr.h/.cpp; tests; new sql/character_updates migration
IMPLEMENTATION_RISKS=Cross-DB validation race; group lifecycle/LFG/instance semantics; bypass by direct SQL or destructive factory commands; dirty production tree; startup latency; malformed or duplicate roster data; non-admin logout paths
NEXT_IMPLEMENTATION_GATE=AWAIT_SEPARATE_AUTHORIZATION

SOURCE_FILES_CHANGED=NO
CONFIG_FILES_CHANGED=NO
DATABASE_CHANGED=NO
PROCESS_CONTROL_PERFORMED=NO
```

## Hub-Preflight und Abschluss

```text
HUB_PREFLIGHT_RESULT=PASS
CANONICAL_REGISTRY_READ=YES
GLOBAL_HUB_README_READ=YES
PRIMARY_WORKSTREAM_ID=WS-10
DEPENDENT_WORKSTREAM_IDS=WS-20,WS-30
WORKSTREAM_ID=WS-10
WORKSTREAM_README_READ=YES
HUB_MANIFEST_VERIFIED=YES
REFERENCED_ARTIFACTS_VERIFIED_COUNT=9
SOURCE_OF_TRUTH_CONFLICT_COUNT=0
UNRESOLVED_REFERENCE_COUNT=0
HUB_MUTATIONS_PERFORMED=NEW_WS10_EVIDENCE_FILES_ONLY;CONTROL_FILES=0
NEXT_TASK_AUTHORIZED=NO
```

Die Implementierungsphase ist nicht gestartet.
