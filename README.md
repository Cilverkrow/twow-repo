
# Tortoise-WoW

This is an unofficial, community driven, restoration of the 1.18.1 patch of Turtle-WoW, with some additions for solo play.  
This project is not to be used for profit or to misrepresent itself, or anyone using it, as the original creators  
This project targets version 1.18.1 build 7272

## About this fork

This repository is a fork of **[Penqle/tortoise-wow](https://github.com/Penqle/tortoise-wow)** (the upstream project described below), used to run a small private server. It differs from upstream in two ways:

1. **Playerbots are integrated and actually in use** — the integration comes from **[r-o-sh/tortoise-wow, branch `playerbots-integration-gh`](https://github.com/r-o-sh/tortoise-wow/tree/playerbots-integration-gh)**, which vendors [ike3's playerbots][20] under `src/modules/PlayerBots/`. Build with `-DBUILD_PLAYERBOTS=ON`; runtime activation is gated by `AiPlayerbot.Enabled` in `aiplayerbot.conf`.
2. **A handful of server-side features and fixes of my own** — automatic zone-restricted world buffs, hourly donation points, a beginners guild, several playerbot battleground fixes (queueing, combat, flag carriers), battleground graveyard resurrection, and a donation shop category fix. These are maintained separately as standalone patches at **[Shyalya/turtle-1.18-server-features](https://github.com/Shyalya/turtle-1.18-server-features)** so they can be applied to any compatible tree.

Upstream fixes are pulled in by merging `Penqle/main` periodically. Everything below is upstream's own documentation and applies to this fork as well, except where noted.

> **Note on the client:** the core must be built with `-DALLOW_TURTLE_ADDONS=ON`, otherwise the client crashes with "interface corrupt" when entering the world.

## Client Version

The client version targetted is patch 1.18.1, build 7272  
Any client that does not match this version or build will likely have a myriad of issues

## Additions
Additions will be added as the core code reaches feature completion

#### Current Additions

- **Autoscale** - Rudimentary toggleable dungeon/raid auto scaling system, found in mangosd.conf
- **Leech** - Basic toggleable leech system designed for solo play, found in mangosd.conf
- **Additional Talent Points** - Mostly used for testing, found in tw_char.characters
- **[Playerbots][20]** *(this fork)* - Integrated from [r-o-sh's branch](https://github.com/r-o-sh/tortoise-wow/tree/playerbots-integration-gh) and in active use. Upstream still lists this as planned/not ready.

#### Planned Additions

- **[Eluna][19]** - The WoW lua engine

## Operating Systems

* **[Windows][15]**, 32 bit and 64 bit. Windows Server 2008 (or newer) or Windows 8 (or newer) is recommended.
* **Linux**, 32 bit and 64 bit. [Ubuntu 22.04 LTS][14] is recommended. Other distributions with similar package versions will work, too.
Of course, newer versions should work, too. In the case of Windows, matching
server versions will work, too.

## Dependencies

* **[Git][1] / [Github for Windows][2]**: This version control software allows you to get the source files in the first place.
* **[MySQL][3]** / **[MariaDB][4]**: These databases are used to store content and user data.
* **[ACE][5]**: aka Adaptive Communication Environment, provides us with a solid cross-platform framework for abstracting operating system specific details.
* **[Recast][21]**: In order to create navigation data from the client's map files, Recast is used to do the dirty work. It provides functions for rendering, pathing, etc.
* **[G3D][6]**: This engine provides the basic framework for handling 3D data and is used to handle basic map data.
* **[Stormlib][7]**: Provides an abstraction layer for reading from the client's data files.
* **[Zlib][8]/[Zlib for Windows][9]** provides compression algorithms used in both MPQ archive handling and the client/server protocol.
* **[Bzip2][10]/[Bzip2 for Windows][11]** provides compression algorithms used in MPQ archives.
* **[OpenSSL][12]/[OpenSSL for Windows][13]** provides encryption algorithms used when authenticating clients.

To build this project follow any MaNGOS/MaNGOS Zero build guide, with the addition of ACE  

## Database Setup

1. Manually import sql/create_databases.sql
2. Manually import all sql scripts in the sql/base folder
3. Run mangosd to automatically import and track updates  

This will be streamlined once the core is more up to date

> **Caveat for this fork:** step 3 relies on the DB auto-updater
> (`Database.AutoUpdate.Enabled` in mangosd.conf). That works on a database
> built up through the auto-updater from the start. On a database that was
> instead restored from a full dump, the `migrations` table won't line up with
> the files in `sql/database_updates/`, and enabling the auto-updater makes it
> try to replay old migrations until one fails on a duplicate key — the server
> then refuses to start. If that applies to you, keep it disabled and apply new
> migration files by hand, recording each one afterwards:
>
> ```sql
> INSERT INTO migrations (Name, Hash, AppliedAt)
> VALUES ('20260726112016_world', 'manual', NOW());
> ```

## Contributing

**For this fork:** improvements to the core itself are best directed at
[upstream](https://github.com/Penqle/tortoise-wow) rather than here — this fork
exists to run a private server and only tracks upstream plus the additions
listed at the top. The standalone server features live in their own repo:
[Shyalya/turtle-1.18-server-features](https://github.com/Shyalya/turtle-1.18-server-features).

Upstream's note follows:

> Contributions are welcome, but I may be slow to review and merge PRs
>
> See `CONTRIBUTING.md` for ways to get started.


[1]: http://git-scm.com/ "Git - Distributed version control system"
[2]: http://windows.github.com/ "github - windows client"
[3]: https://dev.mysql.com/downloads/ "MySQL - The world's most popular open source database"
[4]: https://mariadb.org/download/ "MariaDB - An enhanced, drop-in replacement for MySQL"
[5]: http://www.dre.vanderbilt.edu/~schmidt/ACE.html "ACE - The ADAPTIVE Communication Environment"
[6]: http://sourceforge.net/projects/g3d/ "G3D - G3D Innovation Engine"
[7]: http://zezula.net/en/mpq/stormlib.html "Stormlib - A library for reading data from MPQ archives"
[8]: http://www.zlib.net/ "Zlib"
[9]: http://gnuwin32.sourceforge.net/packages/zlib.htm "Zlib for Windows"
[10]: http://www.bzip.org/ "Bzip2"
[11]: http://gnuwin32.sourceforge.net/packages/bzip2.htm "Bzip2 for Windows"
[12]: http://www.openssl.org/ "OpenSSL - The Open Source toolkit for SSL/TLS"
[13]: http://slproweb.com/products/Win32OpenSSL.html "OpenSSL for Windows"
[14]: http://www.ubuntu.com/ "Ubuntu - The world's most popular free OS"
[15]: http://windows.microsoft.com/ "Microsoft Windows"
[19]: https://github.com/ElunaLuaEngine/Eluna
[20]: https://github.com/ike3/mangosbot-bots
[21]: http://github.com/memononen/recastnavigation "Recast - Navigation-mesh Toolset for Games"
