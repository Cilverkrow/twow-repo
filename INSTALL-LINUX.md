# Installing on Linux

Written from a running install rather than from memory. Every version below is
one this tree is actually built and served on:

| | |
|---|---|
| Debian 13 (trixie) | gcc 14.2, CMake 3.31 |
| MariaDB 11.8 | ACE 8.0.2, Boost 1.83 |

Ubuntu 22.04 or newer works the same way; the package names are identical.

**What is in the repository:** the server source and the full world database
(131 MB under `sql/base`, 186 files).

**What is not:** the client data. Maps, DBC and vmaps come out of a game client
— see step 4. You need a **Turtle WoW 1.18.1 client, build 7272**.

---

## 1. Packages

```bash
sudo apt install build-essential cmake git libace-dev libboost-all-dev default-libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev mariadb-server
```

ACE has to be 7.x or newer. The tree is built as C++17, which removed dynamic
exception specifications, and ACE 6.x still uses them — its headers bury
`WorldSocketMgr.cpp` in errors. Debian 13 and Ubuntu 24.04 ship ACE 8.

## 2. Configure and build

```bash
git clone -b playerbots-integration-gh https://github.com/Shyalya/tortoise-wow.git
cd tortoise-wow
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/turtle -DBUILD_PLAYERBOTS=ON -DUSE_EXTRACTORS=ON
cmake --build build -j$(nproc)
```

**`BUILD_PLAYERBOTS` defaults to `OFF`.** Leave it out and you get a server with
no bots at all, with no warning anywhere — the module simply is not compiled in.

**Use `Release`.** A `Debug` build of this tree produces a `mangosd` binary well
over half a gigabyte and runs noticeably slower.

`ALLOW_TURTLE_ADDONS` is on by default and has to stay on, or the client crashes
with *"interface corrupt"* on entering the world.

### The install prefix is compiled in

Set `CMAKE_INSTALL_PREFIX` now and do not change it later. The path to
`aiplayerbot.conf` is baked into the binary at compile time:

```cpp
inline std::string _D_AIPLAYERBOT_CONFIG = SYSCONFDIR "aiplayerbot.conf";
```

`SYSCONFDIR` comes from `CMAKE_INSTALL_PREFIX/etc/`. Move the installation
afterwards and the server starts anyway, logs one line about not being able to
open the file, and runs with no bots. Changing the prefix means rebuilding.

## 3. Install

```bash
cmake --install build
```

Binaries land in `<prefix>/bin`, configs in `<prefix>/etc`.

## 4. Extract the client data

Run the tools from `build/` inside your **client** directory:

1. `mapextractor` — produces `dbc` and `maps`
2. `vmapextractor`, then `vmap_assembler` — produces `vmaps`
3. `MoveMapGen` — produces `mmaps`, and takes an hour or more

Warnings of the form `Can't find area flag for areaid ...` are normal: a few ADT
cells reference area ids that are not in `AreaTable.dbc`. Those cells end up
without an area flag, which only matters if a player stands exactly there.

Point `DataDir` in `mangosd.conf` at wherever you put the four directories.

## 5. Databases

Four of them: `tw_world`, `tw_char`, `tw_logon`, `tw_logs`.

```bash
mysql -u root -p < sql/create_databases.sql
```

That one file does more than its name suggests: besides creating the four
databases it brings 415 table definitions with it, the complete schema for
`tw_char`, `tw_logon` and `tw_logs` included. Only the world *content* is
kept separate, which is what `sql/base` holds — all 186 files there are
`tw_world_*`, so there is no `characters.sql` to look for.

Then import **every file in `sql/base`** into `tw_world` — that is the actual
world content. `sql/setup_databases.sh` exists but skips `sql/base` entirely, so
if you use it, import the base data yourself in between.

The 95 migrations under `sql/database_updates` are applied on first start when
`Database.AutoUpdate.Enabled` is on.

> **Caveat.** The auto-updater only works on a database built through it from the
> start. On one restored from a full dump the `migrations` table does not line up
> with the files on disk, the updater replays old migrations until one fails on a
> duplicate key, and the server refuses to start. Keep it off in that case and
> record migrations by hand:
>
> ```sql
> INSERT INTO migrations (Name, Hash, AppliedAt)
> VALUES ('20260726112016_world', 'manual', NOW());
> ```

> **MariaDB 11.8 and newer changed the default collation.** New databases get
> `utf8mb4_uca1400_ai_ci`, while dumps and SQL files written against older
> versions carry `utf8mb3_general_ci`. Mixing the two produces *"Illegal mix of
> collations"* on joins between such tables. If you hit that, align the tables
> rather than the queries:
>
> ```sql
> ALTER TABLE <name> CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;
> ```

## 6. Configuration

Copy each `.dist` in `<prefix>/etc` and drop the suffix:

| Template | Becomes |
|---|---|
| `mangosd.conf.dist` | `mangosd.conf` |
| `realmd.conf.dist` | `realmd.conf` |
| `aiplayerbot.conf.dist` | `aiplayerbot.conf` |
| `ahbot.conf.dist` | `ahbot.conf` |

Those four are all there is. `rate.conf` and `mods.conf` have templates in the
source tree but nothing reads them — `_RATE_CONFIG` and `_MODS_CONFIG` are
declared in `SystemConfig.h` and used nowhere. The rate settings live in
`mangosd.conf`.

Database credentials go into `mangosd.conf` and `realmd.conf`. Everything the
fork adds is off by default:

```
AiPlayerbot.Enabled = 1
LFT.BotFill.Enable = 1
SoloDungeonRepopAlive.Enable = 1
Leech.Enable = 1
```

`create_databases.sql` creates the `realmlist` table in `tw_logon` but leaves it
**empty**. Insert a row with your server's address, and put the same address in
the client's `realmlist.wtf`.

## 7. Running it

`realmd` first, then `mangosd`. Two systemd units and an ordering dependency are
enough. The world server wants a console: give it a FIFO and hold it open, or it
sees EOF immediately and shuts down.

```bash
mkfifo ~/turtle/mangosd.in
```

```ini
[Service]
Type=simple
User=turtle
WorkingDirectory=/home/turtle/turtle/bin
ExecStart=/bin/bash -c 'exec 3<>/home/turtle/turtle/mangosd.in; exec /home/turtle/turtle/bin/mangosd -c /home/turtle/turtle/etc/mangosd.conf <&3'
Restart=always
RestartSec=15
TimeoutStartSec=900
```

`exec 3<>` opens the FIFO read-write and keeps it open, so the server never sees
EOF. Console commands then go in from anywhere:

```bash
echo 'server restart 45' > ~/turtle/mangosd.in
```

`TimeoutStartSec=900` matters: the first start applies migrations and builds the
bot travel graph, which takes minutes.

## 8. Checking that it worked

The log must contain

```
Loading TalentSpecs
```

with **no** `Error with premade spec link` lines after it. If you see those and
`No premade specs found!!` at the end, the `aiplayerbot.conf` in use is from an
older checkout and still carries the stock vanilla talent links — every one of
them is rejected against Turtle's reworked trees, and the bots end up with no
talents at all.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Client crashes with "interface corrupt" | built without `ALLOW_TURTLE_ADDONS` |
| No bots, no error | built without `BUILD_PLAYERBOTS` |
| `AI Playerbot is Disabled. Unable to open configuration file` | the install was moved after building — `SYSCONFDIR` is compiled in |
| Server exits seconds after starting, no error | no console on stdin; see the FIFO above |
| `No premade specs found!!` | old `aiplayerbot.conf` with the stock talent links |
| `Illegal mix of collations` | MariaDB 11.8 default vs an older dump |
| Refuses to start after migrations | auto-updater against a dump-restored database |
| World is empty, no creatures | `sql/base` was never imported |
