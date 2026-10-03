# Schnelle Hotfix- und Patch-Builds (#486): Entwurf

> **Status: Entwurf / proposed, nicht freigegeben.** Phase A von twow-repo#486 (nur Analyse und Plan).
> Nichts davon ist eingerichtet. Jeder Schritt in Abschnitt 4 braucht die ausdrückliche Freigabe des
> Inhabers; Einstellungen, Runner und Tokens bedient nur der Inhaber.
> Stand: 02.10.2026, twow-repo@048788cf, twow-core@e368599e (origin/main), `origin/release/8.x` wo genannt.
> Quellen: Datei:Zeile auf `origin/main`, gh-Run-IDs; Messwerte von OB-30 in #486.
> Nicht gemessen: lokaler Kalt-/Warm-Build mit 4 Kernen (braucht ein von OB-00 freigegebenes Fenster).

## 0. Sicherheitsbefund vorab (02.10.2026, lesend geprüft)

- In twow-repo ist ein Self-hosted-Runner registriert und **online**: id 30 `k8s-twow-repo`,
  Labels `self-hosted, Linux, X64, default`. Er gehört nicht zu diesem Plan; Herkunft vermutlich #168
  (Commit 27381670 „run the Linux jobs on the self-hosted runner“).
- `lhns` hat in beiden Repos die Rolle `write`. Rulesets: 0 in beiden Repos.
- Fork-PR-Freigabe steht auf `first_time_contributors`, nicht `all_external_contributors`.
- Workflows nutzen `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}`; die Variable ist derzeit leer.
- Folge: Ein PR, der eine Workflow-Datei auf `runs-on: self-hosted` ändert, kann nach einmaliger
  Freigabe auf Runner 30 laufen. Das betrifft nicht den Host-PC, aber fremde Infrastruktur und den
  Herkunftsnachweis. Empfehlung: Punkte 1, 5, 6 und 12 in Abschnitt 5 zuerst entscheiden.
## 1. Wo geht die Zeit hin

| Stufe (kritischer Pfad) | Median gemessen | Wichtigste Schritte | Quelle |
|---|---|---|---|
| Core-CI vor dem Merge | ca. 37 min | Compile 33 min bei -j4 (4 vCPU), 55 % ccache-Treffer, Cache 3,0/3,0 GB voll | Runs 37034772618 (PR), 37039277560 (Push main); core ci.yml:425 |
| Merge in core `release/8.x` | 0 min | **Startet keine Core-CI.** Core-CI baut den gepinnten SHA nur als PR-Merge-Ref. twow-repo baut ihn dagegen genau als Submodul (441d62e7) | core ci.yml:51-57; `origin/release/8.x` hat ebenfalls nur `push: [main]` |
| Pin-PR, repo-CI | ca. 58 min (46–66) | build+test 38 min (davon Compile 30 min bei 55 %), danach smoke 20 min (davon world-ready 15,6 min) | Runs 37039623283, 37029478051 |
| Merge, dann repo-CI auf `main` (läuft parallel zu publish) | ca. 57 min | **Dieselben 731 Fehltreffer wie im PR**, weil PR-Läufe keinen Cache speichern | Run 37044803296; ci.yml:2257-2264 |
| publish.yml | ca. 62 min (41–83), dazu 0–53 min Wartezeit | **Kalter Compile aller 1.507 Targets: 3504,7 s.** Export und Push von 1,06 GB (94 % Debug-Info). 110 s gha-Cache-Export, der nie trifft | Run 37044803023; publish.yml:27-31, 196-197; Dockerfile.core:119,128 |
| **Summe Core-Merge → Digest** | **ca. 120 min** | Rechnerische Spanne aus den Stufen: 87–200 min. Gemessene Züge: 110–175 min. Hotfix 8.9: 132 min ab Ende der Core-PR-CI (2 h 52 min ab deren Start), davon 19 min Wartezeit | wie oben |

**Wie oft dieselbe Änderung kompiliert wird:** pro Hotfix 6-mal oder öfter.
- 3-mal im Core, auf 2 verschiedenen Commits: PR gegen `release/8.x` (441d62e7), PR für den `main`-Zwilling (e368599e) und der Push auf `main`.
- 2-mal oder öfter im Repo: jeder Push auf den Pin-PR, dann der Push auf `main`.
- 1-mal kalt in publish.

Zwischen den Stufen wird nichts wiederverwendet, weder ein Artefakt noch ein Image.
- In zwei Wochen gab es 68 erfolgreiche publish-Läufe, aber nur 24 verschiedene Core-SHAs. 43 bis 44 Läufe (ca. 65 %, ca. 44 Runner-Stunden) haben einen Core neu kompiliert, der schon veröffentlicht war.
- Nur in 1 von 67 aufeinanderfolgenden Schritten hat sich ein Build-Eingang außerhalb von `core` geändert (`modules/`, `src/`, `cmake/`, `deploy/docker`).
- Der eigentliche Hebel ist deshalb: **jeden Build-Eingang nur einmal bauen.** Mehr CPU bringt wenig.

## 2. Variantenvergleich (1 = schlecht, 5 = gut)

| | V1: JIT-Runner im Container auf dem Live-Host | V2: lokaler buildx-Build, Push nach GHCR | V3: bei GitHub bleiben, einmal bauen, CI-Image befördern |
|---|---|---|---|
| Zeitgewinn Hotfix (geschätzt) | 3 (25–45 min, nur mit warmem lokalem Cache) | 3 (25–45 min, mit Vorbau bis 60) | 2,5 bei V3a (Median 20–25 min, bis ca. 75 bei publish-Wartezeit); **4 bei V3b (55–60)** |
| Tick-Risiko | 2: Compile und Link mit -g neben 180 Bots. WSL2 darf 16 GB plus 8 GB Swap nutzen, das bedeutet OOM-Gefahr für mangosd und MariaDB | 2: gleiches Risiko. `--cpus` ist kein buildx-Flag, ein Limit gibt es nur über einen eigenen `docker-container`-Builder | **5: läuft nie auf dem Host** |
| Sicherheit / Fork-PRs | 2: teilt Kernel und Daemon mit dem Live-Stack, Labels sind keine Grenze, PAT für den Controller | 3: kein Runner, aber ein langlebiger `write:packages`-PAT und ein privilegierter BuildKit-Container | 3,5: kein Host-Zugriff. Wer Schreibrecht hat, kann aber aus Branch-Kopien signierte Images pushen (das geht heute über publish.yml schon). Abhilfe: Attestierungsprüfung mit Ref-Bindung und wenige Schreibberechtigte |
| Wartung (Eigentümer OB-30) | 2: Runner-Image, buildkitd, Controller, Watchdog, Credential-Rotation | 3: Skript, Builder-Volume, buildx-Drift, nur der Inhaber kann pushen | 3: YAML, Contracts und Policy-Test in 2 Repos, jede Änderung zusätzlich nach `release/<zug>.x` |
| PC aus | 3: Job hängt bis zu 24 h und blockiert die publish-Gruppe | 4: Rückfall auf publish.yml | **5 für Build und Digest.** Deploy und Tick-Messung brauchen ohnehin den laufenden Host |
| ADR-0023:102-104 (Provenance + SBOM, „built once, promoted“) | erfüllbar | teilweise: BuildKit-Provenance ist möglich, aber es entsteht ein zweites Image pro SHA | **erfüllt, wenn promote ein SBOM ergänzt.** Der docker-Exporter von `ci-staged` (ci.yml:2355-2365) trägt keine Attestierungen |

Alle Varianten lassen die Pin-PR-CI (ca. 58 min) unverändert. Sie ist der größte verbleibende Block. Nur V3b entfernt den zweiten Compile auf `main`.

## 3. Empfehlung

**Empfehlung:** V3 einführen: bei GitHub bleiben, jeden Build-Eingang einmal bauen, das CI-Image befördern. Dazu kommen Sofortmaßnahmen. In Phase B gibt es keinen Self-hosted Runner.
- Runner 30 wird abgemeldet.
- V3b folgt erst, wenn Rulesets gelten und die Rechtefrage geklärt ist (Punkt 12).
- V1 kommt nur in einer eigenen Hyper-V-VM in Frage, und nur, falls Phase C das Ziel verfehlt.

| Core-Merge → Digest | heute | nach V3a + Sofortmaßnahmen | nach V3b |
|---|---|---|---|
| Hotfix | ca. 120 min (gemessen 110–175) | **ca. 95–100 min**, kaum Streuung, keine publish-Wartezeit | **ca. 60–65 min** |
| Hauptzug | ca. 125–180 min | **ca. 100–110 min** | **ca. 65–75 min** |

Annahmen:
- **V3a:** Pin-PR 58 min, dann main build+test ca. 38 min, dann promote 3–5 min.
- **V3b:** Pin-PR 58 min, dann promote 3–5 min.
- **Deploy-Freigabe** nach der Regel in B5. Wartet man stattdessen immer auf die main-smoke, kommen ca. 20 min hinzu.
- **Hauptzug:** niedrigere Trefferquote, world-ready 15,6 min bleibt.

## 4. Umsetzungsplan Phase B (jeder Schritt einzeln freigeben, Eigentümer OB-30)

Workflow-Änderungen gelten erst, wenn sie in `main` **und** im aktiven core-`release/*.x` liegen. Beim Schnitt eines neuen Release-Branches gehört `git diff origin/main origin/release/<zug>.x -- .github` auf die Checkliste.

**B0 Sicherheitsgrundlage (sofort, unabhängig von der Variante)**
- Dateien: `.github/CODEOWNERS` in beiden Repos mit `.github/workflows/** ops/ci/** deploy/docker/** @Cilverkrow`.
- Der Inhaber macht selbst:
  - Runner 30 `k8s-twow-repo` abmelden, abgestimmt mit lhns (Einzelfreigabe, Löschen).
  - Rulesets in beiden Repos für `main`, `release/**` und die Tags `v*` anlegen:
    - kein Force-Push, kein Löschen;
    - PR mit mindestens 1 Approval und `require_code_owner_review`;
    - Required Check mit der Quelle GitHub-Actions-App;
    - Bypass nur für den Admin;
    - `v*` nur durch den Admin.
  - Freigabe für Fork-PRs auf `all_external_contributors` stellen.
  - `vars.CI_RUNNER` bleibt leer.
  - Rolle von lhns nach Punkt 12 entscheiden.
- Grenze: Ein Required Check schützt vor Versehen, nicht vor einem böswilligen PR-Autor, denn ein Job gleichen Namens erfüllt ihn. Rulesets schützen nur `main`, `release/**` und `v*`.
- Risiko: niedrig. Ein Ruleset kann einen eigenen Direkt-Push blockieren, der Admin kann es umgehen.
- Prüfung (nur lesend):
  - `gh api repos/Cilverkrow/twow-repo/actions/runners` liefert 0 Runner.
  - `gh api repos/<r>/rulesets` ist nicht leer.
  - `gh variable list` ist leer.
  - `gh api repos/<r>/collaborators` zeigt die Rollen.

**B1 Vertragstest Runner-Politik (twow-repo und twow-core)**
- Dateien:
  - neu: `ops/ci/test-workflow-runner-policy.sh` mit den Fixtures `ops/ci/fixtures/workflow-policy/{ok,bad-*}.yml`;
  - ein Aufruf im lint-Job von `ci.yml`;
  - im Core eine Kopie mit Hash-Vergleich im Contract, ein Schritt in core-`ci.yml` und ein Cherry-Pick nach `release/8.x`.
- Ersetzt `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}` durch das Literal `ubuntu-latest` in `ci.yml`, `publish.yml` (64, 100, 222, 344) und `nightly.yml` (59, 152, 229, 347). Der Grund: vars sind auch in Fork-PRs sichtbar. Der Kommentar ci.yml:47-51 wird korrigiert.
- Prüfregeln (bash und awk, auf dem Host gibt es kein Python). Kommentarzeilen (`^\s*#`) werden vorher entfernt.
  1. In Workflows mit dem Trigger `pull_request` dürfen `runs-on:`-Werte und `labels:`-Einträge weder `self-hosted` noch ein Label aus der Allowlist enthalten. Erwähnungen im Fließtext sind kein Fehler. `runs-on` mit `vars.`, `inputs.` oder `fromJSON` ist verboten.
  2. `pull_request_target` und `issue_comment` sind verboten. `workflow_run` ist nur in Dateien aus der Allowlist erlaubt (heute leer), und dort nur mit Prüfung von `head_branch`, `event == 'push'` und `head_repository.full_name`.
  3. `runs-on` erlaubt nur `ubuntu-latest`, `ubuntu-24.04`, `windows-latest` und `windows-2022` (ci.yml:1401). `self-hosted` ist nur über `ops/ci/self-hosted-allowlist.txt` erlaubt (heute leer).
  4. Jede Workflow-Datei hat auf oberster Ebene einen `permissions:`-Block. Im Core betrifft das `ci.yml` und `msvc-portability.yml`, beide werden nachgetragen.
  5. Verschachtelte `**/.github/workflows/*.yml` werden als Warnung gemeldet, nicht als Fehler. Im Core sind das 7 Dateien: 4 unter `modules/mod-dungeon-clear/`, 3 unter `modules/mod-playerbots/`.
  6. Jede `bad-*`-Fixture muss scheitern, `ok.yml` muss bestehen.
- Zusätzlicher Required Check `core-gitlink-trust` in der repo-CI:
  - `git -C core fetch origin main 'release/*'`
  - `merge-base --is-ancestor <gitlink> origin/main || … origin/release/<zug>.x`
  - Ist der gitlink in keinem dieser Branches enthalten, schlägt der Check fehl.
- Grenze: Der Test schützt nur den gemergten Stand, nicht die Workflow-Kopie im PR. B0 ist deshalb Voraussetzung.
- Risiko: niedrig.
- Prüfung: Der Test läuft in der PR-CI grün. Eine absichtlich falsche Fixture lässt ihn scheitern. Ein gitlink auf `refs/pull/N/head` lässt `core-gitlink-trust` scheitern.

**B2 Sofortmaßnahmen im Core-CI**
- Datei: twow-core `.github/workflows/ci.yml`, als Cherry-Pick auch nach `release/8.x`.
- Änderungen:
  - Rechte: auf oberster Ebene `permissions: contents: read`. Der Job `build` bekommt zusätzlich `actions: write`, nur für die Bereinigung, wie in repo ci.yml:1646-1652. Der Bereinigungsschritt bekommt `env: GH_TOKEN: ${{ github.token }}`.
  - Cache-Bereinigung nur mit `if: success()`, nach einem erfolgreichen Save. Gelöscht wird nur innerhalb von `ccache-trixie-${{ github.ref_name }}-`, je Ref bleibt genau 1 Eintrag. Ein globales „keep 1“ wie in repo ci.yml:2296-2301 würde dazu führen, dass main und release sich gegenseitig den Cache löschen. Hintergrund: `Save ccache` läuft auch nach einem Fehlschlag (`if: always()`, core ci.yml:579).
  - Heute: 11,78 GB in 5 Einträgen, also 1,78 GB über dem Limit von 10 GB. Ziel: main 1 + release/8.x 1 (je ca. 2,93 GB) + vcpkg ≤ 9 GB.
  - `push: branches: [main, 'release/**']`. Damit bekommt release einen eigenen ccache-Key, und der gepinnte SHA wird als Push gebaut.
  - `-j ${CI_BUILD_JOBS:-4}` statt `$(nproc)`: nur ein Schutz für einen späteren Self-hosted Runner, auf Hosted-Runnern ohne Zeitgewinn (nproc=4).
- Der Inhaber macht: Ältere `release/*`-Cache-Einträge nach dem Branch-Schnitt einmalig löschen (Einzelfreigabe, Löschen).
- Risiko: niedrig, etwas mehr Runner-Minuten auf release.
- Prüfung: `gh api repos/Cilverkrow/twow-core/actions/cache/usage` liegt unter 9 GB. Ein Push auf release löst einen Lauf aus. Die ccache-Statistik steht im Log.

**B3 Sofortmaßnahmen in publish**
- Datei: `.github/workflows/publish.yml`.
- Änderungen:
  - `cache-from`/`cache-to type=gha,scope=core` entfernen (196-197; 110 s und 948 MB toter Cache pro Lauf).
  - Digest und Core-SHA (`git ls-tree HEAD core`) in die Job-Summary und in das Artefakt `publish-digest.json` schreiben.
  - OCI-Label `io.twow.core.revision` ergänzen.
  - Kommentar 42-54 korrigieren.
- Der Inhaber macht: die zwei alten buildkit-Cache-Einträge löschen (Einzelfreigabe, Löschen).
- Risiko: niedrig.
- Prüfung: Der nächste Lauf zeigt den Digest in der Summary. `imagetools inspect` zeigt das Label.

**B4 Build-Flags vereinheitlichen (Voraussetzung für das Befördern)**
- Dateien: `deploy/docker/Dockerfile.core` (builder), `ci.yml` (env 1666-1668, cmake 1922-1935, Kommentar 1716-1717) und `ops/ci/test-compiler-cache-key.sh`.
- Zwei Möglichkeiten:
  - (a) `DEBUG_SYMBOLS=OFF` überall, wie heute in der CI.
  - (b) Split-Debug: `objcopy --only-keep-debug` und `strip --strip-debug`. Die Symbole gehen **nur** als eigenes Artefakt oder als eigenes OCI-Artefakt mit (`mangosd-debug:sha-<40>`), nie als Layer des Runtime-Images.
  - Kosten von (b): -g in der CI ändert den ccache-Fingerprint (ci.yml:1816-1823) und vervielfacht die Objektgröße. Der Repo-Cache ist mit 4,1/4,0 GB und 90 Cleanups schon voll, das Budget liegt bei 9,07/10 GB. Vorher messen, `CCACHE_MAXSIZE` und das Budget anheben. Ein kalter Lauf nach der Umstellung ist zu erwarten.
- Außerdem zu prüfen und zu belegen:
  - Legt `cmake --install` mit `BUILD_TESTING=ON` Test-Binaries nach `/opt/turtle`?
  - Ändert `fetch-depth: 1` statt `0` die Datei `revision.h`?
- Der Inhaber entscheidet über die Debug-Symbole (Punkt 2).
- Risiko: mittel, denn die Fähigkeit zur Crash-Analyse ändert sich.
- Prüfung: ausschließlich in einem GitHub-hosted Job (`workflow_dispatch`, read-only). Er vergleicht für denselben SHA `revision.h` und die `stage/`-Dateiliste mit dem Runtime-Image und legt das Ergebnis als Artefakt ab. Kein lokaler Build, kein Pull auf dem Live-Host. Ziel-Image ca. 100 MB statt 1,06 GB.

**B5 Promote-Job: einmal bauen, CI-Image veröffentlichen (ein PR zusammen mit B6)**
- Datei: `ci.yml`, neuer Job `promote`.
- Bedingungen und Rechte:
  - `needs: build-and-test`.
  - `if: github.event_name == 'push' && github.ref == 'refs/heads/main' && github.repository == 'Cilverkrow/twow-repo'`.
  - Rechte nur auf Job-Ebene: `packages: write`, `id-token: write`, `attestations: write`.
- Ablauf:
  1. Die gitlink-Prüfung wie in B1 läuft erneut. Schlägt sie fehl, wird nichts gepusht.
  2. Tree-Vergleich `git rev-parse HEAD^{tree}` gegen den Tree des getesteten Pin-PR-Merge-Refs, mit Log-Eintrag.
  3. `docker load` von `core-image`. Die Labels prüfen: revision, source, version und `io.twow.core.revision`. `ci-staged` bekommt dafür `labels:`, denn Dockerfile.core hat kein `LABEL`.
  4. Push unter `sha-<40>` nach `ghcr.io/cilverkrow/{mangosd,realmd}`.
  5. `attest-build-provenance` ausführen, dazu ein SBOM (syft) mit `attest-sbom`.
  6. Digest, Tree-Vergleich und `smoke_pending=true` in die Summary und in `publish-digest.json` schreiben.
- **B5a:** Wird build-and-test übersprungen (`cpp=false`, ci.yml:359-405, 1640-1643), sucht promote den letzten Digest mit gleichem Build-Eingang (`HEAD:core` plus die Trees von modules/src/cmake/deploy/docker). Diesen taggt es per `docker buildx imagetools create` neu, ohne Compile. Commits, die über `paths-ignore` (ci.yml:105-112) laufen, bekommen kein neues Image. Deploy verwendet dann den letzten Digest weiter.
- Actions auf Commit-SHA pinnen, und zwar in `promote`, in `build-and-test` und in allen Jobs, von denen diese beiden abhängen. build-and-test hat `actions: write` und erzeugt jetzt das ausgelieferte Image.
- B5 und B6 kommen in **einen** PR. Andernfalls pushen promote und publish unterschiedliche Digests unter `sha-<40>`, und publish als Letzter gewinnt mit dem 1,06-GB-Image. Wenn sich das nicht vermeiden lässt, pusht promote bis B6 unter `ci-sha-<40>`.
- Deploy-Regel neu (OB-30-Runbook und `fill-digest.sh`):
  1. Den Digest nur aus dem Attestierungs-Subject oder aus `publish-digest.json` übernehmen, nie per Tag-Auflösung. Wer Schreibrecht hat, kann Tags überschreiben.
  2. Vor dem Pull ausführen: `gh attestation verify oci://ghcr.io/cilverkrow/mangosd@<digest> --repo Cilverkrow/twow-repo --signer-workflow Cilverkrow/twow-repo/.github/workflows/ci.yml --source-ref refs/heads/main --deny-self-hosted-runners`. Bei Variante 3(b) ist `promote.yml` der Signer, beim `v*`-Rückfall `publish.yml` mit `--source-ref refs/tags/v…`.
  3. Freigabe nur, wenn main build+test grün ist **und** entweder der Tree-Vergleich identisch und die Pin-PR-smoke grün war (geprüft per `gh run view --json jobs`) **oder** die main-smoke grün ist.
  4. Wird die main-smoke später rot: Deploy stoppen oder Rollback.
- Der Inhaber macht: nichts. Es gibt keinen PAT, das GITHUB_TOKEN reicht.
- Risiko: mittel.
  - Rulesets schützen nur main, release/** und v*.
  - Wer Schreibrecht hat, kann aus einem anderen Branch, einem PR im selben Repo oder per dispatch Workflows mit `packages:write`/`id-token:write` ausführen und signierte Images unter denselben Paketnamen pushen.
  - Das `if:` schützt nur vor Fehlkonfiguration.
  - Wirksam sind wenige Schreibberechtigte (Punkt 12) und die Ref-gebundene Attestierungsprüfung im Deploy.
- Prüfung:
  - `gh attestation verify` wie oben, mit `runner_environment=github-hosted`.
  - Merge → Digest in unter 45 min.
  - Der Vertragstest aus B1 lässt `promote` nur mit diesem `if` zu.

**B6 publish auf Rückfall umstellen, ADR anpassen (gleicher PR wie B5, ADR separat)**
- Dateien:
  - `publish.yml`:
    - `v*` taggt den beförderten Digest des getaggten `main`-Commits neu (`imagetools create`).
    - Ein Build aus Quellcode läuft nur noch per `workflow_dispatch`, und nur mit der Environment `release-publish` (Required Reviewer Cilverkrow, Deployment-Branches `main` und `v*`). Das schützt vor Bedienfehlern, nicht vor Branch-Kopien.
    - db-init und helm bleiben.
  - `nightly.yml`: `docker-from-source` bleibt der Nachweis, dass sich `--target runtime` aus Quellcode bauen lässt.
  - ADR-0023: „promote statt rebuild“.
- Der Inhaber macht: Er gibt die ADR-Änderung frei (Einzelfreigabe, ADR-Status).
- Risiko: niedrig.
- Prüfung: Ein `main`-Push erzeugt genau einen Core-Digest. Nightly bleibt grün.

**B7 (optional, erst nach B0, B5 und Punkt 12) V3b: PR-Artefakt befördern**
- Datei: `ci.yml`, ein zusätzlicher Pfad in `promote`.
- Bedingungen:
  - Der Squash-Tree ist gleich dem getesteten Merge-Ref-Tree.
  - Der Quell-Run erfüllt `event == pull_request`, `path == .github/workflows/ci.yml`, `head_repository.full_name == base` und `actor == triggering_actor == Cilverkrow`.
  - `head_sha` ist der finale PR-Head.
  - Alle Commits im PR wurden von Cilverkrow gepusht (Timeline prüfen).
  - Der sha256 des Artefakts steht in der Run-Summary und wird vor `docker load` verglichen.
  - Die gitlink-Prüfung aus B1 ist bestanden.
- Die Aufbewahrung von `core-image` wird auf mindestens 3 Tage erhöht.
- Risiko: mittel (Vergiftung über Artefakte). Nur mit Rulesets und eingeschränkten Schreibrechten, sonst muss der Inhaber das Restrisiko ausdrücklich annehmen.
- Prüfung: Merge → Digest in unter 10 min. Tree- und Hash-Vergleich stehen im Log.

**Notabschaltung** (gilt für Runner 30 und jeden späteren Runner; ausführen nur durch den Inhaber oder OB-00)
1. Runner abmelden: Settings → Actions → Runners → Remove, oder `gh api -X DELETE repos/Cilverkrow/<repo>/actions/runners/<id>`.
2. Bei Verdacht auf Missbrauch Actions vorübergehend abschalten: `gh api -X PUT repos/Cilverkrow/<repo>/actions/permissions -F enabled=false`.
3. Prüfen, dass `gh variable list` leer ist. Laufende Jobs mit `gh run cancel <id>` abbrechen.
4. Nur bei einem lokalen Runner (nicht Teil von Phase B):
   - Runner-Container und buildkitd stoppen.
   - Cache-Volume verwerfen (Einzelfreigabe, Löschen).
   - Controller-Zugang widerrufen.
   - Den Live-Stack auf fremde Container und Exec-Sitzungen prüfen (`docker ps -a`, Events).
5. Vermerk mit Run-IDs in #486.

**Phase C Messplan**
- Dauer: 14 Tage oder mindestens 3 Hotfixes und 1 Hauptzug, je nachdem, was länger dauert.
- Messgrößen pro Zug, aus gh-Run-Zeiten:
  - Core-Merge → Digest, jeweils mit genannter Basis;
  - jede Stufe (Pin-PR, main build+test, promote);
  - Wartezeit in der Concurrency-Gruppe;
  - Compiles pro Build-Eingang. Ziel auf der Repo-Seite: 1 mit V3b, 2 mit V3a, publish 0;
  - ccache-Trefferquote;
  - Cache-Belegung je Repo unter 9 GB nach jedem Push, mit Warnung in der Summary.
- Vergleichsbasis: Hotfix 8.9 mit 132 min ab Ende der Core-PR-CI sowie die Mediane aus Abschnitt 1.
- Ticks:
  - V3 kompiliert nicht auf dem Host. Gemessen wird nur der Deploy-Pull: 1,06 GB gegenüber ca. 0,1 GB.
  - Werkzeuge: `live-monitor.sh` (Host-Skript, nicht im Repo) und die Zeile `PerformanceLog.TickStats` in `perf.log` (ADR-0031:222-228). Gemessen werden Ticks/min und die p99-Tick-Latenz über ±10 min.
  - Gleiche Rosterphase (v24/180) und gleich lange Fenster.
  - Kein Pull-Fenster 23:30–00:30Z, Mi 00:00–00:45Z oder innerhalb 15 min nach einem mangosd-Start.
  - Pull und Restart getrennt messen: erst `docker pull`, frühestens 10 min später `up -d`.
- Image-Pflege: Nach der Live-Akzeptanz behält OB-30 die letzten 2 Core-Images (aktuell und Rollback). Ältere Images werden nur mit Einzelfreigabe per `docker image rm <digest>` entfernt.
- Falls V1 oder V2 doch pilotiert werden:
  - Limits: nur mit `--cpus=4 --memory=6g --memory-swap=6g --oom-score-adj=1000 --name <chat>-<task>` und `-j4`. buildx nur mit eigenem `docker-container`-Builder und CPU- und Speicher-`driver-opt` (Optionsnamen gegen die installierte buildx-Version prüfen). Der Standard-Treiber ist verboten.
  - Vorab-Prüfungen, sonst kein Start:
    - RSS des Live-Stacks (`docker stats --no-stream`) + 6 GiB ≤ 12 GiB;
    - kein fremder Build-Container läuft;
    - die Sperrdatei `Y:\…\builds\HOST-BUILD.lock` (Chat, Task, Start-UTC) existiert nicht;
    - kein Deploy-Fenster laut #319, nicht 23:30–00:30Z.
  - Ein Watchdog läuft getrennt von der Chat-Sitzung, zum Beispiel als Windows-Aufgabe. Er liest jede Minute die TickStats-Zeile. Fallen die Ticks/min in 2 aufeinanderfolgenden Intervallen um mehr als max(5 %, 2σ des 30-min-Vorlaufs ohne Build) oder liegt p99 über 1000 ms (ADR-0031-Budget), führt er `docker stop <chat>-<task>` aus. Ohne Watchdog kein Start.
- Akzeptanz: Hotfix in ≤ 100 min (V3a) bzw. ≤ 65 min (V3b), 0 verlorene Bots, keine Tick-Regression.

## 5. Offene Punkte und Entscheidungen für den Inhaber

1. Runner 30 `k8s-twow-repo` jetzt abmelden, abgestimmt mit lhns? (ja/nein)
2. Debug-Symbole im Produktions-Image:
   - (a) keine (`DEBUG_SYMBOLS=OFF`);
   - (b) Split-Debug als eigenes Artefakt oder OCI-Artefakt (größerer Cache nötig);
   - (c) wie heute im Image (dann ist kein Befördern möglich).
3. Promote-Pfad:
   - (a) als Job in ci.yml nach build+test: schneller, aber der Rechte-Job steht in einer Datei mit PR-Trigger;
   - (b) als eigene `promote.yml` mit `workflow_run` nach der ganzen CI: saubere Trennung, ca. 20 min langsamer.
4. Deploy-Regel ab B5 wie oben beschrieben (Attestierung mit Ref-Bindung, Digest nicht über den Tag, Tree-Vergleich plus Pin-PR-smoke oder grüne main-smoke)? Oder immer auf die main-smoke warten (ca. 20 min länger)? (Regel / immer warten)
5. Rulesets in beiden Repos für `main`, `release/**` und `v*` (1 Approval, Code-Owner-Review, kein Force-Push, Tags nur durch den Admin) sowie CODEOWNERS für Workflows, CI und Docker? (ja/nein)
6. Freigabe für Fork-PRs auf `all_external_contributors` stellen? (ja/nein)
7. ADR-0023 auf „promote statt rebuild“ ändern? `v*` taggt den beförderten Digest neu, ein Build aus Quellcode läuft nur per dispatch mit Environment-Review. (ja/nein)
8. Core-CI zusätzlich bei Push auf `release/**` auslösen, inklusive Cherry-Pick nach `release/8.x`? (ja/nein)
9. V3b nach B0, B5 und Punkt 12 einplanen? (ja/nein)
10. Ein lokaler Runner oder Host-Build (V1/V2) ist in Phase B ausgeschlossen. Er wird nur wieder geprüft, wenn Phase C das Ziel verfehlt, und dann nur in einer eigenen Hyper-V-VM ohne Laufwerksfreigaben. (ja/nein)
11. Actions in allen Workflows auf Commit-SHA pinnen und `sha_pinning_required=true` setzen? Für build-and-test und promote ist das schon Teil von B5. (ja/nein; eigenes Folge-Issue)
12. lhns nach dem Abmelden von Runner 30 in beiden Repos auf `triage` setzen oder entfernen? Bei „nein“ ist die Attestierungsprüfung aus B5 die einzige wirksame Grenze, und für B7 muss das Restrisiko ausdrücklich angenommen werden. (ja/nein)

Kein Schritt lag in der Verbotszone: Ich habe keine Tokens gelesen und keine Dateien, Branches, Runner oder Container angelegt oder geändert. Die Phase-A-Ergebnisse geben nur Datei:Zeile im jeweiligen `origin/main` an, `origin/release/8.x` ist ausdrücklich genannt.

## Prüfvermerk

- **Security übernommen:**
  - 1: B5-Risiko neu formuliert und Punkt 12 ergänzt.
  - 2: Attestierungsprüfung mit Signer-Workflow und Source-Ref, Digest nicht über den Tag.
  - 3: gitlink-Prüfung in B1 und promote.
  - 4: Approval, Code-Owner-Review und CODEOWNERS in B0.
  - 5: dispatch nur mit Environment.
  - 6: SHA-Pinning auch in build-and-test.
  - 7: B7-Bedingungen.
  - 8: Rechte für die Bereinigung.
  - 9: Cherry-Pick von B1.
  - 10: Split-Debug nicht als Layer.
  - 11: Zeitbasis wird jeweils genannt.
- **Feasibility übernommen:**
  - 1–5: B5 und B6 in einem PR; Literal in allen drei Workflows plus `windows-2022`; Regel 1 ohne Kommentare; Bereinigung je Ref mit `success()`; B5a für `cpp=false`.
  - 6–9: Zeitgewinn 20–25 min; Spanne 87–200; ADR-0023 korrekt zitiert, SBOM ergänzt; Labels.
  - 10: `v*` taggt neu.
  - 11: Tree-Vergleich.
  - 12: Cache-Kosten von (b).
  - 13–17: Präzisierungen.
- **Ops übernommen:**
  - 1–3: Speicherlimits und Builder-Treiber für den Pilot; Tag-Wettlauf.
  - 4 teilweise: Die Deploy-Regel wird mechanisch erzwungen. Ein **zwingendes** Warten auf die main-smoke habe ich nicht übernommen, weil es den Zeitgewinn von V3a aufheben würde. Es steht als Alternative in Punkt 4.
  - 5–7: Cache-Budget je Ref, Watchdog, Sperrdatei.
  - 8: B4-Prüfung nur auf einem Hosted-Runner.
  - 9–15: Pull-Fenster, Eigentümer OB-30 und Release-Checkliste, `-j` nur als Schutz, Debug-Artefakt, Image-Pflege, Schwelle mit Rauschanteil, Bewertung „PC aus“.
- **Nicht übernommen oder nur eingeschränkt:**
  - Ops-1/2: Die `driver-opt`-Namen sind unverifiziert und nur als „zu prüfen“ übernommen.
  - Ops-7: Die Sperrdatei gilt nur für einen möglichen Pilot, nicht für Phase B.
  - Ohne Neumessung habe ich keine weiteren Zahlen geändert. Die Schätzungen für V1/V2 sind als warm-cache-abhängig gekennzeichnet.
