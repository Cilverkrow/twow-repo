# SSC-SOURCE-BASELINE-02A3 – Manual-Hash-Provenienz und Ersatznachweis

## Abschlussentscheidung

`MANUAL_HASH_PROVENANCE=PASS_WITH_LIMITATION`

`CLEAN_BUILD_02B_RECOMMENDATION=GO`

Die Einschränkung bleibt verbindlich: Die 146 historischen Trackerwerte `manual` beweisen nicht, welche SQL-Dateibytes tatsächlich ausgeführt wurden oder ob jede einzelne Anweisung erfolgreich wirksam wurde. Das neue externe Manifest fixiert ausschließlich den jetzt geprüften Kandidatenstand als zukünftigen Baseline-Nachweis.

Der Clean Build wurde nicht begonnen.

## Verbindliche Eingaben

- SELECT-Ausgabe: `C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.stdout.txt`
- verifizierter SHA-256: `B866C9F412526AF05D13823D4F3D508F04CDC74005A720DE0FD08195F223888B`
- Kandidatencommit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Tree-ID: `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`

HEAD entspricht dem Kandidatencommit. Die untersuchten Migrationspfade sind gegenüber dem Commit unverändert und haben einen leeren bereichsbezogenen Git-Status. Der laufende Produktionsserver, seine Logs und laufende Datentabellenänderungen wurden nicht betrachtet.

## 1. World-Namensparität

| Prüfung | Ergebnis |
|---|---:|
| `tw_world.migrations`-Zeilen | 146 |
| `.sql`-Dateien rekursiv unter `sql/database_updates` | 146 |
| exakte Namenszuordnungen | 146 |
| fehlende Trackernamen | 0 |
| zusätzliche Dateinamen | 0 |
| doppelte Trackernamen | 0 |
| doppelte Kandidatennamen | 0 |
| ID-Bereich | 632–777 |
| fortlaufende IDs | 146/146 |
| Trackerreihenfolge gegen namenssortierten Kandidatenbaum | 146/146 |
| Hashwert `manual` | 146/146 |

Die Namens-, Mengen-, Eindeutigkeits-, ID- und Reihenfolgenparität ist vollständig bestätigt.

## 2. Wer `migrations.Hash` schreibt

### Normaler AutoUpdater

Der Kandidatencode bildet in `AutoUpdater::CalculateFileHash` SHA-1 über die vollständigen, mit `std::ios::binary` gelesenen Dateibytes. `ByteArrayToHexStr` gibt den 20-Byte-Digest in ursprünglicher Bytefolge mit `%02X` als 40-stelliges Uppercase-Hex aus.

Nach erfolgreicher Migrationsausführung schreibt `AutoUpdater::ExecuteUpdate`:

```text
INSERT INTO migrations (Name, Module, Hash, AppliedAt)
```

Dabei ist `Hash` ausschließlich der zuvor berechnete Dateihash. Im AutoUpdater-Code existiert kein Literal `manual` und kein Pfad, der diesen Wert erzeugt.

### Dokumentierter manueller Importweg

Der Kandidatensource dokumentiert ausdrücklich einen abweichenden Workflow für Datenbanken, die aus dem gemischten Basisdump restauriert wurden:

1. `Database.AutoUpdate.Enabled = 0`;
2. Migrationsdateien extern mit `--force` anwenden;
3. danach `INSERT IGNORE ... Hash='manual'` ausführen;
4. den AutoUpdater erst für spätere Updates wieder aktivieren.

Dieser Ablauf steht in `INSTALL-WINDOWS.md`, `INSTALL-LINUX.md` und `README.md`. Die Git-Historie führt ihn mindestens bis zu Commit `9a8ad6fb07201b2ce41b9075ae05788d838ade17` vom 31.07.2026 zurück. Dessen Commitbeschreibung erklärt ausdrücklich, dass Basissnapshot und Migrationen überlappen, automatische Wiederholung an Duplicate Keys scheitert und deshalb der manuelle `--force`-/Markerweg dokumentiert wurde.

### Lokaler, zum Live-Muster passender Importweg

Ein archiviertes lokales Installationsskript liegt vor:

- Pfad: `C:\TW\ComTW\runbooks\compile-script-archive-20260828\compile-tortoise-wow-1C9C9149.ps1`
- SHA-256: `1C9C914950E153FEEF773D319114FDBB69E27EDB4FF72557963B3F1D5C732FBD`
- Änderungszeit UTC: `2026-08-25T16:39:53.5835063Z`

Sein Ablauf in Zeilen 356–370:

- importiert zunächst `sql/base`;
- erfasst `sql/database_updates` rekursiv;
- sortiert die Dateien nach Namen;
- importiert jede Datei mit `--force` gegen `tw_world`;
- schreibt anschließend `Name`, den Literalwert `manual` und `NOW()` in `tw_world.migrations`.

Die Verhaltenssignatur stimmt exakt mit der unveränderten SELECT-Ausgabe überein:

- der Kandidaten-Basisdump definiert eine leere `migrations`-Tabelle mit nächster ID 632;
- die Live-Zeilen beginnen bei ID 632 und enden fortlaufend bei 777;
- ihre Namen entsprechen vollständig der namenssortierten rekursiven Dateiliste;
- alle Hashwerte sind `manual`;
- die `AppliedAt`-Werte bilden eine zusammenhängende Sequenz von `2026-08-25 18:55:38` bis `18:56:16`.

Das ist ein starker und belastbarer Nachweis des verwendeten Importmusters. Ohne damaliges Ausführungstranskript beweist es jedoch nicht, dass genau dieses Skript ausgeführt wurde, und wegen `--force` erst recht nicht, welche einzelnen SQL-Anweisungen historisch erfolgreich waren.

## 3. Klassifikation von `manual`

| Frage | Antwort |
|---|---|
| kryptografischer Hash? | nein |
| vom normalen AutoUpdater erzeugt? | nein |
| im Repository ausdrücklich dokumentiert? | ja |
| als externer Alt-/Importmarker unterstützt? | ja, im dokumentierten manuellen Betriebsablauf |
| vom AutoUpdater speziell als Sentinel erkannt? | nein |
| Ursprung innerhalb des normalen Core-Pfads möglich? | nein |
| externer/manueller SQL-Insert oder Übernahme aus einem so erzeugten Dump erforderlich? | ja |

`manual` ist somit ein ausdrücklich dokumentierter, nicht kryptografischer Alt-/Importmarker. Er ist **kein** besonderer AutoUpdater-Sentinel. Die Spalte akzeptiert ihn als normalen String; bei der AutoUpdater-Zuordnung stimmt er mit keinem berechneten Dateihash überein.

## 4. Wirkung von Database.AutoUpdate.Enabled = 0

`AutoUpdater::ProcessUpdates` kehrt bei deaktivierter Option sofort zurück. In diesem Zustand werden:

- keine Migrationsverzeichnisse gescannt;
- keine Dateihashes berechnet;
- keine Trackerzeilen geladen;
- keine Migrationen ausgeführt;
- keine Trackerwerte geschrieben oder umgeschrieben.

Die Option verhindert damit die automatische Wiederholung der durch `manual` nicht hashgenau erkannten Dateien. Sie macht `manual` aber weder zu einem Dateihash noch liefert sie nachträglich Inhaltsprovenienz. Die aktive Configdatei enthält read-only bestätigt `Database.AutoUpdate.Enabled = 0`; eine Configänderung erfolgte nicht.

## 5. Externes Zukunftsmanifest

Das neue Manifest enthält für alle 146 World-Dateien:

- Tracker-ID;
- Tracker-Name;
- relativen Dateipfad;
- Git-Blob-ID;
- SHA-256 der sauberen aktuellen Windows-Kandidatendatei;
- zusätzlich SHA-256 und Größe der rohen Git-Blob-Bytes;
- Ergebnis der exakten Namens-, Reihenfolgen- und ID-Zuordnung.

`core.autocrlf=true` ist berücksichtigt: Checkout-SHA-256 und Git-Blob-SHA-256 werden getrennt geführt. Dieses Manifest ist ausdrücklich `future_candidate_baseline_evidence`. Es kann bei späteren Prüfungen feststellen, ob Kandidatendateien unverändert geblieben sind. Es beweist nicht rückwirkend, welche Bytes 2026-08-25 importiert wurden.

## 6. Character-Matrix

Die gleiche Matrix enthält vier Character-Zeilen:

| ID | Name | Klassifikation | zugehörige Datei |
|---:|---|---|---|
| 1 | `20260708055500_ai_playerbot_random_bots_index` | aktuelle Character-Update-Datei | `sql/character_updates/...` |
| 2 | `20260731160000_guild_bank_money_unsigned` | aktuelle Character-Update-Datei | `sql/character_updates/...` |
| 3 | `20260812142512_character_inventory_copy` | aktuelle Character-Update-Datei | `sql/character_updates/...` |
| 4 | `20260817151028_character` | Kandidaten-AutoUpdater-Datei, auch im Basis-DDL integriert, nicht entfernt | `sql/database_updates/character/20260817151028_character.sql` |

Alle vier Namen besitzen eine exakte zugehörige Kandidatendatei. Die gespeicherten Character-SHA-1-Werte entsprechen jeweils den aktuellen Windows-Checkout-Bytes. Die vierte Zeile ist daher keine fehlende Migration; sie liegt lediglich außerhalb des separat betrachteten Verzeichnisses `sql/character_updates`.

## 7. donation_point_progress

`donation_point_progress` bleibt verifiziert als:

- bewusste Standalone-Migration `sql/logon/donation_point_progress.sql`;
- Ziel LOGIN-Datenbank;
- außerhalb der AutoUpdater-Unterordner `auth`, `character` und `world`;
- folglich ohne erwarteten Eintrag in `tw_logon.migrations`;
- Live-Tabellenschema und Kandidaten-Sourcevertrag stimmen überein.

`DONATION_STANDALONE_MIGRATION=YES`

`TW_LOGON_TRACKER_ENTRY_EXPECTED=NO`

`DONATION_TABLE_SOURCE_CONTRACT_MATCH=YES`

## 8. Schemaevidenz und Grenze

In den unveränderten SELECT-Ergebnissen und den bereits verifizierten Kandidatenverträgen wurde keine gegenteilige Schemaevidenz gefunden. Dies ist kein vollständiger semantischer Vergleich aller World-Tabellen und ersetzt keine historische Ausführungsaufzeichnung. Insbesondere wird keine historische Bytegleichheit der 146 World-Migrationen behauptet.

Das externe Manifest beseitigt diesen Provenienzmangel nur **prospektiv**: Ab jetzt ist der Kandidatendateisatz vollständig kryptografisch fixiert. Unter dieser ausdrücklich dokumentierten Einschränkung ist der isolierte Clean Build von exakt diesem Commit vertretbar.

## 9. Artefakte

- `evidence/external-candidate-baseline-manifest.json` – vollständige 150-Zeilen-Matrix mit World 146 und Character 4
- `evidence/external-candidate-baseline-manifest.csv` – tabellarische Ausgabe derselben Matrix
- `evidence/manual-marker-provenance.json` – maschinenlesbare Code-, Import-, Basisdump- und Historienbewertung
- `evidence/source-local-history-excerpts.txt` – zeilennummerierte Source-, Dokumentations-, Skript- und Git-Historienbelege
- `evidence/local-migrations-hash-write-search.txt` – read-only Suchergebnis zu lokalen Hash-Schreibpfaden
- `evidence/input-and-integrity.json` – Bindung an SELECT-Hash und Kandidatencommit sowie Negativnachweise

## 10. Unverändertheitsbestätigung

- keine neue SQL-Abfrage;
- kein Datenbankschreibzugriff und keine Trackeränderung;
- keine Migration;
- keine Prozesssteuerung oder Laufzeitinspektion;
- keine Source- oder Configänderung;
- kein Build, keine Kompilierung und kein Deployment;
- keine LLM-Inferenz und kein Bot-Test.

Geschrieben wurden ausschließlich neue Berichts-, Evidenz-, Manifest- und Reproduktionsdateien in `C:\TW\ComTW\runbooks\ssc-source-baseline-02a3-20260829-215858`.

Nach diesem Bericht wird gestoppt. Phase 02B wurde nicht begonnen.
