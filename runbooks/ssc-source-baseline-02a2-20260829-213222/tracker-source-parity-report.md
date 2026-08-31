# SSC-SOURCE-BASELINE-02A2 – Tracker-to-Source Parity

## Abschlussstatus

`TRACKER_SOURCE_PARITY=BLOCKED`

Der World-Tracker stimmt hinsichtlich Namen, Anzahl, Eindeutigkeit, IDs und Reihenfolge exakt mit den 146 Kandidatendateien überein. Die Inhaltsprovenienz ist dennoch nicht belegbar: Alle 146 gespeicherten `tw_world.migrations.Hash`-Werte lauten wörtlich `manual`; keiner entspricht dem vom Migrationstool berechneten SHA-1 der jeweiligen Datei. Der Marker ist im Repository für manuell registrierte Migrationen ausdrücklich dokumentiert, ist aber kein Dateihash.

Es wurde kein Clean Build begonnen.

## Evidenzbasis

- Repository: `C:\TW\ComTW\source`
- Kandidatencommit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Tree-ID: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`
- HEAD entspricht dem Kandidatencommit.
- `sql/database_updates` und `sql/character_updates` unterscheiden sich nicht vom Kandidatencommit; ihr bereichsbezogener Git-Status ist leer.
- Live-Evidenz: `ssc-source-baseline-02-20260829-204358/evidence/live-schema-selects-after-user-start-no-tls.stdout.txt`
- SHA-256 der Live-Ausgabe: `B866C9F412526AF05D13823D4F3D508F04CDC74005A720DE0FD08195F223888B`; stimmt mit den ursprünglichen Metadaten überein.
- Die vorhandene Live-Abfrage bestand ausschließlich aus sieben SELECT-/information_schema-Anweisungen. Für 02A2 wurde keine neue SQL-Abfrage ausgeführt.

## Exakter Hashalgorithmus

Der Algorithmus wurde aus dem Kandidatensource ermittelt, nicht vermutet:

1. `AutoUpdater::LoadFileMigrations` ruft für jede reguläre `.sql`-Datei `CalculateFileHash` auf und verwendet den resultierenden Hash als Migration-Key.
2. `CalculateFileHash` öffnet die Datei mit `std::ios::binary`.
3. Die gesamte Datei wird bytegenau in einen Bytevektor gelesen.
4. Über alle Bytes wird SHA-1 gebildet; der Digest ist 20 Byte lang.
5. `ByteArrayToHexStr` kodiert jedes Digestbyte in ursprünglicher Reihenfolge mit `%02X`, also als 40 Zeichen großes Hexadezimalformat.
6. Es findet keine Zeilenenden-, Whitespace-, BOM- oder Textnormalisierung statt.

Damit lautet der genaue Vertrag: **SHA-1 über sämtliche tatsächlich ausgecheckten Rohbytes, ausgegeben als 40-stelliges Uppercase-Hex ohne Trennzeichen.**

Das Repository hat lokal `core.autocrlf=true`. Deshalb unterscheiden sich bei den SQL-Dateien die SHA-1-Werte der rohen LF-Git-Blob-Bytes von den SHA-1-Werten der durch den AutoUpdater tatsächlich gelesenen Windows-Checkout-Bytes. Die gespeicherten Character-Hashes stimmen mit den Checkout-Bytes überein. Die Matrix weist beide Werte getrennt aus und verwendet für die Tool-Parität den Checkout-Byte-Hash.

Belegstellen:

- `src/shared/Database/AutoUpdater.cpp:102-129, 133-230, 441-487, 489-530`
- `src/shared/Util.cpp:668-689`
- vollständig gesichert in `evidence/source-excerpts.txt`

## tw_world.migrations gegen sql/database_updates

| Prüfung | Ergebnis |
|---|---:|
| Trackerzeilen | 146 |
| Kandidatendateien rekursiv unter `sql/database_updates` | 146 |
| fehlende Trackernamen | 0 |
| zusätzliche Dateinamen | 0 |
| doppelte Trackernamen | 0 |
| doppelte Dateinamen | 0 |
| ID-Bereich | 632–777 |
| IDs fortlaufend | ja |
| Reihenfolge nach ID gegen namenssortierte Dateien | 146/146 identisch |
| exakte gespeicherte Datei-Hashes | 0/146 |
| gespeicherter Marker `manual` | 146/146 |

Die 146 Kandidatendateien gliedern sich in 25 Dateien direkt unter `sql/database_updates`, 120 unter `sql/database_updates/world` und eine Character-Datei unter `sql/database_updates/character`.

Die Source-Dokumentation erklärt den Befund ausdrücklich: Bei einer aus einem vollständigen Dump wiederhergestellten Welt-Datenbank wurden Migrationen manuell ausgeführt und anschließend mit `Hash='manual'` registriert, weil Basissnapshot und Migrationshistorie nicht sauber aufeinander abbildbar sind. Das erklärt den Marker, ersetzt aber keinen Inhaltsnachweis. Der AutoUpdater vergleicht nach `Module + Hash`, nicht primär nach Name. `manual` entspricht daher keinem Kandidatendateihash und würde die Dateien nicht als anhand ihres Inhalts angewandt erkennen.

Besonderheit: `tw_world.migrations` enthält bei ID 772 auch `20260817151028_character` mit `Hash=manual`, weil die namensgleiche Datei innerhalb des betrachteten `sql/database_updates`-Baums liegt. Diese World-Trackerzeile beweist nicht, dass die Character-DDL gegen die richtige Datenbank ausgeführt wurde. Die korrekte, hashgenaue Zuordnung findet sich separat in `tw_char.migrations` ID 4.

Folgerung: Die World-Namensparität ist vollständig, die World-Inhalts- beziehungsweise Ausführungsparität bleibt unbelegt. Das ist der Blocker für `PASS`.

## tw_char.migrations gegen sql/character_updates

| Tracker-ID | Trackername | zugehörige Kandidatendatei | gespeicherter Hash = Datei-SHA-1 |
|---:|---|---|---:|
| 1 | `20260708055500_ai_playerbot_random_bots_index` | `sql/character_updates/20260708055500_ai_playerbot_random_bots_index.sql` | ja |
| 2 | `20260731160000_guild_bank_money_unsigned` | `sql/character_updates/20260731160000_guild_bank_money_unsigned.sql` | ja |
| 3 | `20260812142512_character_inventory_copy` | `sql/character_updates/20260812142512_character_inventory_copy.sql` | ja |
| 4 | `20260817151028_character` | `sql/database_updates/character/20260817151028_character.sql` | ja |

Die IDs 1–4 sind eindeutig und fortlaufend. Die drei Dateien unter `sql/character_updates` stimmen 3/3 nach exaktem Namen und AutoUpdater-SHA-1 überein. Die gegenüber diesem Verzeichnis zusätzliche vierte Zeile ist vollständig erklärbar:

- ID: `4`
- Name: `20260817151028_character`
- Trackerhash: `557CE92CFE4B6C0B6E54316EA781459ED26F1B07`
- zugehörige Datei: `sql/database_updates/character/20260817151028_character.sql`
- Checkout-Byte-SHA-1: `557CE92CFE4B6C0B6E54316EA781459ED26F1B07`
- Inhalt: `CREATE TABLE IF NOT EXISTS character_pvp_currency (...)`
- Klassifikation: vorhandene Kandidatenmigration im vom Kandidaten-Configschema bezeichneten AutoUpdater-Character-Verzeichnis; zusätzlich in `sql/create_databases.sql` in den Basisstand integriert; **nicht entfernt und nicht ohne Datei**.
- Sourcevertrag: Der Kandidat lädt die Tabelle in `CharacterHandler.cpp` und schreibt sie in `HonorMgr.cpp`. Name, Datei, Tabellenvertrag und Trackerhash sind kompatibel.

### character_inventory_copy

Ausdrückliche Bestätigung:

```text
TRACKER_NAME=20260812142512_character_inventory_copy
SOURCE_NAME=20260812142512_character_inventory_copy
TRACKER_HASH=8662106E777C548A1349CB813EE1A47DB7A1785E
CANDIDATE_CHECKOUT_SHA1=8662106E777C548A1349CB813EE1A47DB7A1785E
NAME_MATCH=YES
HASH_MATCH=YES
```

Der rohe Git-Blob hat wegen der nicht vom AutoUpdater normalisierten Zeilenenden einen anderen SHA-1. Das ist kein Widerspruch: Der gespeicherte Hash stimmt exakt mit den vom Migrationstool unter diesem Windows-Checkout gelesenen Bytes überein.

## donation_point_progress

`donation_point_progress` ist bewusst als Standalone-Migration geführt:

- Kandidatendatei: `sql/logon/donation_point_progress.sql`
- Ziel laut Datei: LOGIN-Datenbank
- Datei liegt außerhalb von `Database.AutoUpdate.Path` plus den konfigurierten Unterordnern `auth`, `character` und `world`.
- Daher wird sie von diesem AutoUpdater nicht aufgenommen; ein Eintrag in `tw_logon.migrations` ist nicht zu erwarten.
- Der Live-SELECT zeigt folgerichtig 0 Zeilen in `tw_logon.migrations`.
- Die Live-Tabelle besitzt `account_id INT UNSIGNED PRIMARY KEY` und `accumulated_ms INT UNSIGNED NOT NULL DEFAULT 0`, exakt entsprechend der Standalone-Datei.
- `World.cpp` liest `accumulated_ms` über `LoginDatabase` und führt Upserts genau auf diesen beiden Spalten aus.
- `mangosd.conf.dist.in` benennt die Standalone-Datei ausdrücklich als Voraussetzung für persistente Donation-Point-Fortschritte.

Damit gilt:

```text
DONATION_STANDALONE_MIGRATION=YES
TW_LOGON_TRACKER_ENTRY_EXPECTED=NO
DONATION_TABLE_SOURCE_CONTRACT_MATCH=YES
```

## Maschinenlesbare Ergebnisse

- `evidence/tracker-source-parity-matrix.json`: vollständige Matrix mit allen 146 World- und vier Character-Zeilen, beiden SHA-1-Varianten, Git-Blob-OIDs, Größen, SHA-256, IDs, Namen, Pfaden und Einzelbewertungen
- `evidence/world-parity.csv`: alle 146 World-Paarungen
- `evidence/character-parity.csv`: alle vier Character-Paarungen
- `evidence/source-excerpts.txt`: Hashalgorithmus, AutoUpdater-Pfade, Manual-Marker-Dokumentation, Donation-Vertrag und vierte Character-Datei
- `evidence/character-fourth-row-source-excerpts.txt`: Basis-DDL, Character-Read/Write-Vertrag und Dateihistorie der vierten Zeile

## Unverändertheitsbestätigung

- keine SQL-Schreiboperation;
- keine Migration;
- keine Prozesssteuerung;
- keine Source- oder Configänderung;
- kein Checkout, Pull oder Fetch;
- kein Build und keine Kompilierung.

Neu geschrieben wurden ausschließlich Bericht, Matrix, CSVs, Sourceauszüge und lokale Reproduktionswerkzeuge im separaten Runbook `C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222`.

Nach diesem Bericht wird gestoppt; der Clean Build bleibt gesperrt.
