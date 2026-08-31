# SSC-SOURCE-BASELINE-02C-R1 – Kontrollierter Laufzeit- und Rückfalltest

## Abschluss

`SSC_SOURCE_BASELINE_02C_R1_RESULT=PASS`

`CANDIDATE_COMMIT=42b8a7f742548793910fe8880463aeeb71627fb9`

`CANDIDATE_RUNTIME_CHECK=PASS`

`PRODUCTION_EXE_RESTORED=YES`

`MANGOSD_RUNNING_AFTER_TEST=NO`

`REALMD_RUNNING_AFTER_TEST=NO`

`DEPLOYMENT_LEFT_ACTIVE=NO`

Der unveränderte Clean-Build-Kandidat wurde einmal mit den bestehenden Produktionskonfigurationen und der laufenden Produktionsdatenbank gestartet. Er akzeptierte die Datenbankstruktur, erreichte den World-/Netzwerkbetrieb auf `0.0.0.0:8090`, blieb über die geforderten 180 Sekunden stabil und wurde anschließend kontrolliert beendet. Die bisherige Produktions-EXE wurde danach mit dem erwarteten SHA-256 wiederhergestellt. `mangosd` und `realmd` blieben ausgeschaltet.

## Phase A – erneuter Preflight

Erfassung: `2026-08-29T22:45:51.2972941Z` (`2026-08-30T00:45:51.3025215+02:00`). Vor dem Kopieren liefen weder `mangosd.exe` noch `realmd.exe`; die Game-Listener `8090` und `3724` waren nicht vorhanden. MariaDB wurde ausschließlich beobachtet: PID `31724`, Listener `127.0.0.1:3307`. Ollama wurde ausschließlich beobachtet: PID `5528`, Listener `127.0.0.1:11434`.

Alle verbindlichen Hash-Gates bestanden:

| Objekt | SHA-256 | Ergebnis |
|---|---|---|
| Produktions-`mangosd.exe` | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` | MATCH |
| Clean-Build-Kandidat | `2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE` | MATCH |
| `mangosd.conf` | `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D` | MATCH |
| `aiplayerbot.conf` | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` | MATCH |

Der festgelegte Backuppfad `C:\TW\ComTW\server\mangosd.pre-source-baseline-02c-20260829.exe` war noch nicht vorhanden. Das frühere BLOCKED-Paket wurde nicht verändert; sein SHA-256 blieb `78B02C8B3D614581BF842129541BE5C2AE249978783D7CFAB4B88C049549D280`.

## Phase C – temporäre Installation

Ein erster, durch die Sandbox verweigerter `Move-Item`-Versuch bewirkte keine Dateiveränderung. Eine sofortige Read-only-Prüfung bestätigte die Produktions-EXE weiter am ursprünglichen Ort, den unbenutzten Backuppfad und das Fehlen eines Teil-/Fehlerartefakts.

Danach wurde die Produktions-EXE unter dem festgelegten neuen Namen gesichert. Der Backup-Hash stimmte exakt mit dem Produktionshash überein. Der Clean-Build-Kandidat wurde als temporäre `server\mangosd.exe` eingesetzt und erneut mit seinem erwarteten Hash bestätigt. Beide Konfigurationshashes blieben unverändert.

## Phase D – kontrollierter Start und Beobachtung

Startmethode: `C:\TW\ComTW\server\start-mangosd.bat`. Startzeit: `2026-08-30T00:49:41.1128827+02:00`. Es wurde ausschließlich `mangosd` gestartet; beobachtete PID: `25492`. `realmd` blieb ausgeschaltet.

Die Laufzeitevidenz ergab:

- Die Revision `42b8a7f742548793910f` wurde beim normalen Uptime-Startdatensatz protokolliert (Logzeile 2107).
- Die Datenbankverbindungen und der vollständige World-/Netzwerkstart wurden akzeptiert; der Prozess lauschte anschließend unter `0.0.0.0:8090`.
- Es gab keinen Treffer für `character_inventory_copy`, keinen erkannten Schema-/Datenbankfehler und keinen erkannten Fatal-/Unhandled-Fehler.
- Der Prozess blieb antwortend; kein Crash wurde beobachtet.
- Die belastbare Beobachtung vom ersten Listener-Nachweis bis zur letzten Probe dauerte `227.855` Sekunden und überschritt damit die geforderten 180 Sekunden.

Es erfolgten keine Anmeldung, kein Botbefehl, kein Bridge-Start, kein Ollama-Kontakt, keine LLM-Inferenz, kein manueller SQL-Befehl und keine Migration. Normale automatische Serverstartaktivität wurde lediglich dokumentiert.

## Phase E – kontrollierter Shutdown und Rückfall

Der Bediener bestätigte die manuelle Eingabefolge `saveall`, anschließend `server shutdown 0`, in der ursprünglichen `mangosd`-Konsole mit `SHUTDOWN_DONE`. Der fehlerhafte Shutdown-Helper wurde nicht benutzt.

Das geschlossene Serverlog belegt den Graceful-Shutdown von `Shutting down world...` über Netzwerk-, Map-, Transport- und Datenbankbereinigung bis `Halting process...` (Logzeilen 12022–12035). Danach waren weder `mangosd.exe` noch `realmd.exe` aktiv; die Listener `8090` und `3724` waren geschlossen.

Der getestete Kandidat wurde als Evidenzartefakt `artifacts\mangosd.candidate-tested.exe` erhalten. Die zuvor verifizierte Produktions-EXE wurde nach `C:\TW\ComTW\server\mangosd.exe` zurückkopiert. Abschließende Hashprüfung:

| Objekt | SHA-256 | Ergebnis |
|---|---|---|
| Wiederhergestellte Produktions-EXE | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` | MATCH |
| Beibehaltenes Produktionsbackup | `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC` | MATCH |
| Getestetes Kandidatenartefakt | `2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE` | MATCH |
| `mangosd.conf` | `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D` | MATCH |
| `aiplayerbot.conf` | `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF` | MATCH |

## Abschließender Betriebszustand

Read-only erfasst um `2026-08-29T22:59:00.9303696Z`:

- `mangosd.exe`: nicht aktiv
- `realmd.exe`: nicht aktiv
- Listener `8090`: nicht vorhanden
- Listener `3724`: nicht vorhanden
- MariaDB: PID `31724`, `127.0.0.1:3307`, nicht gesteuert
- Ollama: PID `5528`, `127.0.0.1:11434`, nicht gesteuert und nicht angesprochen
- Produktions-EXE: wiederhergestellt und hashverifiziert
- Konfigurationen: unverändert und hashverifiziert
- Produktionsserver: nicht erneut gestartet

## Grenzen der Aussage

Der Test belegt die einmalige Start-, Schema- und Laufzeitkompatibilität des angegebenen Clean-Build-Kandidaten unter den beobachteten Bedingungen sowie den erfolgreichen Rückfall auf das Produktionsartefakt. Er ist kein Deployment-Freigabebeschluss, kein Login-/Bot-/Gameplay-Test und kein LLM-Integrationstest.

## Evidenzdateien

- `evidence/preflight.json`
- `evidence/phase-c-installation.json`
- `evidence/phase-d-runtime-observation.json`
- `evidence/phase-e-shutdown-and-restore.json`
- `evidence/final-state.json`
- `logs/server_2026-08-30_00-49-41.log`
- `artifacts/mangosd.candidate-tested.exe`
- `SHA256SUMS.txt`
