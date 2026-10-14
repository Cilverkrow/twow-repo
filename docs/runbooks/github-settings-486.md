# Runbook: GitHub-Einstellungen für #486 (Rulesets, Fork-Freigabe, Runner, Environment)

Stand: 03.10.2026, Phase B von #486, Schritt B0 (Plan `final.md` Abschnitt 4,
Inhaberentscheide vom 03.10.2026: Punkt 5 „ja mit Admin-Bypass“, Punkt 6 „ja“,
Punkt 12 „lhns bleibt write“).

**Aktualisiert 14.10.2026 (Inhaber, „merge freigabe bei grün immer zulassen“; Overlay Ä16):** In beiden
Branch-Rulesets ist die Regel `pull_request` entfernt (kein Pflicht-Review, keine PR-Pflicht, keine
Code-Owner-Prüfung). Das Merge-Tor sind die Required Status Checks. `creation`, `deletion`,
`non_fast_forward` und `release-tags` sind unverändert. Die JSON-Nutzlasten und die Beschreibung unten
entsprechen dem API-Stand vom 14.10.2026 (`gh api repos/Cilverkrow/<repo>/rulesets/<id>`: twow-core 24422501
`main-und-release`, twow-repo 24418335 `main-und-release-` mit Bindestrich am Ende). Abschnitte, die ausdrücklich den Stand vom 03.10. nennen (Ausgangslage), beschreiben den früheren Zustand.

**Ausführen nur durch den Inhaber (Cilverkrow).** Agenten bereiten vor und prüfen
lesend (Abschnitt 6); sie ändern keine Repo-Einstellungen. Jeder Schritt hat einen
Klickpfad (GitHub-Oberfläche, englische Beschriftung) und einen gleichwertigen
`gh api`-Befehl. Die JSON-Nutzlasten liegen neben dieser Datei in
`docs/runbooks/github-settings-486/` und werden mit `--input` übergeben. Kein Token
gehört in eine Datei oder in einen Befehl: `gh` nutzt die eigene Anmeldung.

Alle `gh api`-Befehle setzen die REST-API-Version ausdrücklich:

```text
-H "X-GitHub-Api-Version: 2022-11-28"
```

Die Befehle laufen aus dem Wurzelverzeichnis eines twow-repo-Checkouts, in dem
dieser PR gemergt ist (bash und PowerShell gleichermaßen; in PowerShell den
Zeilenumbruch `\` weglassen und alles in eine Zeile schreiben).

Ausgangslage, lesend geprüft am 03.10.2026:

| | twow-repo | twow-core |
|---|---|---|
| Rulesets | keine (`[]`) | keine (`[]`) |
| Fork-PR-Freigabe | `all_external_contributors` | `all_external_contributors` (im Plan noch `first_time_contributors`; inzwischen umgestellt) |
| Self-hosted Runner | 1: id **31** `k8s-twow-repo`, online (Phase A sah noch id 30, der Runner wurde also neu registriert) | 0 |
| Repo-Variablen | keine | keine |
| Environments | keine | keine |
| Collaborators | Cilverkrow `admin`, lhns `write` | Cilverkrow `admin`, lhns `write` |
| Actions | aktiv, `allowed_actions: all`, `sha_pinning_required: false` | gleich |

## 1. Rulesets (beide Repos)

### 1.1 Was sie tun und warum der Admin-Bypass nötig ist

Ein Branch-Ruleset für `main` und `release/**` und ein Tag-Ruleset für `v*`:

- kein Force-Push (`non_fast_forward`), kein Löschen (`deletion`);
- neue `release/**`-Branches legt nur an, wer den Bypass hat (`creation`);
- **seit 14.10.2026 keine `pull_request`-Regel mehr:** weder Pflicht-Approval noch Code-Owner-Review
  noch PR-Pflicht. Vom 03. bis 14.10. galt hier „1 Approval und Code-Owner-Review“. `.github/CODEOWNERS`
  (@Cilverkrow für `.github/`, `ops/ci/`, `deploy/docker/`) bleibt als Hinweis liegen, wird aber
  nicht mehr erzwungen;
- Required Status Checks, gebunden an die App **GitHub Actions** (`integration_id`
  15368). Ein gleichnamiger Status aus einer anderen Quelle zählt damit nicht;
- `v*`-Tags anlegen, verschieben, löschen darf nur der Admin.

**Warum Bypass für die Admin-Rolle** (`actor_type: RepositoryRole`, `actor_id: 5` =
Repository-Admin, `bypass_mode: always`):

1. (bis 14.10.) GitHub lässt niemanden den eigenen PR approven; alle PRs der Agenten laufen über
   das Konto Cilverkrow, den einzigen Code Owner. Ohne Bypass wäre kein solcher PR mergebar gewesen.
   Seit 14.10. gibt es keine Approval-Pflicht mehr, dieser Grund entfällt.
2. Hotfix-Züge (Ä15) brauchen den Merge sofort, wenn die CI grün ist, auch ohne
   zweite Person.
3. Release-Branches in twow-core (`release/<zug>.x`) werden vom Inhaber bzw. OB-00
   angelegt; die `creation`-Regel lässt das nur mit Bypass zu.

Folge für den Ablauf (seit 14.10.): Ein PR wird gemergt, sobald alle Required Status Checks
grün sind (`gh pr merge <nr> --squash`); `--admin` ist dafür nicht mehr nötig. Der Bypass der
Admin-Rolle bleibt für `creation` neuer `release/**`-Branches und für Notfälle; er erscheint im
Audit-Log und auf der Ruleset-Seite unter „Insights“. Bis 14.10. musste das Merge-Kommando
`--admin` enthalten.

Was die Rulesets **nicht** leisten (Grenze aus Phase A):

- Ein Required Check schützt vor Versehen, nicht vor einem böswilligen PR-Autor: der
  PR bestimmt seine eigene Workflow-Kopie. Darum zusätzlich der Policy-Test im
  lint-Job und `core-gitlink-trust` (wirken auf den gemergten Stand).
- Rulesets schützen nur `main`, `release/**` und `v*`. Wer Schreibrecht hat (lhns
  bleibt `write`, Punkt 12), kann andere Branches pushen und dort Workflows
  ausführen. Die wirksame Grenze für ausgelieferte Images ist die ref-gebundene
  Attestierungsprüfung im Deploy (B5).
- Weil die Agenten mit dem Konto des Inhabers arbeiten, haben sie technisch denselben
  Bypass. Die Grenze dort ist die Freigaberegel im Overlay (seit Ä16 vom 13.10.:
  Merge bei grüner CI ist Dauerfreigabe, alles andere bleibt Einzelfreigabe), nicht GitHub.

### 1.2 Required Checks

Die Namen sind die `name:`-Felder der Jobs (so erscheinen sie als Check-Runs),
abgeglichen mit dem PR-Lauf 37071577325 und den aktuellen Workflow-Dateien.

**twow-repo** (`.github/workflows/ci.yml`, alle Jobs laufen bei `pull_request`
ohne Pfadfilter):

| Check | Bemerkung |
|---|---|
| `lint` | enthält den Runner-Policy-Test (`Workflow runner policy`) und den `Core gitlink trust contract` |
| `core-gitlink-trust` | neu in diesem PR: gitlink muss in core `main` oder `release/*` liegen |
| `capacity preflight` | |
| `scope` | |
| `config provenance` | |
| `clientpatch tools` | |
| `dbcheck tools` | |
| `clientinventory tools` | |
| `go (bot-brain)` | |
| `bot-brain live integration` | |
| `bootstrap from empty` | |
| `build + test` | wird bei reinen Nicht-C++-Änderungen übersprungen; „skipped“ zählt als erfüllt |
| `compose up + smoke` | hängt an `build + test`; übersprungen = erfüllt. Kann gestrichen werden, wenn Merges nicht auf die Smoke warten sollen (die Deploy-Regel B5 verlangt sie ohnehin) |

Nicht required: `msvc compile-only` (nur per Dispatch).

**twow-core** (`.github/workflows/ci.yml`):

| Check | Bemerkung |
|---|---|
| `Build core (Debian trixie)` | |
| `Upstream ref is the one we claim to track` | |
| `Workflow runner policy` | neu mit dem Core-PR zu B0/B1/B2 (eigener Job `workflow-policy`, läuft bei jedem PR). Erst eintragen, wenn dieser PR auf core `main` liegt, sonst warten ältere Core-PRs ewig auf „Expected“ |

Nicht required: `Build core (MSVC, windows-latest)` (bei PRs übersprungen) und
`POSIX-only-Aufrufe in den Modulen` (`msvc-portability.yml` hat einen Pfadfilter;
ein Pfad-gefilterter Required Check bliebe bei anderen PRs ewig „Expected“).
Die Code-Owner-Prüfung ist seit 14.10. abgeschaltet (keine `pull_request`-Regel); `.github/CODEOWNERS`
bleibt ohne Wirkung liegen.

`strict_required_status_checks_policy: false`: der PR muss nicht auf dem neuesten
`main` stehen (sonst wäre nach jedem Merge ein neuer Voll-Lauf nötig).
`do_not_enforce_on_create: true`: ein neuer `release/<zug>.x` darf von einem
Pin-Commit geschnitten werden, auch wenn genau dieser SHA keinen eigenen Check-Lauf
hat. **Wird ein Job umbenannt, muss der Check im Ruleset mit umbenannt werden**,
sonst wartet jeder PR auf „Expected“.

### 1.3 Anlegen per Oberfläche

Für jedes Repo (`Cilverkrow/twow-repo`, `Cilverkrow/twow-core`):

1. Repo → **Settings** → **Rules** → **Rulesets** → **New ruleset** →
   **New branch ruleset**.
2. **Ruleset name**: `main-und-release`; **Enforcement status**: `Active`.
3. **Bypass list** → **Add bypass** → **Repository admin** → Modus **Always allow**.
4. **Target branches** → **Add target** → **Include by pattern** → `main`; nochmals
   **Include by pattern** → `release/**`.
5. **Rules** anhaken:
   - **Restrict creations**
   - **Restrict deletions**
   - **Require a pull request before merging** bleibt **aus** (seit 14.10.2026; bis dahin: Required
     approvals `1`, Dismiss stale approvals an, Require review from Code Owners an).
   - **Require status checks to pass** → **Do not require status checks on creation**
     an, **Require branches to be up to date before merging** aus → **Add checks**:
     jeden Namen aus 1.2 eintippen und als Quelle **GitHub Actions** wählen.
   - **Block force pushes**
6. **Create**.
7. Danach **New ruleset** → **New tag ruleset**: Name `release-tags`, `Active`,
   Bypass **Repository admin / Always allow**, Target **Include by pattern** `v*`,
   Rules **Restrict creations**, **Restrict updates**, **Restrict deletions**,
   **Block force pushes** → **Create**.

### 1.4 Anlegen per `gh api`

```bash
H='X-GitHub-Api-Version: 2022-11-28'
D=docs/runbooks/github-settings-486

gh api -X POST repos/Cilverkrow/twow-repo/rulesets -H "$H" \
  --input "$D/ruleset-twow-repo-branches.json"
gh api -X POST repos/Cilverkrow/twow-repo/rulesets -H "$H" \
  --input "$D/ruleset-tags.json"

gh api -X POST repos/Cilverkrow/twow-core/rulesets -H "$H" \
  --input "$D/ruleset-twow-core-branches.json"
gh api -X POST repos/Cilverkrow/twow-core/rulesets -H "$H" \
  --input "$D/ruleset-tags.json"
```

Nutzlasten:
[twow-repo Branches](github-settings-486/ruleset-twow-repo-branches.json),
[twow-core Branches](github-settings-486/ruleset-twow-core-branches.json),
[Tags `v*` (beide)](github-settings-486/ruleset-tags.json).

Ändern später: `gh api -X PUT repos/Cilverkrow/<repo>/rulesets/<id> -H "$H" --input <datei>`.
Notfall (Ruleset blockiert etwas Dringendes): Enforcement in der Oberfläche auf
`Disabled` stellen oder `gh api -X DELETE repos/Cilverkrow/<repo>/rulesets/<id> -H "$H"`
(Löschen = Einzelfreigabe).

## 2. Fork-PR-Freigabe (twow-core; twow-repo ist bereits gesetzt)

Wirkung: Workflows aus Forks laufen erst, nachdem ein Maintainer sie freigegeben hat
– für **alle** externen Beitragenden, nicht nur beim ersten PR. Vor jeder Freigabe die
Diffs unter `.github/` ansehen.

- Oberfläche: twow-core → **Settings** → **Actions** → **General** →
  **Approval for running fork pull request workflows from contributors** →
  **Require approval for all external contributors** → **Save**.
- `gh api`:

  ```bash
  gh api -X PUT repos/Cilverkrow/twow-core/actions/permissions/fork-pr-contributor-approval \
    -H 'X-GitHub-Api-Version: 2022-11-28' -f approval_policy=all_external_contributors
  ```

Am 03.10.2026 lieferte die lesende Abfrage für beide Repos bereits
`all_external_contributors`; der Befehl ist idempotent und dient dann nur als
Bestätigung.

## 3. Self-hosted Runner 31 `k8s-twow-repo` abmelden (twow-repo)

Reihenfolge ist wichtig: **erst den Pod bei lhns stoppen**, sonst registriert sich
der Runner neu (genau das ist zwischen Phase A, id 30, und heute, id 31, passiert).
Löschen = Einzelfreigabe; der Inhaber führt es selbst aus.

1. Mit lhns abstimmen: Runner-Pod/Deployment `k8s-twow-repo` stoppen und den
   Registrierungs-Token bzw. die Controller-Konfiguration für twow-repo entfernen.
2. Runner-Id prüfen:

   ```bash
   gh api repos/Cilverkrow/twow-repo/actions/runners -H 'X-GitHub-Api-Version: 2022-11-28' \
     --jq '.runners[] | [.id, .name, .status, .busy] | @tsv'
   ```

3. Abmelden:
   - Oberfläche: twow-repo → **Settings** → **Actions** → **Runners** →
     `k8s-twow-repo` → **…** → **Remove runner** → **Force remove this runner**
     (falls er noch online ist).
   - `gh api`:

     ```bash
     gh api -X DELETE repos/Cilverkrow/twow-repo/actions/runners/31 \
       -H 'X-GitHub-Api-Version: 2022-11-28'
     ```

4. Prüfen, dass 0 Runner übrig sind (Abschnitt 6) und dass `vars.CI_RUNNER` nicht
   existiert. Seit diesem PR wertet keine Workflow-Datei die Variable mehr aus; der
   Policy-Test lehnt jede Rückkehr ab.

## 4. Environment `release-publish` (twow-repo, Voraussetzung für PR C / B6)

Zweck: Der Quellcode-Build in `publish.yml` läuft künftig nur per `workflow_dispatch`
und nur nach Freigabe durch Cilverkrow, und nur von `main` oder einem `v*`-Tag.
Schützt vor Bedienfehlern, nicht vor Branch-Kopien (die Environment wirkt nur, wenn
die ausführende Workflow-Datei `environment: release-publish` deklariert).

- Oberfläche: twow-repo → **Settings** → **Environments** → **New environment** →
  Name `release-publish` → **Configure environment**:
  - **Required reviewers** an → `Cilverkrow` hinzufügen; **Prevent self-review** aus
    (der Inhaber startet den Dispatch selbst und gibt ihn selbst frei);
  - **Deployment branches and tags** → **Selected branches and tags** →
    **Add deployment branch or tag rule** → Typ *Branch*, Muster `main`; nochmals →
    Typ *Tag*, Muster `v*`;
  - **Save protection rules**.
- `gh api` (die Nutzer-Id 323250786 ist Cilverkrow, geprüft mit
  `gh api users/Cilverkrow --jq .id`):

  ```bash
  H='X-GitHub-Api-Version: 2022-11-28'
  D=docs/runbooks/github-settings-486
  gh api -X PUT repos/Cilverkrow/twow-repo/environments/release-publish -H "$H" \
    --input "$D/environment-release-publish.json"
  gh api -X POST repos/Cilverkrow/twow-repo/environments/release-publish/deployment-branch-policies \
    -H "$H" --input "$D/environment-policy-main.json"
  gh api -X POST repos/Cilverkrow/twow-repo/environments/release-publish/deployment-branch-policies \
    -H "$H" --input "$D/environment-policy-tags.json"
  ```

  Nutzlasten: [Environment](github-settings-486/environment-release-publish.json),
  [Regel main](github-settings-486/environment-policy-main.json),
  [Regel v*](github-settings-486/environment-policy-tags.json).

## 5. Was dieser PR selbst ändert (zur Einordnung)

- `.github/CODEOWNERS`: @Cilverkrow für `/.github/`, `/ops/ci/`, `/deploy/docker/`.
- `runs-on` ist in `ci.yml`, `publish.yml` und `nightly.yml` überall das Literal
  `ubuntu-latest` (bzw. `windows-2022` für den abgeschalteten MSVC-Job).
- `ops/ci/test-workflow-runner-policy.sh` (+ Fixtures, Allowlist
  `ops/ci/workflow-policy-allowlist.txt`) im lint-Job.
- Neuer Job `core-gitlink-trust` (`ops/ci/check-core-gitlink-trust.sh`).

## 6. Prüfung (nur lesend)

```bash
H='X-GitHub-Api-Version: 2022-11-28'
for r in twow-repo twow-core; do
  echo "== $r"
  # Rulesets vorhanden, Bypass und Bedingungen wie oben
  gh api repos/Cilverkrow/$r/rulesets -H "$H" --jq '.[] | [.id, .name, .target, .enforcement] | @tsv'
  # wirksame Regeln auf main (Typen und Required Checks)
  gh api repos/Cilverkrow/$r/rules/branches/main -H "$H" --jq '.[].type'
  gh api repos/Cilverkrow/$r/rules/branches/main -H "$H" \
    --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | [.context, .integration_id] | @tsv'
  # Fork-PR-Freigabe
  gh api repos/Cilverkrow/$r/actions/permissions/fork-pr-contributor-approval -H "$H"
  # 0 Self-hosted Runner
  gh api repos/Cilverkrow/$r/actions/runners -H "$H" --jq '.total_count'
  # keine Repo-Variablen (CI_RUNNER darf nie existieren)
  gh variable list -R Cilverkrow/$r
  # Rollen (lhns bleibt write, Punkt 12)
  gh api repos/Cilverkrow/$r/collaborators -H "$H" --jq '.[] | [.login, .role_name] | @tsv'
done
# Environment
gh api repos/Cilverkrow/twow-repo/environments/release-publish -H "$H" \
  --jq '{name, rules: [.protection_rules[] | {type, reviewers: [.reviewers[]?.reviewer.login]}], policy: .deployment_branch_policy}'
gh api repos/Cilverkrow/twow-repo/environments/release-publish/deployment-branch-policies -H "$H" \
  --jq '.branch_policies[] | [.name, .type] | @tsv'
```

Erwartet: je Repo 2 Rulesets (`main-und-release` Branch, `release-tags` Tag, beide
`active`); auf `main` die Typen `creation`, `deletion`, `non_fast_forward`,
`required_status_checks` (seit 14.10. ohne `pull_request`) mit den Checks aus 1.2 und
`integration_id` 15368; Freigabe `all_external_contributors`; `total_count` 0;
keine Variablen; Environment mit Reviewer Cilverkrow und den Regeln `main` (branch)
und `v*` (tag).

Funktionsprobe nach dem Anlegen (lesend bzw. ohnehin anstehend): Der nächste PR
zeigt die Checks als „Required“; ein `git push --force` auf `main` ohne Bypass würde
abgelehnt (nicht ausprobieren, die Regelliste oben genügt als Nachweis).
