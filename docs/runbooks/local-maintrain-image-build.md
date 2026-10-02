# Runbook: lokaler Image-Build im Hauptzug-Fenster

Stand: 2026-10-03, Inhaberentscheid Punkt 13 in #486 (Kommentar 5962586221).
Eigentümer: OB-30. Freigabe des Fensters: OB-00. Grundlage: ADR-0023, Nachtrag
2026-10-03 („befördern statt neu bauen“).

Der Normalweg ist CI: Das Image wird einmal auf `main` gebaut, getestet und von
`promote.yml` mit GitHub-Attestierung und SBOM veröffentlicht. Dieser lokale Build
ist die **dokumentierte Ausnahme**. Er ersetzt den Normalweg nicht.

## 1. Wann erlaubt, wann nicht

| erlaubt | nicht erlaubt |
|---|---|
| Hauptzug-Fenster (8, 9, …), in dem der Live-Server ohnehin aus ist und OB-00 das Fenster angekündigt hat | jeder Zeitpunkt, an dem ein `mangosd` läuft (live `ws50-roster-*` oder Teststack) |
| dringender Hotfix nur auf ausdrückliche Inhaber-Anweisung **„Server aus, lokal bauen“** | Hotfix-Züge ohne diese Anweisung: die laufen über CI |
| 08:00–23:30 UTC | 23:30–00:30 UTC (immer gesperrt); 00:30–08:00 UTC nur mit ausdrücklicher Inhaber-Anweisung (`--owner-night-order`) |
| ein Build zur Zeit, mit Sperrdatei `HOST-BUILD.lock` | parallel zu einem anderen Build-Container oder Deploy-Fenster |

Außerhalb dieses Fensters gelten die normalen Regeln unverändert: lokale Builds
mit `--cpus=4`/`-j4`, solange der Live-Server läuft, `--name <chat>-<task>`, keine
Builds in Deploy-Fenstern. 12–14 Kerne gibt es **nur** bei ausgeschaltetem Server.

## 2. Vorbereitung (einmal pro Zug)

1. **Eigene, vollständige Klon-Kopie**, kein Linked Worktree: `Dockerfile.core`
   kopiert `.git` in den Build, und der Revision-Header wird mit `git` in
   `/src/core` erzeugt. Ein Worktree hat nur eine `.git`-Datei mit einem Host-Pfad,
   der im Build nicht existiert. Das Skript lehnt Worktrees ab.
2. **LF-Zeilenenden.** Mit `core.autocrlf=true` (Windows-Standard auf dem Host)
   landen Shell-Skripte wie `entrypoint-mangosd.sh` mit CRLF im Image. Das Skript
   lehnt `core.autocrlf=true` ab.

   ```sh
   SRC="/y/backup twwow/workspace-relocation-20260902/builds/ob30-maintrain-src"
   git clone --config core.autocrlf=false https://github.com/Cilverkrow/twow-repo "$SRC"
   git -C "$SRC" checkout --detach <main-sha-des-zugs>
   git -C "$SRC" -c core.autocrlf=false submodule update --init --recursive
   git -C "$SRC" submodule foreach --recursive git config core.autocrlf false
   ```

   Für einen späteren Zug: `git -C "$SRC" fetch origin`, dann `checkout --detach`
   und `submodule update` wie oben.
3. **buildx prüfen**, weil die CPU-Begrenzung über `driver-opt` des
   `docker-container`-Treibers läuft (`cpu-period`, `cpu-quota`, optional `memory`,
   `memory-swap`; in buildx seit 0.12):

   ```sh
   docker buildx version
   docker buildx create --help | grep -i driver-opt
   ```

   Unsicherheit: Die Optionsnamen stammen aus der buildx-Doku zum
   `docker-container`-Treiber und wurden für diese Änderung nicht gegen die
   installierte Version ausgeführt. Beim ersten Lauf mit
   `docker buildx inspect <prefix>-maintrain-build` prüfen, dass
   `cpu-quota="1200000"` (bei 12 Kernen) unter „Driver Options“ steht, und
   während des Builds mit `docker stats buildx_buildkit_<prefix>-maintrain-build0`
   nachsehen, dass die CPU-Last bei etwa 1200 % gedeckelt ist.
4. **Speicher prüfen:** `docker info` zeigt den Speicher der Docker-VM. Die
   schweren Übersetzungseinheiten brauchen 1,5–2,5 GiB je Job. Unter etwa
   1,5 GiB × Kerne warnt das Skript. Ein OOM zeigt sich als `buildkitd`-EOF
   (siehe Kommentar in `Dockerfile.core`). Bei weniger als 18 GiB: nicht bauen,
   OB-00 melden.
5. **Registry-Anmeldung** nur für `--push`, und nur durch den Bediener selbst:
   `docker login ghcr.io` (Konto mit `write:packages`). Das Skript liest, zeigt
   oder speichert keine Zugangsdaten. Fehlt die Anmeldung, scheitert der Push
   und damit das Skript.

## 3. Ablauf

```sh
# Probelauf: alle Prüfungen ohne Docker, druckt die geplanten Befehle
ops/build/local-maintrain-image.sh --source "$SRC" --name-prefix ob30 \
    --cpus 12 --reason "Zug 9 Hauptzug, Fenster laut #319" --dry-run

# echter Lauf mit Push
ops/build/local-maintrain-image.sh --source "$SRC" --name-prefix ob30 \
    --cpus 12 --reason "Zug 9 Hauptzug, Fenster laut #319" --push
```

Das Skript (aus einem beliebigen Checkout aufrufbar, gebaut wird `--source`):

1. lehnt ab bei gesperrter Uhrzeit, unsauberem oder nicht vollständigem Klon,
   CRLF-Konfiguration, einem `origin`, der nicht
   `https://github.com/Cilverkrow/twow-repo` (oder `git@github.com:Cilverkrow/twow-repo.git`)
   ist (Fork-Klon), `HEAD` nicht auf `origin/main` (Ausnahme
   `--allow-unmerged`: nur Probe, nie deploybar), laufendem `mangosd`, laufendem
   fremdem Build-Container oder vorhandener Sperrdatei
   `Y:\backup twwow\workspace-relocation-20260902\builds\HOST-BUILD.lock`.
   `origin/main` holt das Skript vorher selbst frisch
   (`git fetch origin +refs/heads/main:refs/remotes/origin/main`, auch im
   Probelauf); ohne Netz lehnt es ab. Ein lokal verschobenes oder veraltetes
   `origin/main` zählt also nicht. Eine andere Referenz als `origin/main` lässt
   sich nicht angeben (`--main-ref` gibt es nicht);
2. legt die Sperrdatei an. Sie wird bei jedem Ende entfernt, auch nach einer
   Ablehnung oder einem fehlgeschlagenen Build. Ebenso stoppt das Skript bei
   jedem Ende den eigenen Builder (`docker buildx stop`), damit `buildkitd` die
   12–14 Kerne nicht weiter belegt. Der eigene Builder-Container aus einem
   abgebrochenen Lauf blockiert einen erneuten Lauf nicht;
3. legt den Builder `<prefix>-maintrain-build` (Container
   `buildx_buildkit_<prefix>-maintrain-build0`) mit `cpu-quota = Kerne × 100000`
   an oder verwendet ihn weiter. Ein vorhandener Builder mit anderer Quote wird
   nicht still benutzt: Das Skript nennt `docker buildx rm --keep-state …`
   (behält den Cache);
4. baut `deploy/docker/Dockerfile.core --target runtime` mit `BUILD_TYPE=Release`,
   `BUILD_JOBS=<Kerne>`, denselben OCI-Labels wie `publish.yml` (`revision`,
   `source`, `url`, `version=sha-<40>`, `title`, `licenses`, `created`), dazu
   `io.twow.core.revision=<core-gitlink>` und `io.twow.build.origin=local-maintrain`,
   mit `--provenance=mode=max --sbom=true`;
5. baut zusätzlich das Debug-Symbol-Image (`--target debug-symbols`,
   `ghcr.io/cilverkrow/mangosd-debug:local-sha-<40>`), **sofern** `Dockerfile.core`
   dieses Ziel hat. Das kommt mit dem Split-Debug-PR aus #486 (Entscheid 2b).
   Ohne dieses Ziel wird der Schritt übersprungen und im Log genannt;
6. pusht unter `ghcr.io/cilverkrow/{mangosd,realmd}:local-sha-<40>`. Der Präfix
   `local-` hält den Tag getrennt vom CI-Tag `sha-<40>`. Maßgeblich ist ohnehin
   nur der Digest;
7. stoppt den Builder-Container (`docker buildx stop`, der Cache bleibt) und
   schreibt `local-digest.json` (Felder wie `publish-digest.json`, dazu
   `builder: local-maintrain`, `deployable`, `reason`, Laufzeit, `origin_url`,
   `origin_main` = gefetchter `main`-Stand, `main_ref`) nach
   `--out-dir`, Standard
   `Y:\backup twwow\workspace-relocation-20260902\builds\<prefix>-maintrain-<sha12>`.
   Schlägt ein Build fehl oder fehlt ein Digest in den Metadaten, endet das
   Skript mit Code 1 **ohne** `local-digest.json`. Ein schon gepushtes
   Runtime-Image nennt die Fehlermeldung; es gilt als nicht erfasst und wird
   nicht deployt. Erneut laufen lassen.

Ohne `--push` wird das Image nur lokal geladen (`--load`). Der Docker-Exporter
kann keine Attestierungen tragen. Ein solches Image ist ein lokales Prüfartefakt
und **nie deploybar** (`"deployable": false`).

**Zeiterwartung (Schätzung, beim ersten Lauf messen und in #486 eintragen):**
- Kalt: In CI braucht der Compile 1507 Ziele bei `-j4` rund 58 Minuten. Bei 12–14
  Kernen sind lokal grob 15–25 Minuten plus Kontext-Upload und Runtime-Schichten
  zu erwarten, abhängig von CPU und Speicher des Hosts.
- Warm: Der ccache liegt im Zustand des Builders (`RUN --mount=type=cache,target=/ccache`)
  und überlebt `docker buildx stop` und `rm --keep-state`. Ein Folgezug mit wenig
  Core-Änderung braucht dann wenige Minuten.

## 4. Deploy-Regel für lokale Images

Für einen lokalen Build gibt es **keine GitHub-Attestierung**, denn ohne
GitHub-OIDC gibt es kein `gh attestation verify`. Stattdessen gilt:

1. **Digest nur aus `local-digest.json`**, nie über einen Tag auflösen. Wer
   Schreibrecht hat, kann Tags überschreiben. `deployable` muss `true` sein,
   `origin_url` muss auf `Cilverkrow/twow-repo` zeigen, und `revision` muss auf
   GitHub in `main` liegen:
   `gh api repos/Cilverkrow/twow-repo/compare/<revision>...main --jq .status`
   ergibt `identical` oder `ahead`.
2. **BuildKit-Provenance prüfen.** Die Befehle druckt das Skript am Ende:

   ```sh
   docker buildx imagetools inspect ghcr.io/cilverkrow/mangosd@<digest> --format '{{json .Provenance}}'
   docker buildx imagetools inspect ghcr.io/cilverkrow/mangosd@<digest> --format '{{json .SBOM}}'
   docker buildx imagetools inspect ghcr.io/cilverkrow/mangosd@<digest> --format '{{json .Image.Config.Labels}}'
   ```

   Die Provenance muss `target=runtime` und die Repo-Revision zeigen. buildx legt
   bei einem Git-Kontext `vcs:revision`/`vcs:source` in die Metadaten. Der genaue
   Feldpfad hängt von der buildx-Version ab; beim ersten Lauf festhalten. Die
   Labels müssen `org.opencontainers.image.revision=<sha>`,
   `io.twow.core.revision=<core-sha>` und `io.twow.build.origin=local-maintrain`
   zeigen. Der Core-SHA muss dem Pin des Zugs in #319 entsprechen.
3. **Quellcode-Test:** Für denselben `main`-Commit muss `build + test` in der CI
   grün sein. Das lokale Image selbst hat die CI-Smoke nicht durchlaufen. Deshalb
   gelten die Live-Akzeptanz mit `ops/live/live-smoke.sh` (mit
   `TWOW_LIVE_EXPECT_DIGEST=<digest>`) und ein bereitgehaltener Rollback-Digest.
4. **Vermerk in #319 und #486:** Digest, Inhalt von `local-digest.json`,
   Ausgabe der drei `imagetools`-Befehle (oder ihr Hash-Pfad unter
   `Y:\…\evidence\ws-40\…`), Bediener, Start-/Endzeit, Kerne.
5. Liegt später für denselben Commit ein beförderter CI-Digest mit Attestierung
   vor, wird beim nächsten Deploy dieser bevorzugt.

## 5. Aufräumen

- Der Builder-Cache wächst mit jedem Zug. Belegung ansehen:
  `docker buildx du --builder <prefix>-maintrain-build`.
- Begrenzen mit Obergrenze, damit der warme ccache bleibt:
  `docker buildx prune --builder <prefix>-maintrain-build --max-used-space 60gb -f`
  (buildx vor 0.17: `--keep-storage 60gb`). Das ist Löschen und braucht deshalb
  eine Einzelfreigabe. Nie `docker system prune` oder `docker builder prune -a`
  auf dem Live-Host.
- `docker buildx rm <prefix>-maintrain-build` (ohne `--keep-state`) verwirft den
  Cache ganz und braucht ebenfalls eine Einzelfreigabe. Dasselbe gilt für lokal
  geladene Images (`docker image rm <digest>`).
- Die Sperrdatei entfernt das Skript selbst, auch bei Abbruch durch eine
  Prüfung. Bleibt sie nach einem harten Abbruch (Stromausfall, `kill -9`)
  liegen: Inhalt prüfen (Chat, Start-UTC, PID) und nur mit Freigabe des
  eingetragenen Chats löschen.

## 6. Prüfung des Skripts

`test/contract/local-maintrain-image.contract.sh` prüft alle Sperren und die
Build-Befehlszeile gegen ein Fake-`docker` und ein Wegwerf-Repository, ohne
Docker-Daemon. Die Prüfung läuft im lint-Job von `ci.yml`. Lokal:

```sh
bash test/contract/local-maintrain-image.contract.sh
```
