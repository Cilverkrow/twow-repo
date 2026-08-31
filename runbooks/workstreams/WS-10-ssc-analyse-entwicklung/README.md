# WS-10 – SSC – Analyse und Entwicklung

Lokaler Chat: SSC – Analyse und Entwicklung
Online-Chat: SSC – Analyse und Entwicklung

## Eigentumsregel
SSC, PlayerBot, Source-Baselines und technische LLM-Brücke.

## Hub-Pfad
C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung

## Referenzverzeichnisse
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

## Referenz-Dateien (Runbook-Oberseiten)
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

## Überschneidungen und Sonderregeln
- WS-10-Technik bleibt für technische LLM-/PlayerBot-Implementierung, Brückenlogik und Kontexttransport.
- WS-70-Only Persona-Inhalt, Dialog- und Gedächtnisregeln.

## Neue Evidenz in diesem Workstream
Neue fachliche Evidenz unter WS-10 ablegen (z. B. neue LLM-Bridge-Funde, technischer Brückenstand).

### RNDBOT Persistent Active Roster – Phase B (2026-08-31)

- Runbook: `C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-20260830-230336`
- Deliverable: `C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-20260831-003005.zip`
- ZIP-Audit: `C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-20260831-003005.zip.audit.json`
- Ergebnis: `PHASE_B_RESULT=BLOCKED`; Implementierung, zwei reproduzierbare Tests, Post-Build-Scope-Gate und Clean Build sind `PASS`. Ausschließlicher Blocker ist der nicht ausführbare Create-/Rollback-Nachweis gegen eine disposable MariaDB (`127.0.0.1:3307`, Verbindungsfehler 10061). Es wurde keine aktive Datenbank gelesen oder verändert.
- Phase C: `AWAIT_SEPARATE_PACKAGE_AUDIT`; kein Deployment, kein Kandidatenstart und keine reale Roster-Version.

## Verfahrensregel
- Keine Inhalte fremder Workstreams verschieben, kopieren, überschreiben oder per Merge einfügen.
- Neue fachliche Evidenz nur als neue Dateien innerhalb dieses Workstream-Verzeichnisses anlegen.
- Historische Inhalte nur über Querverweise referenzieren; nicht kopieren oder neu schreiben.
