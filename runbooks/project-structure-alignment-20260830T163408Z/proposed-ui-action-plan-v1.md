# Vorgeschlagener manueller UI-Aktionsplan v1

Task: `PROJECT-STRUCTURE-ALIGNMENT-01`  
Status: Vorschlag, nicht ausgeführt  
Benutzerfreigabe erforderlich: ja

## Sicherheitsregeln

- Keine Aktion aus diesem Plan ist durch den Alignment-Auftrag zur Ausführung freigegeben.
- Keine Chats löschen, verschieben, physisch zusammenführen oder in andere Chats kopieren.
- Die Legacy-Chats `Bot Anzahl einschätzen` und `Serverdateien gemeinsam nutzen` unverändert erhalten.
- Historische Inhalte ausschließlich über kompakte Querverweise anbinden.
- Vor jeder Neuanlage prüfen, dass auf derselben Projektseite noch kein Chat mit dem exakten kanonischen Titel existiert.
- Zukünftige `runbooks\workstreams`-Verzeichnisse nicht anlegen.

## Vorgeschlagene Reihenfolge

Die fachlichen Online-Chats werden zuerst umbenannt. WS-00 folgt als letzte Online-Umbenennung, damit `Workspace einrichten` während der vorherigen Schritte als erkennbarer Navigationsanker erhalten bleibt. Erst danach werden fehlende Chats angelegt. Lokal wird entsprechend zuerst WS-00 umbenannt und anschließend werden die drei fehlenden Bereiche angelegt.

### A. Online: sieben exakte Umbenennungen

1. `SSC Analyse und Entwicklung` → `SSC – Analyse und Entwicklung`
2. `Datenbankmigrationen Übersicht` → `Datenbank und Migrationen`
3. `Serverkonfiguration prüfen` → `Serverkonfiguration`
4. `Deployment Skripte beschreiben` → `Deployment und Skripte`
5. `Ollama Botpersönlichkeiten planen` → `Bot-Persönlichkeiten`
6. `Dokumentation anlegen TWoW Server` → `Dokumentation und Entscheidungen`
7. `Workspace einrichten` → `Projektsteuerung und Workspace`

Die Online-Chats `Bot Anzahl einschätzen` und `Serverdateien gemeinsam nutzen` werden nicht umbenannt.

### B. Online: zwei exakte Neuanlagen

#### Aktion 8 – WS-50

Titel:

```text
Build und Serverbetrieb
```

Exakter Eröffnungstext:

```text
Dieser Chat ist der kanonische Arbeitsbereich WS-50 für Build und Serverbetrieb. Hier dokumentieren wir Builds, Start-/Stop-Abläufe, Laufzeitdiagnosen, Betriebszustände und reproduzierbare Verifikationen. Konfigurationsänderungen bleiben in WS-30, Deployment-Automation in WS-40 und Referenz-/Backup-Themen in WS-60; hier werden sie nur verknüpft.
```

#### Aktion 9 – WS-60

Titel:

```text
Referenzserver und Backups
```

Exakter Eröffnungstext:

```text
Dieser Chat ist der kanonische Arbeitsbereich WS-60 für Referenzserver und Backups. Hier dokumentieren wir Referenzbestände, Freigabe- und Zugriffsregeln, Backup- und Restore-Verfahren sowie deren Verifikation. Deployment-Skripte bleiben in WS-40 und laufender Serverbetrieb in WS-50; hier werden sie nur referenziert.
```

### C. Lokal: eine exakte Umbenennung

10. `Analysiere TWoW-Projektstruktur` → `Projektsteuerung und Workspace`

### D. Lokal: drei exakte Neuanlagen

#### Aktion 11 – WS-30

Titel:

```text
Serverkonfiguration
```

Exakter Eröffnungstext:

```text
Dieser Chat ist der kanonische lokale Arbeitsbereich WS-30 für Serverkonfiguration. Hier prüfen und dokumentieren wir sanitisierte Server- und PlayerBot-Konfigurationen, Pfade, Ports und Laufzeitparameter. Datenbankänderungen bleiben in WS-20, Deployment- und Steuerskripte in WS-40 und beobachtete Betriebszustände in WS-50; hier werden sie nur referenziert.
```

#### Aktion 12 – WS-70

Titel:

```text
Bot-Persönlichkeiten
```

Exakter Eröffnungstext:

```text
Dieser Chat ist der kanonische lokale Arbeitsbereich WS-70 für Bot-Persönlichkeiten. Hier planen und dokumentieren wir Persönlichkeiten, Verhalten, Prompts, Gedächtnis und Dialogregeln. Die technische SSC-/PlayerBot-/LLM-Brücke bleibt in WS-10, Konfiguration in WS-30 und migrationspflichtige Persistenz in WS-20; hier werden sie nur verknüpft.
```

#### Aktion 13 – WS-80

Titel:

```text
Dokumentation und Entscheidungen
```

Exakter Eröffnungstext:

```text
Dieser Chat ist der kanonische lokale Arbeitsbereich WS-80 für Dokumentation und Entscheidungen. Hier pflegen wir projektweite Entscheidungen, ADRs, verbindliche Betriebsdokumentation und kanonische Indizes. Arbeitssteuerung und Übergaben bleiben in WS-00, fachliche Detaildokumentation beim jeweiligen Workstream; hier werden sie nur referenziert.
```

## Verifikationscheckliste nach einer später freigegebenen Ausführung

- [ ] Online sind genau neun kanonische Workstream-Titel vorhanden.
- [ ] Online sind `Bot Anzahl einschätzen` und `Serverdateien gemeinsam nutzen` unverändert vorhanden.
- [ ] Online beträgt die Gesamtzahl danach 11 Chats: neun kanonische plus zwei Legacy-Referenzen.
- [ ] Lokal sind genau neun kanonische Workstream-Titel vorhanden.
- [ ] Lokal beträgt die Gesamtzahl danach 9 Chats.
- [ ] Innerhalb einer Projektseite existiert kein kanonischer Titel doppelt.
- [ ] Die fünf neu angelegten Chats enthalten exakt die oben festgelegten Eröffnungstexte.
- [ ] Kein historischer Verlauf wurde kopiert, umgeschrieben oder physisch zusammengeführt.
- [ ] Kein Legacy-Chat wurde gelöscht oder umbenannt.
- [ ] Keine zukünftigen Workstream-Verzeichnisse wurden angelegt.
- [ ] Die tatsächlich ausgeführten Schritte wurden in einem neuen, separat autorisierten Handoff protokolliert.

## Begrenzter Rollback-Hinweis

- Bei einer fehlerhaften Umbenennung ausschließlich den betroffenen Titel manuell auf den unmittelbar vorherigen Titel zurücksetzen.
- Einen versehentlich neu angelegten Chat nur entfernen, wenn zweifelsfrei bestätigt ist, dass er leer ist und keine Arbeits- oder Historieninhalte enthält.
- Historische Chats niemals löschen, zusammenführen oder als Rollback-Ziel verwenden.

```text
HISTORICAL_CONTENT_POLICY=CROSS_REFERENCES_ONLY
COPY_OLD_CHAT_CONTENT=NO
REWRITE_OLD_CHAT_CONTENT=NO
DELETE_LEGACY_CHATS=NO
```
