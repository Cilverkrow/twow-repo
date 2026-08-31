# SSC-LLM-BRIDGE-V1-ENGLISH-CORRECTION

## Ergebnis

`V1_ENGLISH_CORRECTION_RESULT=PASS`

Die Korrektur wurde in einem neuen, isolierten Runbook aus dem vorab vollständig verifizierten Phase-1B-Bridge-Payload erstellt. Bestehende Phase-1A-, Phase-1B- und Production-Bridge-Phase-A-Pakete blieben bytegenau unverändert. Core-Source, produktive Configs und Produktions-EXE blieben unverändert; Phase B wurde nicht begonnen.

## Unveränderte Architektur und Grenzen

- serverfreier NDJSON-Child über `src/cli.mjs --run`;
- Bot-GUID `18281`;
- Modell `qwen2.5:7b`, Digest `845dbda0ea48ed749caafd9e6037047aa19acfcfd82e704d7ca97d631a0b697e`;
- genau eine aktive Inferenz, zwei Wartende, Ledger 64;
- keine Retries, kein Resubmit, kein Auto-Restart;
- kein Core-seitiger Ollama-Zugriff;
- keine Aktionen, Emotes, Befehle oder zusätzlichen Zustellkanäle;
- kein Game-Chat und keine Datenbankverbindung.

## English-only-Korrektur

Der versionierte Personality-Kontext wurde innerhalb des neuen Pakets auf `personality-context-profile-v1.json` angehoben. Bot-GUID, Race-/Class-IDs, Population-Key, leere Professions/Traits und die null Race-Variante blieben erhalten. Die Identitätsnamen und sämtliche laufzeitwirksamen System-, Personality- und Dialogregeln sind nun Englisch.

Die Regeln verlangen kurze englische First-Person-Dialogantworten unabhängig von der Eingabesprache. Sie verbieten weiterhin erfundene Eigenschaften, Berufe, Erinnerungen, Beziehungen und Vergangenheit sowie Aktionen, Emotes, Befehle, Tools, Datenbankzugriff oder sonstige externe Aktionen. Freier Text bleibt ausschließlich Dialogtext.

## Outputgrenze

Die bestehende Grenze von 240 Unicode-Codepoints und zwei Terminatorläufen bleibt bestehen. Zusätzlich gilt exakt `max_output_utf8_bytes=240`.

Der Sanitizer normalisiert zuerst den vollständigen String und prüft danach Codepoints und UTF-8-Bytes. Ein überlanger String wird vollständig mit `assistant_text_too_many_bytes` verworfen. Es findet kein Byte-Truncate statt; dadurch kann kein mehrbyteiliges UTF-8-Zeichen zerschnitten werden.

Automatisierte Grenztests bestätigen:

- 240 ASCII-Bytes werden akzeptiert;
- 241 ASCII-Codepoints werden durch die bestehende Codepointgrenze verworfen;
- 120-mal `é` ergeben genau 240 UTF-8-Bytes und werden akzeptiert;
- 121-mal `é` ergeben 242 UTF-8-Bytes und werden vollständig verworfen.

## Neue Pins und Hashes

| Artefakt | SHA-256 |
|---|---|
| `config/bridge-config-v1.json` | `D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902` |
| `context/personality-context-profile-v1.json` | `386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E` |
| `bridge/sha256-manifest.txt` | `814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B` |
| `bridge/package-entry-list.txt` | `628A10F7D0B5771A8BC0640B9DF6E7DE35F05F27C399C12D0EDE95694B05BD8F` |

Das Payload umfasst 50 Dateien; das Manifest enthält 49 Hashzeilen und schließt nur sich selbst aus. Vor und nach dem Live-Lauf bestanden Entry-Set und alle Manifesthashes ohne Fehler.

## Server-free Tests

`V1_ENGLISH_SERVER_FREE_TESTS=PASS`

- Node `v24.19.0`;
- 75 Tests, 75 bestanden, 0 fehlgeschlagen;
- keine Paketinstallation;
- nur lokale Mock-Listener;
- keine Live-Inferenz während des Testlaufs;
- Wallclock-Sprung-/monotone Deadline-, Queue-, Duplicate-, Mismatch-, Stale-, Consume-once-, Sentence-run-, English-rule- und UTF-8-Bytegrenztests enthalten.

Evidenz: `bridge/evidence/automated-test-result.json` und `bridge/evidence/automated-tests.tap`.

## Einmaliger kontrollierter Inferenznachweis

Preflight bestätigte exakt einen Listener auf `127.0.0.1:11434`, ein gültiges Payloadmanifest, die neuen Pins, keinen Instance-Lock und keinen bereits vorhandenen One-shot-Guard.

Es wurde genau ein deutscher Dialogrequest submitted:

- Request-ID: `a3fb954c-ca57-42a4-948a-b646dbb05b15`;
- Bot-GUID: `18281`;
- Input: `Was hast du heute vor?`;
- TTL: 45 Sekunden;
- genau ein Submit und ein Inferenzversuch;
- ausschließlich Statuspolling, kein Resubmit;
- erster Consume erfolgreich, zweiter Consume `already_consumed` mit `completion=null`;
- `max_active_observed=1`, `active=0` nach Abschluss;
- Shutdown `drain=true`, Worker gejoint, Instance-Lock entfernt.

Sanitizte Antwort:

> I plan to scout the outskirts for any signs of the undead creeping closer. Safety first, always.

Die Antwort ist Englisch, beginnt in der ersten Person, enthält 96 Codepoints und 96 UTF-8-Bytes, hat zwei Terminatorläufe und enthält keinen Action-/Emote-/Command-Präfix. Rohantwort: 393 Bytes. Gemessene Submit-bis-Ready-Latenz: 7.802,151 ms.

`V1_ENGLISH_LIVE_INFERENCE=PASS`

## Bewahrungs- und Unverändertheitsnachweis

| Paket | Unveränderter SHA-256 |
|---|---|
| Phase 1A | `2A39C09AACDC5CDEAD1CAC5EE78143D634A3FE006311DD1C67EC253115C1DE51` |
| Phase 1A Hardening | `BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11` |
| Phase 1B | `020BDBA7BDE016FEACD2E484818E02BFAD8BE792AD84735BDEA845C2A2D9A5C8` |
| Production Bridge Phase A | `A4EB4552EF029C41F61D9BF4F247332F0239A5058FC32EE7ECCF1961EAF79A9D` |

Die vier bereits vorhandenen Dirty-Tree-LLM-Debugdateien besitzen nach Abschluss weiterhin exakt die in Production-Bridge Phase A erfassten SHA-256-Werte. Die Produktions-EXE sowie `mangosd.conf` und `aiplayerbot.conf` stimmen weiterhin mit ihren freigegebenen Hashes überein.

Keine Core-Source- oder aktive Configänderung, kein Build, keine Kompilierung, kein Deployment, kein MariaDB-Zugriff, keine Spielprozesssteuerung und kein Game-Chat wurden durchgeführt. Ollama wurde weder gestartet noch gestoppt; ausschließlich die autorisierte Bridge-Modellinventur und der eine Inferenzversuch erfolgten.

Nach Erstellung und Prüfung des neuen Deliverable-ZIP wurde gestoppt. Phase B bleibt gesperrt, bis sie separat freigegeben wird.
