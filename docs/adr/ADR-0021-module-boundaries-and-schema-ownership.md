# ADR-0021: Module boundaries and per-module schema ownership

- Status: Proposed
- Date: 2026-09-01
- Primary: WS-10 / WS-20
- Relates to: ADR-0005 (incremental modularization), ADR-0007 (forward migrations), ADR-0024 (invariants 2 and 4)

## Context

The project has a module system already, inherited from the Penqle line, and it is
better than the code currently using it:

- `modules/` is discovered by `cmake/ConfigureModules.cmake`, which globs
  `modules/<name>/src` and links each module per `-DMODULES=static|dynamic|disabled`.
- `src/game/ScriptObjects.h` declares ~40 script base classes with virtual hooks —
  `PlayerScript` 40, `WorldScript` 12, `UnitScript` 11, `GameObjectScript` 11,
  `CreatureScript` 9, `ServerScript` 7, and smaller ones down to `FormulaScript`.
- `src/shared/Database/AutoUpdater.cpp` already scans
  `modules/<name>/data/sql/{auth,character,world}/` per module, gated by
  `Database.AutoUpdate.AllowedModules`, and tracks each file as
  `Module + ":" + SHA1(file bytes)` in the `migrations` table.

So per-module code, config and migrations are all supported **today**. What is missing
is *ownership*: nothing says which schema a module may write, and the fork's own
features do not use the system at all.

- `AutoWorldBuff` and `AutoDonationPoints` live inside `World::Update()`.
  `SoloDungeonRepop`/`Leech` live in the spell pipeline. None has a file of its own;
  each is marked only by a `// custom:` comment inside an upstream file.
- `mod-lft-botfill` is already one file (`src/game/LFT/LFTBotFill.cpp`, 648 lines) but
  sits in the core tree rather than in `modules/`.
- `src/modules/PlayerBots` is a separate static library behind its own
  `BUILD_PLAYERBOTS` option, outside `modules/` entirely. The project therefore runs
  **two parallel module systems**, with different discovery, linkage and migration
  rules.

## Decision

**One module system: `modules/`.** Every project feature is a module there, with
`src/`, `conf/`, `data/sql/` and `t/` (ADR-0025).

**Schema ownership is exclusive. One schema, exactly one owner.**

| Schema | Owner | Migrations from |
|---|---|---|
| `tw_world`, `tw_char`, `tw_logon`, `tw_logs` | upstream (`twow-core`) | core AutoUpdater, upstream files only |
| `cv_bots` | `mod-playerbots` | `modules/mod-playerbots/data/sql/` |
| `cv_ops` | `mod-donation`, `mod-worldbuff`, `mod-guildbank` | each module's `data/sql/` |

Upstream schemas are read-only to us (ADR-0024 invariant 2). A module migration that
names an upstream schema fails CI (`.github/workflows/lint.yml`, job `schema-ownership`).
Multiple modules may share `cv_ops`, but a table has exactly one owning module and its
migrations live only there.

**Features to extract into modules** (Phase 3): `mod-donation`, `mod-worldbuff`,
`mod-solo-dungeon` (all three currently spliced into upstream files), `mod-guildbank`,
`mod-lft-botfill` (moved out of `src/game/LFT/`), and `mod-playerbots` — promoted from
`src/modules/PlayerBots`, first and alone, since it retires the second module system and
the other extractions follow its pattern.

**Modules reach the core only through declared extension points.** A module prefers an
existing `ScriptObjects.h` hook. Where none fits, adding one is a **core edit** and goes
to `twow-core` as its own reviewed single-purpose commit — never bundled into the module
PR. The same applies to `src/game/ModuleSlots.h`, whose fixed per-`Player` `void*` slot
array currently holds two entries (`MODULE_SLOT_BOT_AI`, `MODULE_SLOT_BOT_MGR`, both
playerbots) and whose own comment states that claiming a slot "needs a line in the core".
Slots stay scarce and each keeps a named owner; there is no runtime collision check.

**Every module is individually switchable off** and the server still starts and plays
(ADR-0024 invariant 4). A feature that cannot be compiled out is not acceptable.

## Consequences

- Migration ownership becomes checkable rather than conventional; the existing
  `Module:SHA1` tracker needs no change to support it.
- Extracting the spliced features shrinks the core delta against upstream, which is the
  point of ADR-0020's split: what remains in `twow-core` is fixes and hooks, not features.
- Adding a core hook stays deliberately expensive. That is the intended pressure toward
  using the ~40 existing script classes before inventing a new seam.
- `BUILD_PLAYERBOTS` and the `src/modules/` tree disappear once promotion completes.
  Until then both systems coexist and both are built in CI.
- Moving tables out of upstream schemas into `cv_bots`/`cv_ops` is real migration work
  under ADR-0007, forward-only and replay-guarded, and it must not lose a bot
  (invariant 1). ADR-0016 persisted donation progress into `tw_logon`; that table is a
  named migration candidate for `cv_ops`, not a precedent to repeat.
- Three competing character-migration conventions collapse into the per-module one.

## Evidence

- `cmake/ConfigureModules.cmake`, `modules/CMakeLists.txt`, `modules/create_module.sh`
- `src/game/ScriptObjects.h`, `src/game/ModuleSlots.h`
- `src/shared/Database/AutoUpdater.cpp` (`MigrationTable`, `Database.AutoUpdate.AllowedModules`,
  `ProcessModuleUpdates`)
- `src/game/LFT/LFTBotFill.cpp` (648 lines), `src/modules/PlayerBots/CMakeLists.txt`
- `.github/workflows/lint.yml` (job `schema-ownership`)
- `docs/issues/00-refactor-plan.md` (Phase 3), `docs/adr/ADR-0024-project-invariants.md`

## Update 2026-09-01: the promotion happened

`src/modules/PlayerBots` is `modules/mod-playerbots`, and `BUILD_PLAYERBOTS` is gone.
`src/modules/` no longer exists; every module lives under `modules/`.

Two things came out differently from what was written above:

- **Static only**, and not because C++ forbids the alternative. The decisive reason is
  that the core's seam is resolved by the *linker*: `game.a` calls eleven free
  functions, and `PlayerbotStubs.cpp` supplies no-ops whenever the module is off, so a
  `.so` would leave the core calling the stubs — a server with no bots and no error.
  Two more reasons stack on top: the framework cannot express that
  `mod-dungeon-clear` depends on this module (dlopen is `RTLD_GLOBAL`, so on Linux it
  would resolve only if load order happened to be right), and a Windows DLL exports
  nothing the vendored tree has not marked, which it has not.
  `mod-playerbots.cmake` refuses dynamic linkage with that reason rather than failing
  at link time.
- **The link-time seam stays.** The plan called for deleting
  `src/game/PlayerbotStubs.cpp` first. Six of its eleven symbols are `BotActionLog_*`
  diagnostic probes called from twelve sites in `Unit.cpp` and `Spell.cpp`; six new
  entries in `ScriptObjects.h` to relocate logging is a bad trade, and dynamic linkage
  — the only reason the stubs were a blocker — was never available anyway.

The payoff landed as expected: `mod-dungeon-clear` dropped 25 hand-written include
directories, because `CollectModuleIncludeDirectories` now publishes them and linking
the target carries them across.

## Update 2026-09-01: `MODULES` defaults to `static`

It defaulted to `disabled`, and nothing in the tree passed `-DMODULES`: not
`Dockerfile.core`, not `docker-compose.yml`, not any CI job. So every image and every
pipeline build shipped with no modules compiled in at all.

That was survivable while `modules/` held one optional module. It stopped being
survivable when `AutoWorldBuff`, `AutoDonationPoints`, `Leech` and `SoloDungeonRepop`
left `World.cpp`, `Unit.cpp` and `Player.cpp` and became modules: four features that
were in the server before the extraction would have been absent after it, with nothing
failing to say so.

A module exists to be built. Turning them off is the special case, and the nightly
all-features-off job asks for it explicitly.
