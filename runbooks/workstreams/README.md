# Lokaler TWoW Workstream-Hub

Erstellungszeitpunkt: 2026-08-30T17:39:32Z
Aufgabe: PROJECT-COLLAB-HUB-01 (lokale Kollaborations-Hub-Materialisierung)

## Zweck
- Eine verbindliche Zuordnung von 9 Workstreams zu lokalen und Online-Chats.
- Eine eindeutige Referenzliste für bestehende Runbook-Pfade im Lokalprojekt.
- Eigentums- und Überschneidungsregeln als Routing-Quelle für künftige Evidenz.

## Kernkennzahlen

- Projekt: C:\TW\ComTW (TWoW - Lokal)
- Bestehende Runbook-Verzeichnisse: 41
- Bestehende Runbook-Oberseiten-Dateien: 43
- Vorab validierte Laufzeit-Konsistenz: PASS

## Workstream-Index

| Workstream | Kanonischer Titel | Lokaler Chat | Online-Chat | Hub-Pfad |
| --- | --- | --- | --- | --- |
| WS-00 | Projektsteuerung und Workspace | Projektsteuerung und Workspace | Projektsteuerung und Workspace | C:\TW\ComTW\runbooks\workstreams\WS-00-projectsteuerung-workspace |
| WS-10 | SSC – Analyse und Entwicklung | SSC – Analyse und Entwicklung | SSC – Analyse und Entwicklung | C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung |
| WS-20 | Datenbank und Migrationen | Datenbank und Migrationen | Datenbank und Migrationen | C:\TW\ComTW\runbooks\workstreams\WS-20-datenbank-migrationen |
| WS-30 | Serverkonfiguration | Serverkonfiguration | Serverkonfiguration | C:\TW\ComTW\runbooks\workstreams\WS-30-serverkonfiguration |
| WS-40 | Deployment und Skripte | Deployment und Skripte | Deployment und Skripte | C:\TW\ComTW\runbooks\workstreams\WS-40-deployment-skripte |
| WS-50 | Build und Serverbetrieb | Build und Serverbetrieb | Build und Serverbetrieb | C:\TW\ComTW\runbooks\workstreams\WS-50-build-serverbetrieb |
| WS-60 | Referenzserver und Backups | Referenzserver und Backups | Referenzserver und Backups | C:\TW\ComTW\runbooks\workstreams\WS-60-referenzserver-backups |
| WS-70 | Bot-Persönlichkeiten | Bot-Persönlichkeiten | Bot-Persönlichkeiten | C:\TW\ComTW\runbooks\workstreams\WS-70-bot-persoenlichkeiten |
| WS-80 | Dokumentation und Entscheidungen | Dokumentation und Entscheidungen | Dokumentation und Entscheidungen | C:\TW\ComTW\runbooks\workstreams\WS-80-dokumentation-entscheidungen |

## Eigentums- und Quellenregelungen

- Historische-Content-Policy: CROSS_REFERENCES_ONLY (keine Verlinkungen kopieren/umschreiben).
- copy_old_chat_content: false, rewrite_old_chat_content: false, delete_legacy_chats: false.
- EXISTING_RUNBOOK_MUTATION_ALLOWED = NO, CHAT_MUTATION_ALLOWED = NO, SOURCE_MUTATION_ALLOWED = NO, SERVER_OR_DATABASE_OPERATIONS_ALLOWED = NO.

| Workstream | Eigentumsregel | Referenzierte Verzeichnisse | Referenzierte Oberseiten-Dateien |
| --- | --- | --- | --- |
| WS-00 (Projektsteuerung und Workspace) | Projektkarte, Routing, Governance und Übergaben | 0 | 0 |
| WS-10 (SSC – Analyse und Entwicklung) | SSC, PlayerBot, Source-Baselines und technische LLM-Brücke. | 19 | 13 |
| WS-20 (Datenbank und Migrationen) | Datenbank, Migrationen und direkt zugehörige Rücksicherung. | 14 | 19 |
| WS-30 (Serverkonfiguration) | Künftige sanitisierte Konfigurations-, Port- und Pfadevidenz. | 0 | 0 |
| WS-40 (Deployment und Skripte) | Skripte, Launcher, Archive und Hilfsprogramme. | 4 | 3 |
| WS-50 (Build und Serverbetrieb) | Buildausführung, Dienste und Live-Smoke-Evidenz. | 2 | 3 |
| WS-60 (Referenzserver und Backups) | Künftige langfristige, historische und referenzserverbezogene Sicherungen. | 0 | 0 |
| WS-70 (Bot-Persönlichkeiten) | Bot-Personality-Paketierung, Prompts, Verhalten, Gedächtnis und Dialogregeln. | 2 | 5 |
| WS-80 (Dokumentation und Entscheidungen) | Projektweite Entscheidungen, ADRs und Indizes. | 0 | 0 |


## Vollständige Referenzliste

### WS-00 Projektsteuerung und Workspace
- (keine bestehenden Runbook-Verzeichnisse zugeordnet; Hub-Knoten ist der Workstream-Ordner.)

### WS-10 SSC – Analyse und Entwicklung
- C:\TW\ComTW\runbooks\_superseded-phase1b-package-build-20260829-163519
- C:\TW\ComTW\runbooks\_superseded-phase1b-package-build-20260829-163519-timestamp-audit
- C:\TW\ComTW\runbooks\playerbot-discovery-matrix-preflight-02-20260830-173815
- C:\TW\ComTW\runbooks\ssc-llm-bridge-phase0-20260829-015349
- C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-20260829-023418
- C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-hardening-20260829-035317
- C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1b-live-20260829-163519
- C:\TW\ComTW\runbooks\ssc-llm-bridge-v1-english-correction-20260830-131349
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-20260830-012815
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r1-20260830-163931
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r2-20260830-170407
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-20260830-173121
- C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352
- C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848
- C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358
- C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222
- C:\TW\ComTW\runbooks\ssc-source-baseline-02a3-20260829-215858
- C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607
- C:\TW\ComTW\runbooks\ssc-source-baseline-02c-r1-20260830-004551

### WS-20 Datenbank und Migrationen
- C:\TW\ComTW\runbooks\acl-context-lab
- C:\TW\ComTW\runbooks\autodonationpoints-preflight-20260829-034455
- C:\TW\ComTW\runbooks\db-profession-riding-discovery-01-20260830-010856
- C:\TW\ComTW\runbooks\donation-point-backup-20260829-183323
- C:\TW\ComTW\runbooks\donation-point-manual-20260829-182942
- C:\TW\ComTW\runbooks\donation-point-migration-20260829-183829
- C:\TW\ComTW\runbooks\donation-point-progress-migration-20260829-173126
- C:\TW\ComTW\runbooks\donation-point-progress-migration-20260829-180600
- C:\TW\ComTW\runbooks\donation-point-progress-migration-20260829-181230
- C:\TW\ComTW\runbooks\donation-runtime-test-01-20260829-184426
- C:\TW\ComTW\runbooks\semantic-acl-e2e-lab
- C:\TW\ComTW\runbooks\semantic-acl-e2e-lab-3
- C:\TW\ComTW\runbooks\trainer-control-20260829-014115-699
- C:\TW\ComTW\runbooks\trainer-purchase-money-loss-20260829-004949-873

### WS-30 Serverkonfiguration
- (keine neuen bestehenden Verzeichnisse vorhanden)

### WS-40 Deployment und Skripte
- C:\TW\ComTW\runbooks\compile-launcher-regeneration-lab
- C:\TW\ComTW\runbooks\compile-script-archive-20260828
- C:\TW\ComTW\runbooks\runtime-file-archive-20260828
- C:\TW\ComTW\runbooks\shutdown-helper-console-lab

### WS-50 Build und Serverbetrieb
- C:\TW\ComTW\runbooks\post-completion-live-smoke-20260829-000920-697
- C:\TW\ComTW\runbooks\world-shutdown-smoke-evidence-20260828-160724-135

### WS-60 Referenzserver und Backups
- (keine bestehenden Verzeichnisse vorhanden)

### WS-70 Bot-Persönlichkeiten
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-223311
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032

### WS-80 Dokumentation und Entscheidungen
- (keine bestehenden Verzeichnisse vorhanden)

## Vollständige Referenzdateien

### WS-10 SSC – Analyse und Entwicklung
- C:\TW\ComTW\runbooks\ssc-llm-bridge-v1-english-correction-20260830-131349-deliverable-audit.json
- C:\TW\ComTW\runbooks\ssc-llm-bridge-v1-english-correction-20260830-131349-deliverables.zip
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-20260830-012815-deliverables.zip
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r1-20260830-163931-deliverables.zip
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r2-20260830-170407-deliverables.zip
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-20260830-173121-deliverables.zip
- C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-20260830-173121-deliverables.zip.metadata.json
- C:\TW\ComTW\runbooks\SSC-OLLAMA-MANUAL-SCALING-01-PHASE1-20260829-210352.zip
- C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-01-20260829.zip
- C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-02B-20260829-222913.zip
- C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-02C-BLOCKED-20260830-001200.zip
- C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-02C-R1-PASS-20260830-010122.zip
- C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-02C-R1-PASS-20260830-010122.zip.metadata.json

### WS-20 Datenbank und Migrationen
- C:\TW\ComTW\runbooks\tw-char-migration-114C52D2.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-1B9D3F82.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion-candidate.md
- C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion-candidate.zip
- C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion-revised-candidate.md
- C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion-revised-candidate.zip
- C:\TW\ComTW\runbooks\tw-char-migration-20260827-205920-completion.md
- C:\TW\ComTW\runbooks\tw-char-migration-3904689F.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-db-ready-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-F92F86D6.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-module-inspection-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-module-metadata-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-module-reset-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-normalize-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-post-run-audit-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-post-run-audit-candidate.zip
- C:\TW\ComTW\runbooks\tw-char-migration-readiness-smoke-candidate.ps1
- C:\TW\ComTW\runbooks\tw-char-migration-semantic-acl-candidate.ps1

### WS-30 Serverkonfiguration
- (keine vorhandenen Top-Level-Dateien zugeordnet)

### WS-40 Deployment und Skripte
- C:\TW\ComTW\runbooks\compile-tortoise-wow-launcher-regeneration-candidate.ps1
- C:\TW\ComTW\runbooks\compile-tortoise-wow-launcher-regeneration-review.zip
- C:\TW\ComTW\runbooks\shutdown-helper-title-compatibility-review.zip

### WS-50 Build und Serverbetrieb
- C:\TW\ComTW\runbooks\tw-world-shutdown-smoke-35C08FAF.ps1
- C:\TW\ComTW\runbooks\tw-world-shutdown-smoke-35C08FAF.ps1.attempted
- C:\TW\ComTW\runbooks\tw-world-shutdown-smoke-count-fix-candidate.ps1

### WS-60 Referenzserver und Backups
- (keine vorhandenen Top-Level-Dateien zugeordnet)

### WS-70 Bot-Persönlichkeiten
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip.base64-chunks.tsv
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip.base64.txt
- C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032.zip.base64.txt.chunks.txt
- C:\TW\ComTW\runbooks\personality-context-contract-v1.md

### WS-80 Dokumentation und Entscheidungen
- (keine vorhandenen Top-Level-Dateien zugeordnet)

### WS-00 Projektsteuerung und Workspace
- (keine vorhandenen Top-Level-Dateien zugeordnet)

## Überschneidungsregeln
1. WS-40 entwickelt und versioniert Skripte; WS-50 besitzt Ausführungs-, Dienst- und Live-Smoke-Evidenz.
2. WS-20 besitzt migrationslokale Rücksicherung; WS-60 besitzt langfristige, historische und referenzserverbezogene Backups.
3. WS-10 besitzt technische LLM-/PlayerBot-Brücke und Kontexttransport; WS-70 besitzt Persona-Inhalt, Verhalten und Dialogregeln.
4. Fachdokumentation bleibt beim jeweiligen Fachbereich; WS-80 besitzt nur projektweite Entscheidungen, ADRs und Indizes.
5. WS-30 besitzt Konfigurationswerte, Ports und Pfade; WS-40 besitzt Verteilungs- und Steuerskripte; WS-50 besitzt die beobachtete Laufzeitwirkung.
6. Historische Fehlzuordnungen werden nicht umgeschrieben; neue Arbeit folgt der kanonischen Workstream-ID.

## Arbeitsablauf für neue Belege

1. Arbeitsthema wählen.
2. Zuständigen Workstream im Root-Index lesen.
3. Ziel-WS-README öffnen.
4. Nur dort referenzierte Bestände konsultieren.
5. Neue fachliche Evidenz ausschließlich im zugehörigen Workstream-Verzeichnis ablegen.
6. Bei Überschneidung nur fachlich geeignete Querverweise setzen (keine Kopie/Weiterleitung von Inhalt).
7. Historische Kontextbezüge unverändert lassen.

## Quellenverifikation

- local-project-structure-inventory-v1-r1.json SHA-256 77E97BB469D98453830D4F925C89700EB04A28F1DB1F02BAA10681A18F09F433 (15.08 KiB)
- canonical-workstream-matrix-v1.json SHA-256 F78359A6F6EE69E413113C3F73BCABE2617DB15FC2783AA8FD3D8A6DD8172042 (3.50 KiB)
- proposed-ui-action-plan-v1.md SHA-256 EBD7C62CCCDD60DFB499714774B24B7B36A85B5E86F80FC404ABD36050536CBA (11.13 KiB)

