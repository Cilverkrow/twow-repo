# RNDBOT Persistent Active Roster Analysis – Package Closure R1

Dieses Verzeichnis ist das korrigierte, ausschließlich dokumentarische R1-Payload. Es beginnt keine Implementierung.

## Bytegleich bewahrte Primärartefakte

- `REPORT.md` – SHA-256 `5D434F3B0E83A4B8ADBD758BA2B2F4ADA22D4FC2164E7F6AE1880FF171872444`
- `RESULT.txt` – SHA-256 `3AF7DFC3D5734D19A8B699AE1ADFF548636F6D2A0CF4E71436E8AC11D720E51C`
- `SOURCE-MATRIX.tsv` – SHA-256 `D7E062AA306A26B48848FAF0E47B48E4C426EE047858AC7F7764D0C2073409A1`
- `ANALYSIS.json` – SHA-256 `1EF7FAF0719CD6C7627CE00CAA072E14CBCD61CC47B92D45B17394EF87740C28`

`evidence/PRIMARY-ARTIFACT-PARITY.json` weist die Bytegleichheit gegen das vorherige Closure-Verzeichnis nach. Das bisherige Closure-ZIP bleibt extern unverändert unter seinem Hash `A03C9D7D42D5A8CE46D74598AAE27315F1FD8B6D8A03A7052241DD28745222B5` erhalten.

## R1-Korrekturen

- `IMPLEMENTATION-CONTRACT-ADDENDUM.md` definiert `operation_id`/`request_sha256`-Idempotenz, die exakte kanonische Hashserialisierung, die acht Laufzeitzustände, den minimalen Roster-Scope und die ausdrückliche Abgrenzung von `MASTER_LOGOUT_GROUP_PERSISTENCE`.
- `evidence/SOURCE-BLOB-MANIFEST.tsv` enthält nun 27 statt 26 kanonische Sourcepfade und ergänzt `src/game/World.cpp`.
- `evidence/BASELINE-SOURCE-BLOBS.zip` enthält dieselben 27 Pfade als kanonische Git-Blobbytes des Baseline-Commits.
- `evidence/WORKTREE-EOL-EXPORT.zip` enthält dieselben 27 Pfade als dokumentierten Windows-EOL-Export. Dieses Archiv ist kein kanonischer Blobnachweis.
- `evidence/SOURCE-ARCHIVE-AUDIT-R1.json` belegt Pfadgleichheit, Eintragszahlen, Archivhashes und die EOL-Abgrenzung.

Der ergänzte kanonische Blob ist:

```text
path=src/game/World.cpp
git_blob_id=951bdcf7f1e8782d5991e0e9cb3920a23412b4a2
byte_count=213593
sha256=8AF6E3AD004BE8F4AAC323C767DCA4BB7CE3E4E8A5B3EC6E208F4C6550CD6D85
commit=42b8a7f742548793910fe8880463aeeb71627fb9
```

## Belegstruktur

- `evidence/HUB-PREFLIGHT-R1.json`: aktueller Hub-, Registry- und Manifestnachweis.
- `evidence/PRIOR-PACKAGE-AUDIT.json`: Unverändertheitsnachweis des bisherigen Pakets und erneute Prüfung der stabilen 02C-R1-Baseline.
- `evidence/R1-BEFORE-STATE.json` und `evidence/R1-AFTER-STATE.json`: bytegenauer Source-/Config-Schutzvergleich für diesen Auftrag.
- `evidence/PREPACKAGE-VALIDATION-R1.json`: abschließende Payloadvalidierung vor der ZIP-Bildung.
- `evidence/previous-closure/`: bytegleiche historische Wrapperdokumente des bisherigen Pakets; sie sind nicht der aktive R1-Gate-Status.
- Die ohne R1-Suffix übernommenen Evidence-Dateien sind unveränderte historische Belege der Primäranalyse beziehungsweise des vorherigen Closure-Pakets.

## Manifest- und ZIP-Regel

`SHA256SUMS.txt` ist das vollständige interne Payload-Manifest und schließt sich selbst aus, da ein Selbsthash zyklisch wäre. Der äußere ZIP-Hash, die ZIP-Größe und die Eintragszahl stehen in der neben dem ZIP liegenden `.metadata.json`. Diese externe Auditdatei kann definitionsgemäß nicht Bestandteil genau des ZIPs sein, dessen Hash sie enthält.

`NEXT_IMPLEMENTATION_GATE=AWAIT_R1_PACKAGE_AUDIT`
