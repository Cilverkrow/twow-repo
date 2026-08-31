# RNDBOT Persistent Active Roster – Implementation Contract Addendum R1

Status: verbindliche Vertragspräzisierung für eine mögliche spätere Implementierung. Dieses Dokument autorisiert und implementiert weder Source-, Config- noch Datenbankänderungen.

Baseline-Commit: `42b8a7f742548793910fe8880463aeeb71627fb9`

## 1. Vorrang und Scope

Dieses Addendum ergänzt die bytegleich bewahrten Analyseartefakte. Bei einem Widerspruch über den minimalen Implementierungsumfang hat dieses Addendum Vorrang. Insbesondere wird eine Änderung der Gruppensemantik beim absichtlichen Logout des realen Spielers **nicht** beiläufig Bestandteil der minimalen Rosterimplementierung. `MASTER_LOGOUT_GROUP_PERSISTENCE` bleibt ein separater Entscheidungs-, Implementierungs- und Testgegenstand.

Die minimale Rosterimplementierung darf ausschließlich die Identitätsrotation und den dadurch ausgelösten Austausch beziehungsweise Logout von Rosterbots verhindern. Sie muss garantieren:

- Lease, Rotation, Populationsregeln, `RandomizeFirst` und Loginfehler ersetzen niemals einen Rosterbot durch eine andere GUID.
- Ein fehlender, gelöschter, gesperrter oder nicht einloggbarer Rosterbot führt zu `DEGRADED`; es gibt keinen Ersatzkandidaten und keine automatische Neuauswahl.
- Gruppierte Rosterbots werden im normalen Spielbetrieb nicht rotations-, lease- oder populationsbedingt ausgeloggt oder aus ihrer Gruppe entfernt.
- `validIn` und andere Laufzeit- oder Aktualisierungstimer definieren keine Roster-Mitgliedschaft.
- Gewöhnliche AI-Drosselung darf AI-Ticks reduzieren, aber weder Mitgliedschaft noch Loginidentität, Gruppe oder persistente Charakterdaten verändern.

## 2. Operation-ID und idempotente Adminoperationen

`operation_id` ist ein global eindeutiger, kanonischer UUIDv4-Wert. Zulässig ist ausschließlich die kleingeschriebene ASCII-Darstellung `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`, wobei `x` eine Hexziffer und `y` eine der Hexziffern `8`, `9`, `a` oder `b` ist. Eine einmal verwendete `operation_id` darf nie für einen anderen logischen Request wiederverwendet werden.

Jede angenommene Adminoperation speichert neben `operation_id` einen `request_sha256`. Dieser Hash wird über den vollständigen, unten definierten kanonischen Admin-Request gebildet. In der Datenbank ist der Digest als exakt 32 rohe Bytes zu speichern; in Reports und Protokollen wird er als 64-stellige großgeschriebene Hexdarstellung ausgegeben.

Das Idempotenzverhalten ist verbindlich:

- Gleiche `operation_id` und bytegleich gleicher `request_sha256`: das bereits dauerhaft gespeicherte Ergebnis wird unverändert zurückgegeben. Es entstehen keine neue Rosterversion, kein weiterer Auditdatensatz, keine Pointeränderung und keine erneuten Login-/Logoutwirkungen.
- Gleiche `operation_id`, aber anderer `request_sha256`: fail-closed mit `OPERATION_ID_REQUEST_MISMATCH`. Es erfolgen keine Daten-, Pointer-, Roster-, Login- oder Logoutänderungen.
- Die Eindeutigkeit von `operation_id`, Requesthash, Operationsergebnis, Vorher-/Nachherhash und gegebenenfalls erzeugter Version muss in derselben Datenbanktransaktion dauerhaft festgeschrieben werden.

## 3. Kanonische Admin-Request-Serialisierung

### 3.1 Allgemeine Byte-Regeln

- Schemaversion: `1`.
- Zeichencodierung: UTF-8 ohne BOM.
- Zeilentrenner: ausschließlich LF, Byte `0A`; CR ist verboten.
- Jede Zeile, einschließlich der letzten, endet mit genau einem LF.
- Schlüssel/Wert-Trenner: ASCII `=`, Byte `3D`.
- Listenfeld-Trenner: genau ein TAB, Byte `09`.
- Leerzeichen vor oder nach Schlüsseln, Werten oder Trennern sind verboten.
- Unbekannte, fehlende oder doppelte Felder sowie unbekannte Operationstypen werden fail-closed abgelehnt.
- Eingabetext für Akteur und Begründung muss gültiges UTF-8 und bereits Unicode-NFC sein. Nicht-NFC-Eingaben werden abgelehnt und nicht stillschweigend normalisiert.
- `actor` ist nicht leer. `reason` darf leer sein.
- Textwerte werden als unpadded Base64url der NFC-UTF-8-Bytes serialisiert; Alphabet `A-Z a-z 0-9 - _`, kein `=`.
- Unsigned Integer werden dezimal ohne Vorzeichen und ohne führende Nullen serialisiert; allein der Wert null wird als exakt `0` geschrieben. Bereichsüberschreitung wird abgelehnt.
- Ein nullable Versionswert ist entweder ein positiver UInt64-Dezimalwert ohne führende Nullen oder das ASCII-Wort `null`.
- GUIDs sind UInt32 im Bereich `1..4294967295` und werden als exakt zehn Dezimalziffern mit führenden Nullen dargestellt.
- Listenordinale sind einsbasiert und werden als exakt zehn Dezimalziffern mit führenden Nullen dargestellt. Die erste Ordinale ist `0000000001`; Lücken und Duplikate sind verboten.

### 3.2 Exakte Feldreihenfolge

Der zu hashende Byte-Stream hat immer exakt diese Reihenfolge:

```text
ssc-rndbot-admin-request-v1
schema_version=1
operation_id=<canonical-lowercase-uuidv4>
operation_type=<INITIALIZE|EXPAND|ADD|REMOVE|REPLACE|ROLLBACK>
expected_current_version_id=<positive-u64-or-null>
actor_utf8_b64url=<unpadded-base64url>
reason_utf8_b64url=<unpadded-base64url-or-empty>
requested_target_count=<u32-decimal>
add_count=<u32-decimal>
add	<ordinal10>	<guid10>
...
remove_count=<u32-decimal>
remove	<ordinal10>	<guid10>
...
replace_count=<u32-decimal>
replace	<ordinal10>	<old-guid10>	<new-guid10>
...
rollback_version_id=<positive-u64-or-null>
```

Die Listenzeilen erscheinen unmittelbar nach der jeweiligen Count-Zeile und exakt so oft wie dort angegeben. Bei Count `0` folgt keine Listenzeile. Additionsreihenfolge ist semantisch und wird unverändert als neue Rosterreihenfolge angehängt. Remove-GUIDs müssen streng numerisch aufsteigend und eindeutig angeliefert werden. Replace-Zeilen müssen nach `old-guid` streng numerisch aufsteigend sein; alte und neue GUIDs müssen innerhalb ihrer jeweiligen Spalte eindeutig sein. Nichtkanonische Reihenfolge wird abgelehnt, nicht umsortiert.

Alle oben aufgeführten Scalarfelder sind auch dann vorhanden, wenn sie für einen Operationstyp nicht genutzt werden. Nicht genutzte Counts sind `0`, nicht genutzte Versionsfelder `null`. `requested_target_count` ist immer die erwartete Memberanzahl des erfolgreichen Nachzustands. `expected_current_version_id` ist nur für `INITIALIZE` `null`; für alle anderen Operationen ist er verpflichtend. `rollback_version_id` ist nur bei `ROLLBACK` gesetzt. Ein Operationstyp mit inkonsistenten Counts, Listen oder Versionsfeldern wird vor jeder Mutation abgelehnt.

`request_sha256` ist SHA-256 über genau diesen vollständigen Byte-Stream. Das Digestfeld selbst und das spätere Ergebnis sind nicht Bestandteil dieses Byte-Streams.

## 4. Kanonische Roster-Snapshot-Serialisierung

Der Hash eines geordneten Rosterzustands wird unabhängig vom Admin-Request gebildet. Die Regeln sind:

- Schemaversion: `1`.
- Ordinalbasis: `1`.
- UTF-8 ohne BOM, ausschließlich LF, abschließendes LF verpflichtend, CR verboten.
- Headerwerte verwenden `=`; Memberwerte verwenden genau ein TAB.
- `member_count` ist UInt32 dezimal ohne führende Nullen, außer `0`.
- Jede Ordinale und GUID wird nach den Regeln aus Abschnitt 3 als zehnstellige Dezimalzahl serialisiert.
- Ordinale müssen lückenlos bei eins beginnen; GUIDs müssen eindeutig sein.

Exaktes Format:

```text
ssc-rndbot-roster-v1
schema_version=1
ordinal_base=1
member_count=<u32-decimal>
<ordinal10>	<guid10>
...
```

Der leere Initialzustand besteht aus exakt 68 Bytes:

```text
ssc-rndbot-roster-v1
schema_version=1
ordinal_base=1
member_count=0
```

Auch nach `member_count=0` ist das abschließende LF vorhanden; es gibt keine Memberzeile. SHA-256 dieses exakten leeren Zustands ist `BA46C4A526EE8BBE3A640492A1167DE0A449D382FE129891BF38BA89E3DF293E`. Dieser Digest ist der kanonische Vorherhash, wenn noch kein Roster existiert. Snapshotdigests werden intern als 32 rohe Bytes und extern als 64-stellige großgeschriebene Hexwerte behandelt.

## 5. Laufzeitzustände

Desired Roster, Verfügbarkeit und tatsächlicher Onlinezustand bleiben getrennte Größen. Mindestens folgende Zustände sind verpflichtend:

| Zustand | Bedeutung |
| --- | --- |
| `DISABLED` | Feature ist ausdrücklich deaktiviert; kein Roster wird geladen und kein Rosterlogin initiiert. |
| `LOADING` | Current-Pointer, Version, geordnete Member und ihre Hashes werden geladen und vollständig validiert. |
| `STARTING` | Ein gültiges Desired Roster ist geladen; seine verfügbaren GUIDs werden deterministisch angemeldet. |
| `HEALTHY` | Desired, Available und Online erfüllen vollständig den gültigen Zielzustand. |
| `DEGRADED` | Desired Roster ist gültig, aber mindestens eine gewünschte GUID ist nicht verfügbar, fehlerhaft oder offline; kein Ersatz erfolgt. |
| `INVALID_FAIL_CLOSED` | Pointer, Version, Schema, Ordinale, GUID-Eindeutigkeit oder Hash ist ungültig; Admission und automatische Rosterwirkung bleiben gesperrt. |
| `SHUTTING_DOWN` | Neue Login- und Admin-Admission ist geschlossen; geordneter Shutdown läuft. |
| `STOPPED` | Die aktivierte Komponente ist vollständig beendet; keine Worker- oder Rosterwirkung besteht. |

Erlaubte Zustandsübergänge:

```text
DISABLED -> LOADING                    nur nach ausdrücklich konfigurierter Aktivierung
STOPPED -> LOADING                     bei ausdrücklich autorisiertem Start
LOADING -> STARTING | INVALID_FAIL_CLOSED | SHUTTING_DOWN
STARTING -> HEALTHY | DEGRADED | INVALID_FAIL_CLOSED | SHUTTING_DOWN
HEALTHY <-> DEGRADED
HEALTHY | DEGRADED -> INVALID_FAIL_CLOSED
LOADING | STARTING | HEALTHY | DEGRADED | INVALID_FAIL_CLOSED -> SHUTTING_DOWN
SHUTTING_DOWN -> STOPPED
STOPPED -> DISABLED                    bei ausdrücklich deaktivierter Konfiguration
```

Aus `INVALID_FAIL_CLOSED` gibt es keine automatische Reparatur, Neuauswahl oder Rückkehr nach `LOADING`. Ein erneuter Ladeversuch benötigt einen später ausdrücklich autorisierten administrativen Neustart beziehungsweise Reload. Timer dürfen ausschließlich Laufzeit-/Aktualisierungszustand beeinflussen, niemals Desired Membership.

Jede Statusausgabe enthält mindestens `state`, `roster_version_id`, `roster_sha256`, `roster_target`, `roster_available`, `roster_online` und eine deterministisch sortierte Diagnose je fehlender GUID. Beispiel: Ziel 50, verfügbar 49, online 49 ergibt `DEGRADED` und `AUTOMATIC_REPLACEMENT=NO`.

## 6. Noch nicht autorisiert

Dieses Addendum startet keine Implementierung, keine Migration, keinen Build, kein Deployment und keinen Prozess. Vor jeder späteren Mutation bleiben isolierter Migrationstest, vollständiger Rollbackplan, Source-/Config-/Schema-Abnahme sowie ein separates Gate erforderlich.

`MASTER_LOGOUT_GROUP_PERSISTENCE=AWAIT_SEPARATE_DECISION_AND_TEST`

`NEXT_IMPLEMENTATION_GATE=AWAIT_R1_PACKAGE_AUDIT`
