# clientpatch: build our client patch from versioned deltas

Stage 1 of the client patch pipeline (#409). The design is
[docs/design/client-patch-pipeline.md](../../docs/design/client-patch-pipeline.md),
in particular section 3.

**What it does.** It turns our own changes, kept in Git as small per-DBC
deltas, into client DBCs and an MPQ patch (`patch-X-v<N>.mpq`). Along the way
it produces:

- a field-level review of every change;
- a mandatory consistency check against the server's SQL;
- the changed server-side DBCs, for coupled releases;
- version, sha1/sha256 and `build-info.json`.

**What it never does.**

- It never commits client files: no DBC, MPQ or SQL export enters Git, and
  the build refuses output paths inside the repository unless they are
  ignored.
- It never touches a database except through read-only `SELECT`s that the
  operator runs.
- It never patches an executable.

The tool is Python 3.11+ **standard library only**, so it runs on Linux, in
the container and on Windows. The only external tool is the pinned `mpqcli`.

## Contents

| Path | What |
|---|---|
| `clientpatch/` | the tool (a Python package, `python -m clientpatch`) |
| `clientpatch.toml` | configuration: patch name, pinned mpqcli version and command lines |
| `bindings/<build>/<Dbc>.toml` | field layout of each DBC per client build (generated, reviewed) |
| `bases/<id>.toml` | fingerprints (sha256) of registered pristine client bases |
| `changes/<Dbc>/NNNN_*.csv` | **our changes**, as deltas |
| `changes/code-values.md` | values that live in code and not in `spell_template` |
| `consistency/*.toml` | rules pairing client DBC data with server SQL |
| `sql/sources.toml` | the read-only server queries the rules and deltas use |
| `templates/` | Nostalgia Launcher config and catalogue templates (placeholders only) |
| `tools/gen_bindings.py` | regenerates bindings from WoWDBDefs, cross-checked with the core |
| `tools/talentdelta.py` | writes a `Talent` delta from a talent list, after checking the tree layout (grid, collisions, arrows) and, with `--core`, the server sources |
| `tools/inputs/` | inputs of the generators (talent lists, committed base cells) |
| `tests/` | unit and end-to-end tests on **synthetic** mini DBCs |
| `Dockerfile` | Python + mpqcli built from the pinned source |

## Install

**Container (recommended).** Build the image from `ops/clientpatch/`, then
run it with the repository mounted, so the build records the git commit of
the deltas:

    docker build -t twow-clientpatch ops/clientpatch
    docker run --rm -v "<repo>:/repo" -w /repo/ops/clientpatch \
        -v "<work dir>:/work" twow-clientpatch check

The image builds mpqcli from its pinned commit (see `clientpatch.toml`). The
DBC, MPQ and SQL files stay in `<work dir>`, outside the repository.

**Windows without a container.** This is portable and needs no installer and
no PATH change:

1. Unpack a Python 3.11+ "embeddable package" (python.org) into a task
   directory, for example below
   `Y:\backup twwow\workspace-relocation-20260902\tools\` (the approved
   location, AGENTS.md).
2. Put `mpqcli.exe` **built or released from the pinned commit** next to it
   and pass it with `--mpqcli <path>`, or set `CLIENTPATCH_MPQCLI`.
3. Run `python -m clientpatch ...` from `ops\clientpatch`.

The version check refuses any other mpqcli build, with a clear message.
If you build mpqcli yourself, run cmake **from inside its source directory**:
its CMakeLists embeds the commit via `git rev-parse` in the current directory,
and a build started elsewhere reports `0.9.9-` and is refused.

**Extracting the base DBCs** (once per client, by the owner or OB-15, locally,
with the client mounted read-only):

    python -m clientpatch extract-base --client <client folder> --out <work>/base

This reads `DBFilesClient\*.dbc` from the base archives in load order
(`[base] archives` in `clientpatch.toml`: `dbc.MPQ`, `patch.MPQ`, `patch-2` …
`patch-9`). A later archive's copy replaces an earlier one (design 2.2). It
writes nothing to the client. The result, `<work>/base/`, is the **base
directory**. It contains:

- `extract-report.txt`: which archive every DBC came from;
- `foreign-archives.tsv`: every other `*.mpq` in `Data\` that is not a stock
  1.12 archive (for example Turtle's `backup.MPQ`, a community `patch-Y`, or
  an old copy of our own `patch-X`). Each entry records whether the archive
  loads **before** or **after** our patch, or in an **unknown** order, and
  which DBCs it carries. The build reads this file (see "Limits").

## Workflow

```text
check        ->  validate bindings, rules, sources, deltas (CI runs this; no client needed)
extract-base ->  pristine DBCs from the client archives + report of foreign archives
fingerprint  ->  register the pristine base once (hashes only, bases/<id>.toml)
roundtrip    ->  prove every bound DBC reads and writes back byte-identical
export-sql   ->  read-only TSV exports of the declared server tables
build        ->  deltas -> DBC -> review -> consistency -> MPQ + hashes
catalog      ->  Nostalgia assets.json entry for the built release
testpatch    ->  version file + probe addon only (transport test, no client data)
```

### Register the client base (once)

    python -m clientpatch fingerprint --base <work>/base \
        --id turtle-1.18.1-enUS --client "Turtle WoW 1.18.1 (build 7272), English" \
        --registered "2026-10-01, OB-15" --write
    python -m clientpatch roundtrip --base <work>/base

Commit `bases/turtle-1.18.1-enUS.toml`; it holds hashes, not files. `roundtrip`
must report every bound DBC as byte-identical. That is the acceptance check
for the bindings on the real client files, which the cloud session cannot see.

### Export the server tables (read-only)

    export CLIENTPATCH_MYSQL='docker compose -f deploy/compose/docker-compose.yml exec -T db mariadb --defaults-extra-file=<file with credentials> -B tw_world'
    python -m clientpatch export-sql --out <work>/sql

The command is yours: credentials stay outside Git and outside the tool.
Every query in `sql/sources.toml` must be a single read-only `SELECT`.

**Do not run the export against the live database under load.** The owner
has ~180 bots running (#319). Point `CLIENTPATCH_MYSQL` at a dump restored
into a throwaway container; at the very least use a read-only session
(`mariadb --init-command="SET SESSION TRANSACTION READ ONLY" …`). Stay
outside the measurement window 23:30–00:30 UTC.

### Build a release

    python -m clientpatch build --base <work>/base --sql <work>/sql \
        --server-dbc <server data/dbc, read-only> \
        --version 3 --label "shaman talents" --out <work>/release-3

The output directory contains:

| File | What |
|---|---|
| `patch-X-v3.mpq` | the patch, installed on the client as `Data\patch-X.mpq` |
| `server-dbc/*.dbc` | changed DBCs the **server** also loads: a coupled release, deployed only with owner approval (design 5.5) |
| `review.csv` | every field change: dbc, key, field, old, new |
| `consistency.csv` | every consistency finding and its status |
| `SHA256SUMS`, `build-info.json` | hashes (sha1 for Nostalgia, sha256), version, base, git commit, tool versions |

The build **stops** in these cases:

- the server's `data/dbc` is not byte-identical to the client base (design
  3.4 step 2 a: client and server were extracted from different clients);
- the base matches no registered fingerprint (a new or localised client, or a
  modified file);
- a DBC header disagrees with its binding;
- an archive outside the base that loads **after** our patch, or in an
  unknown order, carries a DBC we change. On that client it would silently
  override us (`foreign-archives.tsv`; an earlier one only warns);
- a delta is invalid, or a DBC differs in a way no delta declared
  (`undeclared.csv`);
- a consistency rule has a finding that is not accepted;
- mpqcli is missing or not the pinned version.

Two builds of the same input are **byte-identical**. The mpqcli flags drop
file times from `(attributes)`, and `tests/test_build.py` checks this.

### Transport test (stage 1)

    python -m clientpatch testpatch --version 1 --out <work>/testpatch-1

This builds an archive with only two things in it:

- `TWPatch/version.txt`, for humans;
- a tiny probe addon, `Interface\AddOns\TWPatchProbe\`. It is our own
  `.toc`/`.lua` and prints `TWPatchProbe: TWPatch v<N> loaded from
  patch-X.mpq` in chat at login.

The 1.12 client cannot read `version.txt` from Lua. Whether it loads addons
from a patch MPQ at all is exactly what this test shows; the fallback is the
sentinel texture of design 5.4. The archive contains no client data, so it
needs no base and no SQL. Use it for launcher tests T4/N1/N5 (design
section 8).

**A new or changed `patch-X.mpq` needs a full game restart.** `/reload` is
not enough, because the client opens its archives only at start-up. The same
applies to removing the file after a test.

### Nostalgia catalogue entry

    python -m clientpatch catalog --build-info <work>/release-3/build-info.json \
        --url-base https://<patch-host>/files

This prints the `assets.json` entry (version, url, sha1, size, `dest` =
`Data/patch-X.mpq`). The real catalogue lives on the patch host; see
[templates/README.md](templates/README.md).

## Delta format

`changes/<Dbc>/NNNN_<description>.csv` has one directory per DBC, and the
files are applied in name order:

```csv
op,key,field,value,note
# lines starting with # are comments
insert,90100,,copy:16039,new talent rank spell for the tooltip (#357)
set,90100,Name_lang_enUS,Earthen Bulwark,
set,90100,Description_lang_enUS,"Reduces damage taken by $s1%.\nCannot exceed 40%.",CV-1
set,90100,EffectBasePoints[0],sql:spell_template.effectBasePoints1,server is the source of truth
set,261,SpellRank[1],90101,rank 2
insert,3:7,,,dwarf shaman on the creation screen (#379)
```

- **`op`**: `insert` creates a row (empty value, or `copy:<key>` to start
  from an existing row); `set` changes one field. Deleting rows is not
  supported on purpose.
- **`key`**: the binding's key; composite keys are joined with `:`, as in
  `3:7` for CharBaseInfo (race 3, class 7).
- **`field`**: the column name as the binding expands it. Arrays become
  `Name[i]`; localised strings become `Name_lang_<locale>` plus
  `Name_lang_flags`. `python -m clientpatch columns <Dbc>` lists them.
- **`value`**: an integer (decimal or `0x`; masks may be written as `-1` or
  `0xFFFFFFFF`), a float, or text (`\n`, `\t` and `\\` are understood).
  `sql:<source>.<column>` takes the value from the server export for the same
  key.
- **`note`**: why the change exists: issue, `changes/code-values.md` entry.
  Every tooltip that shows a code-side value cites its `CV-` entry.

## Extending it

**Add a DBC.** Generate its binding and review the diff:

    python3 tools/gen_bindings.py --wowdbdefs <WoWDBDefs checkout> --core <twow-core checkout> \
        --build 1.12.1.5875 --out bindings/1.12.1.5875 <Dbc>

The generator takes the layout from WoWDBDefs. Where the core has a format
string (`src/game/Database/DBCfmt.h`), it cross-checks field count and
float/string positions, and **the core wins** where they disagree (the
server loads these files daily). It also sets `server_loaded` from the core's
`LoadDBCStores()`. Nothing else changes: deltas, diff, build and consistency
work on any bound DBC.

**Mirror server spells into Spell.dbc.** For spells that exist in
`spell_template` and need a client row (talent ranks, new player spells),
list them as `id,copy_from,class_mask,note` in `tools/inputs/<name>.csv` and run

    python3 tools/gen_spell_mirror.py --spells tools/inputs/<name>.csv \
        --out changes/Spell/NNNN_<name>.csv

Every column the `spell-matches-server` rule compares, plus texts, icon and
the remaining mapped columns (`EXTRA_PAIRS`), is written as a `sql:` value.
`copy_from` supplies locale flags and the other locales; `class_mask` is the
64-bit `spellFamilyFlags` split into `SpellClassMask[0..1]`, or `copy`.

**Add a consistency rule.** Add a `[[rule]]` to `consistency/*.toml`. There
are three kinds:

- `keys_in_dbc`: every server key must exist in the client DBC;
- `fields_equal`: paired columns must agree, with `scope = "all"` or
  `"changed"`, a float `tolerance`, and `skip_sql_value` for "keep the DBC
  value";
- `refs_in_sql`: DBC columns must reference existing server rows.

Known differences go into `[[rule.accept]]`, **with a reason**. An accept that
no longer matches is reported as stale.

**Add a server table.** Add a `[source.<name>]` with a `SELECT` and its key
column to `sql/sources.toml`.

**Support a new client build.**

1. Generate `bindings/<new build>/`.
2. Register the new base with `fingerprint`; its `build` names the binding
   directory.
3. Run `roundtrip` on the new base.

A base that matches no registered fingerprint is refused. A new client
therefore never silently reuses old bindings.

**Update mpqcli.** Change the pin in `clientpatch.toml` and the `Dockerfile`
together, then run `tests/test_build.py` with the new tool. The determinism
test must still pass.

## Tests

    python3 -m unittest discover -s tests          # from ops/clientpatch/

- The tests use only synthetic mini DBCs, which they generate with their own
  independent packer. **No real client file is used or committed.**
- The MPQ tests run when the pinned mpqcli is available (the container, PATH,
  or `CLIENTPATCH_MPQCLI`) and are skipped otherwise.
- CI runs the pure-Python tests and `check`.

## Limits

- Only the WDBC format (1.x–3.x clients) is supported, together with the
  layouts that have a binding.
- New DBC **columns** cannot be added; the client reads a fixed layout.
- Deleting rows is not supported.
- **No archive that loads after `patch-X` may carry DBCs.** That means
  `patch-Y`, `patch-Z` (Turtle's localisation slot) or any archive whose load
  order is unknown. The build stops when such an archive carries a DBC we
  change. Every friend's client must satisfy this: an English client with no
  late letter patches (design 2.2). `extract-base` reports it for the client
  it reads.
- `sql:` references need a single-column key.
- Values that live in server code are not visible to the SQL check. Keep
  them in `changes/code-values.md`.
- The bindings are verified against the core formats and on synthetic files.
  Their proof on the real client files is `roundtrip` on the registered base,
  run locally (stage 1 acceptance).
