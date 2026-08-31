# SSC-SOURCE-BASELINE-02C – kontrollierter Laufzeit- und Rückfalltest

## Abschlussentscheidung

`SOURCE_BASELINE_02C_RESULT=BLOCKED`

`STABLE_REVISION_RESULT=BLOCKED`

Phase B wurde am kontrollierten World-Shutdown-Gate abgebrochen. Der vorhandene Produktionshelfer konnte seinen ersten Konsolenbefehl nicht zustellen und meldete `WriteConsoleInput failed`. Entsprechend dem verbindlichen Arbeitsauftrag gab es keinen zweiten Versuch, keinen Force-Kill, keinen realmd-Shutdown, keine EXE-Kopie und keinen Kandidatenstart.

Die bisherige Produktions-EXE befindet sich weiterhin unverändert im Produktionspfad. `mangosd`, `realmd`, MariaDB und Ollama laufen mit denselben PIDs und Listenern weiter wie unmittelbar vor dem fehlgeschlagenen Shutdownversuch.

## Freigabe und gebundene Artefakte

Die beigefügte Freigabe enthielt:

```text
MAINTENANCE_WINDOW_CONFIRMED=YES
PHASE_B_TO_E_AUTHORIZED=YES
PRODUCTION_PROMOTION_APPROVED=NO
SSC_LLM_PRODUCTION_BRIDGE_01=QUEUED_NOT_AUTHORIZED
```

Die unveränderte Arbeitsauftragskopie liegt als `evidence/authorized-work-order.txt` vor, SHA-256 `0A3C3797E72F17F75286D2D2F6D8CBBB00E4F83976FDE1654878C196259A0AFD`.

Vor Phase B erneut bestätigte Hashes:

- Kandidaten-EXE: `2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE`
- Produktions-EXE: `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`
- `mangosd.conf`: `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`
- `aiplayerbot.conf`: `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`
- Backupziel `C:\TW\ComTW\server\mangosd.pre-source-baseline-02c-20260829.exe`: nicht vorhanden

## Kontrollierte Methode

Als bestehende Produktionsmethode wurde `C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully.ps1` verwendet, SHA-256 `CC0BD46FEA50F653778A11711BC9D9FE1A1B0BBE84980440A18734C6632FE3B1`.

Der Helfer ist der von `shutdown_all.bat` verwendete kontrollierte Pfad. Für den Worldserver validiert er den vollständigen EXE-Pfad, `twlive.pid`, den zugehörigen Prozess und den Konsolentitel. Anschließend soll er zuerst `saveall`, nach fünf Sekunden `server shutdown 0` senden und auf Exitcode 0 warten. Er enthält keinen Force-Kill.

Der Computer-Use-Skill untersagt die Automatisierung eines Konsolenfensters. Daher erfolgte keine simulierte Tastatureingabe in das Serverterminal. Stattdessen wurde der vorhandene validierte Shutdownhelfer direkt aufgerufen.

## Phase-B-Ablauf

Unmittelbarer Zustand vor dem Versuch, `2026-08-29T22:07:38.4613352Z` / `2026-08-30T00:07:38+02:00`:

- `mangosd.exe`: PID 13808, Pfad `C:\TW\ComTW\server\mangosd.exe`, Listener `0.0.0.0:8090`
- `realmd.exe`: PID 32260, Pfad `C:\TW\ComTW\server\realmd.exe`, Listener `0.0.0.0:3724`
- `mysqld.exe`: PID 31724, Listener `127.0.0.1:3307`
- `ollama.exe`: PID 5528, Listener `127.0.0.1:11434`
- `twlive.pid`: 13808
- `twrealmd.pid`: 32260

Der World-Shutdownversuch begann am `2026-08-29T22:08:24Z` und endete nach 0,598 Sekunden mit Exitcode 1:

```text
[FEHLER] Ausnahme beim Aufrufen von "WriteCommand" mit 1 Argument(en): "WriteConsoleInput failed"
```

Aus dem unveränderten Helfer-Quellpfad folgt, dass Prozess-, Pfad-, PID- und Konsolentitelprüfung bereits durchlaufen waren und der Fehler beim ersten `WriteCommand` innerhalb der World-Operation auftrat. Eine erfolgreiche Zustellung von `saveall` ist daher nicht nachgewiesen; `server shutdown 0` wurde vom Helfer nicht mehr aufgerufen. Es wurde keine Fehlerbehebung oder Wiederholung innerhalb 02C versucht.

## Zustand nach dem Blocker

Nachweiszeit: `2026-08-29T22:08:40.2486165Z` / `2026-08-30T00:08:40+02:00`.

- `mangosd.exe` läuft weiterhin mit derselben PID 13808; Port 8090 gehört weiterhin dieser PID.
- `realmd.exe` wurde nicht angesprochen und läuft weiterhin mit derselben PID 32260; Port 3724 gehört weiterhin dieser PID.
- MariaDB läuft unverändert mit PID 31724 auf `127.0.0.1:3307`.
- Ollama läuft unverändert mit PID 5528 auf `127.0.0.1:11434`; es gab keine Prozesssteuerung und keine Anfrage.
- Die Produktions-EXE hat weiterhin SHA-256 `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`.
- Beide Config-Hashes sind unverändert.
- Das vorgesehene Backup wurde nicht erstellt und existiert weiterhin nicht.
- Die Kandidaten-EXE wurde nicht in den Serverordner kopiert.
- Keine PDB wurde installiert.
- Keine Config, SQL-Tabelle oder Migration wurde verändert.
- Keine Bridge, Ollama-Inferenz, Anmeldung, Chat-, GM-, Debug-, Bot- oder PlayerBot-Aktion wurde ausgeführt.

Ein read-only erfasster 1-MiB-Ausschnitt des weiterhin aktiven Produktionslogs zeigt normale automatische Serveraktivität nach dem Blocker und keine Prozessbeendigung. Er ist kein Kandidaten-Startlog; Phase D wurde nicht begonnen.

## Nicht begonnene Phasen und Rückfallstatus

Phase C wurde nicht begonnen, weil Phase B vor dem Stillstand blockierte. Deshalb wurde kein Backup erzeugt, keine EXE ersetzt und keine PDB kopiert. Phase D einschließlich Revisionstest, Datenbankschema-Gate, World-Initialisierung und 180-Sekunden-Beobachtung wurde nicht begonnen.

Ein Kopier-Rollback in Phase E war nicht erforderlich und durfte bei laufendem `mangosd` nicht ausgeführt werden. Die Produktions-EXE gilt im Abschlussblock als wiederhergestellt, weil sie den Produktionspfad nie verlassen hat und ihr finaler Hash exakt dem gebundenen Produktionshash entspricht. `ROLLBACK_TESTED=NO` bleibt korrekt, da kein tatsächlicher Austausch/Rückkopiervorgang stattfand.

## Abschlussblock

```text
SOURCE_BASELINE_02C_RESULT=BLOCKED
CANDIDATE_HASH_MATCH=YES
BACKUP_HASH_MATCH=NO
STARTUP_REVISION_MATCH=NO
DATABASE_STRUCTURE_ACCEPTED=NO
CHARACTER_INVENTORY_COPY_ERROR=NO
WORLD_STARTUP_COMPLETE=NO
LISTENER_8090_READY=NO
OBSERVATION_WINDOW_SECONDS=0
OBSERVATION_WINDOW_PASS=NO
LLM_ACTIVITY=NONE
OLLAMA_PROCESS_CONTROL=NONE
CONFIG_CHANGED=NO
CONTROLLED_SHUTDOWN_PASS=NO
ROLLBACK_TESTED=NO
PRODUCTION_EXE_RESTORED=YES
PRODUCTION_EXE_FINAL_SHA256=FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC
MANGOSD_FINAL_STATE=RUNNING
REALMD_FINAL_STATE=RUNNING
STABLE_REVISION_RESULT=BLOCKED
PRODUCTION_PROMOTION_STARTED=NO
SSC_LLM_PRODUCTION_BRIDGE_STARTED=NO
```

`BACKUP_HASH_MATCH=NO` und die Startup-Gates `NO` bedeuten hier „nicht ausgeführt, weil Phase B blockierte“, nicht einen festgestellten Kandidaten- oder Backup-Hashfehler. `CHARACTER_INVENTORY_COPY_ERROR=NO` bedeutet, dass diese Aufgabe keinen solchen Fehler erzeugt hat; das Schema wurde mangels Kandidatenstart nicht erneut bewertet.

Nach diesem Bericht stoppen. Es wurde keine nächste Phase begonnen.
