# Canonical Collaboration Hub Policy (LOCAL)

BEGIN_CANONICAL_COLLAB_HUB_POLICY_V1

## 3.1 Kanonischer Hub

Der verbindliche Collaboration Hub für alle lokalen Arbeitsaufträge liegt unter:
`C:\TW\ComTW\runbooks\workstreams`.

Die technische Workstream-ID `WS-00` bis `WS-80` ist der dauerhafte Primärschlüssel.
Sichtbare Chat-Titel sind keine technischen Identitäten.

## 3.2 Pflicht-Preflight für jeden Auftrag

Vor jeder Analyse, Planung, Mutation oder Ausführung prüft der lokale Agent:

1. `canonical-workstream-registry-v1.json` vollständig lesen.
2. `C:\TW\ComTW\runbooks\workstreams\README.md` vollständig lesen.
3. Den zuständigen Workstream anhand der Registry und des Auftragsziels bestimmen.
4. Die zugehörige Workstream-`README.md` vollständig lesen.
5. Für den Auftrag relevante, dort referenzierte Artefakte direkt verifizieren.
6. Den Hub-Manifeststatus (`C:\TW\ComTW\runbooks\workstreams\sha256-manifest.txt`) prüfen.
7. Widersprüche oder fehlende Informationen feststellen und dokumentieren.

Kein Chatgedächtnis oder frühere Zusammenfassung darf eine aktuelle lokale Datei,
einen Hash oder eine reproduzierbare Verifikation ersetzen.

## 3.3 Prioritätsordnung

Bei widersprüchlichen Informationen gilt in dieser Reihenfolge:

1. aktuell und reproduzierbar verifizierter Produktionszustand  
2. ausdrücklich freigegebene aktuelle technische Baseline  
3. `canonical-workstream-registry-v1.json`  
4. Hub-`README.md` des zuständigen Workstreams  
5. direkt referenzierte Reports, Handoffs und Manifeste  
6. übrige lokale Dokumentation  
7. Chatverlauf und Projektgedächtnis  

Ein niedriger priorisierter Eintrag darf einen höher priorisierten Befund nicht stillschweigend ersetzen.

## 3.4 Stop-Regel

Vor jeder Mutation wird mit `HUB_PREFLIGHT_RESULT=BLOCKED` sofort gestoppt, wenn:

- der zuständige Workstream nicht eindeutig bestimmbar ist;
- eine erforderliche Datei fehlt oder nicht lesbar ist;
- ein vorgeschriebener Hash nicht stimmt;
- Registry, Workstream-README und überprüfter Ist-Zustand widersprüchlich sind;
- eine benötigte Referenz nur im Chatgedächtnis behauptet wird;
- eine Mutation mehrere Workstreams betrifft ohne eindeutigen primären Eigentümer;
- Berechtigungen für die beabsichtigte Mutation fehlen.

Keine eigenmächtige Reparatur oder Erweiterung des Auftrags.

## 3.5 Schreibregeln

Der Collaboration Hub ist kein allgemeiner Ort für ungeprüfte Zwischenstände.
Neue Ergebnisse müssen zuerst als eigenständige, reproduzierbare Artefakte im vorgesehenen
Runbook- oder Workstream-Kontext abgelegt werden.

Änderungen an folgenden Hub-Dateien sind nur durch ausdrücklich autorisierte Hub-Aktualisierungsaufträge zulässig:

- `canonical-workstream-registry-v1.json`
- globale Hub-`README.md`
- Workstream-`README.md`
- Hub-`sha256-manifest.txt`

Bestehende Artefakte dürfen nicht kopiert, verschoben, gelöscht oder physisch zusammengeführt werden, sofern dies nicht gesondert autorisiert wurde.

## 3.6 Abschlussnachweis

Jeder lokale Abschlussbericht enthält mindestens:

- `HUB_PREFLIGHT_RESULT=PASS|BLOCKED`
- `CANONICAL_REGISTRY_READ=YES|NO`
- `GLOBAL_HUB_README_READ=YES|NO`
- `WORKSTREAM_ID=...`
- `WORKSTREAM_README_READ=YES|NO`
- `HUB_MANIFEST_VERIFIED=YES|NO`
- `REFERENCED_ARTIFACTS_VERIFIED_COUNT=...`
- `SOURCE_OF_TRUTH_CONFLICT_COUNT=...`
- `UNRESOLVED_REFERENCE_COUNT=...`
- `HUB_MUTATIONS_PERFORMED=...`
- `NEXT_TASK_AUTHORIZED=NO`

Bei mehreren beteiligten Workstreams zusätzlich:

- `PRIMARY_WORKSTREAM_ID=...`
- `DEPENDENT_WORKSTREAM_IDS=...`

END_CANONICAL_COLLAB_HUB_POLICY_V1

