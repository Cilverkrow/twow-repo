

With  you also need Boost. Install the nine libraries the
module actually includes rather than the  meta-package - that one drags in
, which needs C++20 and does not build under Visual Studio 2019:



Then add  to the configure line.# Installing on Windows

Start to finish, for someone who has just unpacked this repository and has
nothing else set up yet. Written against the `playerbots-integration-gh`
branch.

**What is in the repository:** the server source and the full world database
(131 MB under `sql/base`, 186 files).

**What is not:** the client data. Maps, DBC and vmaps have to be extracted from
a game client — see step 4. You need a **Turtle WoW 1.18.1 client, build
7272**; a client that does not match will misbehave in a hundred small ways.

---

## 1. Prerequisites

| Component | Notes |
|---|---|
| Visual Studio 2022 | workload **Desktop development with C++** |
| CMake | 3.16 or newer, on `PATH` |
| MariaDB or MySQL | server plus the command line client, on `PATH` |
| **ACE 7.x or 8.x** | **not** bundled — install it and pass `-DACE_ROOT=` if CMake cannot find it |

MySQL, OpenSSL and zlib are bundled under `dep/windows`, and Recast, G3D,
libmpq and fmt under `dep/`. Those need no separate install. ACE is the one
dependency you have to supply yourself.

Installing ACE through vcpkg is fine — just point at it directly instead of
pulling in the whole toolchain, which would break OpenSSL as described below:

```
vcpkg install ace:x64-windows
cmake -B build -A x64 -DBUILD_PLAYERBOTS=ON -DUSE_EXTRACTORS=ON -DACE_ROOT=C:/vcpkg/installed/x64-windows
```

`FindACE.cmake` looks for `ace/ACE.h` under `${ACE_ROOT}` and `${ACE_ROOT}/include`
and for the library under `${ACE_ROOT}/lib`, which is exactly vcpkg's layout.
Watch the configure output for `Found ACE headers:` — if it is missing, nothing
else will work. At runtime `ACE.dll` has to sit next to `mangosd.exe`; vcpkg
keeps it in `installed/x64-windows/bin`.

> **The ACE version matters.** This tree is built as C++17, which removed
> dynamic exception specifications. ACE 6.x still uses them, so its headers
> produce a cascade of exception-specification errors in `WorldSocketMgr.cpp`
> and anything that includes it. That is ACE, not this code — the core's own
> headers contain no `throw()` at all, and patching them only moves the error.
> Verified working: **ACE 8.0.2**.

> **Do not add the vcpkg toolchain file.** The `if(WIN32)` branch of the
> top-level `CMakeLists.txt` deliberately pins MySQL, OpenSSL and zlib to the
> copies under `dep/windows` — `find_package(OpenSSL)` is only called on UNIX.
> Passing `-DCMAKE_TOOLCHAIN_FILE=...vcpkg.cmake` puts vcpkg's OpenSSL 3.x
> headers ahead of the bundled 1.1.1 ones while the hard-coded 1.1.1 import
> libraries still win at link time. The result is exactly two unresolved
> symbols, `OSSL_PROVIDER_load` and `SSL_get1_peer_certificate` — both of which
> the code guards by version and would otherwise never reference. If you have
> already configured with the toolchain, delete the build directory; the cached
> variables survive a re-run.

## 2. Configure and build

```
cmake -B build -A x64 -DBUILD_PLAYERBOTS=ON -DUSE_EXTRACTORS=ON
cmake --build build --config Release
```

Two flags matter:

- **`BUILD_PLAYERBOTS` defaults to `OFF`.** Leave it out and you get a server
  with no bots at all, with no warning anywhere — the module simply is not
  compiled in.
- **`USE_EXTRACTORS`** builds the tools you need in step 4. Skip it only if you
  already have `dbc`, `maps`, `vmaps` and `mmaps` from elsewhere.

`ALLOW_TURTLE_ADDONS` is already on by default. It has to stay on: without it
the client crashes with *"interface corrupt"* the moment you enter the world.

If the link fails on `World::FinalizePlayerbotsPostPlayerInfo` or
`Player_DispatchBotChatCommand`, the checkout predates the stub fix — pull, or
see `src/game/PlayerbotStubs.cpp`. Those two only ever surface with
`BUILD_PLAYERBOTS=OFF`, the one configuration nobody builds on Linux.

## 3. Install into one folder

```
cmake --install build --config Release --prefix C:\turtle-server
```

Do this rather than running from the build tree. On Windows the CMake files put
binaries **and** config files into the same flat directory, which is exactly
what the server expects — see the note on `aiplayerbot.conf` in step 6. Run
`mangosd.exe` straight out of `build\src\mangosd\Release\` and the configs sit
one directory above it, where nothing looks for them.

## 4. Extract the client data

Copy the extractors from `tools/` into your **client** directory and run them
there, in this order:

1. `extractor` — produces `dbc` and `maps`
2. `vmap_extractor`, then `vmap_assembler` — produces `vmaps`
3. `mmap` — produces `mmaps` (slow, an hour or more is normal)

Move all four resulting folders next to `mangosd.exe`.

## 5. Databases

Four of them: `tw_world`, `tw_char`, `tw_logon`, `tw_logs`.

```
mysql -u root -p < sql\create_databases.sql
```

Then import **every file in `sql\base`** into `tw_world`. This is the actual
world content — creatures, quests, items, the lot.

> There is a `sql\setup_databases.bat`, but read it before you trust it: it runs
> `create_databases.sql` and then everything in `sql\database_updates`, and
> **skips `sql\base` entirely**. If you use it, import the base data yourself in
> between the two.

The 95 migrations in `sql\database_updates` are applied by the server on first
start, provided `Database.AutoUpdate.Enabled` is on in `mangosd.conf`.

> **Caveat.** The auto-updater only works on a database built through it from
> the beginning. On a database restored from a full dump the `migrations` table
> does not line up with the files on disk, the updater replays old migrations
> until one fails on a duplicate key, and the server refuses to start. If that
> is your situation, keep it disabled and apply new migrations by hand,
> recording each one afterwards:
>
> ```sql
> INSERT INTO migrations (Name, Hash, AppliedAt)
> VALUES ('20260726112016_world', 'manual', NOW());
> ```

## 6. Configuration files

The build produces six templates ending in `.dist`. Copy each one and drop the
suffix:

| Template | Becomes |
|---|---|
| `mangosd.conf.dist` | `mangosd.conf` |
| `realmd.conf.dist` | `realmd.conf` |
| `rate.conf.dist` | `rate.conf` |
| `mods.conf.dist` | `mods.conf` |
| `aiplayerbot.conf.dist` | `aiplayerbot.conf` |
| `ahbot.conf.dist` | `ahbot.conf` |

Put your database credentials into `mangosd.conf` and `realmd.conf`.

### The one Windows-specific trap

The path to the bot configuration is resolved differently per platform
(`PlayerbotAIConfig.h`):

```cpp
#if PLATFORM == PLATFORM_WINDOWS
inline std::string _D_AIPLAYERBOT_CONFIG = "aiplayerbot.conf";
#else
inline std::string _D_AIPLAYERBOT_CONFIG = SYSCONFDIR "aiplayerbot.conf";
#endif
```

On Linux the directory is compiled in. **On Windows the path is relative**, so
`aiplayerbot.conf` has to sit in the working directory the server is started
from — next to `mangosd.exe` if you launch it normally. Get this wrong and the
server starts perfectly happily, logs one line saying the file could not be
opened, and runs with no bots. Following step 3 puts it in the right place
already.

### Switches that default to off

```
AiPlayerbot.Enabled = 1
LFT.BotFill.Enable = 1
SoloDungeonRepopAlive.Enable = 1
Leech.Enable = 1
```

## 7. Realm entry and an account

`create_databases.sql` creates the `realmlist` table in `tw_logon` but leaves it
**empty**. Insert a row with your server's name and address, and put the same
address into the client's `realmlist.wtf`.

Start `mangosd.exe` once and create your account from its console with
`account create`, then raise it with `account set gmlevel`.

## 8. Starting

`realmd.exe` first, then `mangosd.exe`. The first start takes a long time: the
migrations run and the bot travel graph is computed from scratch.

**Check that the bots came up properly.** The log has to contain

```
Loading TalentSpecs
```

with **no** `Error with premade spec link` lines after it. If instead you see
those errors and `No premade specs found!!` at the end, you are running an
`aiplayerbot.conf` from an older checkout that still carries the stock vanilla
talent links — every one of them is rejected against Turtle's reworked talent
trees, and the bots end up with no talents at all. Regenerate the file, or copy
the `AiPlayerbot.PremadeSpec*` block out of `aiplayerbot.conf.dist`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Client crashes with "interface corrupt" on entering the world | built without `ALLOW_TURTLE_ADDONS` |
| No bots anywhere, no error | built without `BUILD_PLAYERBOTS`, or `aiplayerbot.conf` not in the working directory |
| `AI Playerbot is Disabled. Unable to open configuration file` | `aiplayerbot.conf` is in the wrong place — see step 6 |
| `No premade specs found!!` | old `aiplayerbot.conf` with the stock talent links |
| Server refuses to start after applying migrations | auto-updater against a dump-restored database — see step 5 |
| World is empty, no creatures | `sql\base` was never imported |
