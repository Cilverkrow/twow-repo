# Synchronisations- und Übergabeblock v1

```text
DATUM_UTC=2026-08-30T16:11:24Z
ZUSTAENDIGER_CHAT=Analysiere TWoW-Projektstruktur
KANONISCHER_ARBEITSBEREICH=WS-00 Projektsteuerung und Workspace
LOKALE_SPIEGELUNG=Analysiere TWoW-Projektstruktur
ZIEL=Lokale Projekt-, Chat-, Zuständigkeits- und Runbook-Struktur vollständig read-only inventarisieren; LLM-/Bot-Chat-relevante Bereiche kennzeichnen.
BESTAETIGTER_AUSGANGSZUSTAND=Lokales Codex-Projekt TWoW - Lokal mit sechs Chats; C:\TW\ComTW mit sieben obersten Verzeichnissen und bestehenden Server-/Build-/Runbook-Artefakten.
REPOSITORY_PFAD=C:\TW\ComTW\source
BRANCH=playerbots-integration-gh
COMMIT=42b8a7f742548793910fe8880463aeeb71627fb9
GIT_STATUS=M src/modules/PlayerBots/CMakeLists.txt; M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp; M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h; M src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp; ?? bin/
WICHTIGE_HASHES=compile-tortoise-wow.ps1:80D4D4607AF05048D14487AAD335C56ED2857D3F984D7F133A41F25D66706ECC; mangosd.exe:FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC; realmd.exe:A36A3B611229D2A68FEAA4BD92D4283888CA64CD45FBD7C5E6F28050AB0B676B; aiplayerbot.conf:490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF
SERVERDIENSTE=mangosd:not_running; realmd:not_running; mysqld:not_running; mariadbd:not_running; ollama:running(1)
BESTAETIGTE_ERGEBNISSE=6 lokale Chats; 5 exakte kanonische Titel; 1 Umbenennungsvorschlag; 3 fehlende Arbeitsbereiche; 41 Runbook-Verzeichnisse und 43 oberste Runbook-Dateien fachlich zugeordnet; 9 künftige Mapping-Kandidaten; 0 Chatmutationen; 0 Änderungen an bestehenden Projektdateien; 0 Server-/DB-Operationen.
OFFENE_FRAGEN=Freigabe WS-00-Umbenennung? Freigabe Anlage WS-30/WS-70/WS-80? Historische Fehlzuordnungen nur querverweisen oder zusätzlich manuell zusammenfassen?
ERLAUBTE_AKTIONEN=Dieses Inventar lesen, prüfen und kommentieren; einen Folgeauftrag ausdrücklich freigeben.
VERBOTENE_AKTIONEN=Ohne neue Freigabe keine Chatänderung, keine Verschiebung bestehender Runbooks, keine Änderung bestehender Projektdateien, keine Builds, keine Serverstarts/-stopps, keine Datenbankoperationen, keine Migrationen und keine Rollbacks.
ERWARTETES_ERGEBNIS=Benutzerentscheidung zur manuellen UI-Aktionsliste und zur künftigen Arbeitsstruktur; bis dahin bleibt der Ist-Zustand unverändert.
EMPFOHLENES_MODELL=GPT-5.6-Terra
REASONING_STUFE=medium
NEXT_TASK_AUTHORIZED=NO
```

## Fakten

- Lokales Projekt: `TWoW - Lokal`, Projekt-ID `bad28a62-cbc0-4374-bd12-e7e23a17aedf`, Pfad `C:\TW`.
- Exakte lokale Chat-Titel: WS-10, WS-20, WS-40, WS-50 und WS-60.
- WS-00 ist inhaltlich vorhanden, heißt derzeit aber `Analysiere TWoW-Projektstruktur`.
- Fehlende lokale Chats: WS-30 `Serverkonfiguration`, WS-70 `Bot-Persönlichkeiten`, WS-80 `Dokumentation und Entscheidungen`.
- Der technische Kern der LLM-/Bot-Chat-Integration liegt in WS-10; Persona-Inhalte liegen in WS-70. WS-30, WS-20, WS-40 und WS-50 sind wesentliche Abhängigkeiten.
- Bestehende lokale Git-Änderungen wurden nur erfasst und nicht berührt.

## Annahmen und Grenzen

- Kompaktierte Chatstände wurden nicht als vollständig rekonstruierbar behandelt.
- Ein beim Snapshot aktiver WS-10-Turn kann später neue Fakten liefern.
- Der Online-Screenshot diente nur zum Vergleich der Namensstruktur, nicht als Beweis für lokalen Inhalt.
- Es wurden keine Zugangsdaten in die Evidenz aufgenommen.

## Vorschlag für den nächsten freizugebenden Abschnitt

1. In WS-00 die drei UI-Entscheidungen treffen: Umbenennung, fehlende Chats, Umgang mit historischen Fehlzuordnungen.
2. Danach pro freigegebenem Arbeitsbereich einen kompakten Synchronisationsblock erstellen; keine vollständigen Verläufe kopieren.
3. Erst in einem separaten, ausdrücklich freigegebenen Auftrag über physische Runbook-Zuordnung oder Verzeichnisänderungen entscheiden.

## Ergebnisstatus

`PARTIAL`: Der lokale Chatbestand und die Dateistruktur wurden vollständig inventarisiert. Vier inhaltliche Chatstände bleiben wegen aktiver beziehungsweise kompaktierter Verläufe offen; drei kanonische Chats existieren noch nicht.
