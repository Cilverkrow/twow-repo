# AutoDonationPoints configuration and semantics

## Active file

- Path: `C:\TW\ComTW\server\mangosd.conf`
- Bytes: 69,531
- SHA-256: `90D6D7AE3CC7AF9216F8B17F21E5762C1ED9D39DCC329234832123BAB0D618FF`
- Block: lines 2083-2093

```ini
# AutoDonationPoints. Grants donation points (shop_coins) to real online players
# for time spent online, tracked per account. Requires the
# donation_point_progress table in the LOGIN database - see
# sql/logon/donation_point_progress.sql. Without it the feature still runs but
# progress is lost on every restart. FlushIntervalMs controls how often progress
# is written out; at worst that much time is lost on an unclean shutdown.

AutoDonationPoints.Enable = 1
AutoDonationPoints.IntervalMs = 3600000
AutoDonationPoints.Amount = 100
AutoDonationPoints.FlushIntervalMs = 300000
```

All four keys are present and uncommented. `Enable=1` means the feature is
configured to run on the next Worldserver start. No activation was performed by
this preflight.

## Shipped defaults

The tracked template is `C:\TW\ComTW\source\src\mangosd\mangosd.conf.dist.in`
(69,543 bytes, SHA-256
`AC8C7AFA0255DBCD0CF0C90E3A8173239F4D9CA189971759A2577D05B657A6A5`),
lines 2083-2093. Its defaults are:

```ini
AutoDonationPoints.Enable = 0
AutoDonationPoints.IntervalMs = 3600000
AutoDonationPoints.Amount = 1
AutoDonationPoints.FlushIntervalMs = 300000
```

## Keys, units, and validation

| Key | Type used by source | Unit | Source default | Current | Explicit validation |
|---|---|---|---:|---:|---|
| `AutoDonationPoints.Enable` | Boolean | none | `0` | `1` | True only for `true`, `TRUE`, `yes`, `YES`, or `1`; every other value is false. |
| `AutoDonationPoints.IntervalMs` | `int32` parsed by `atoi`, then assigned to `uint32` | milliseconds per grant period | `3600000` | `3600000` | Zero is replaced with `3600000` and logged. No other range check. |
| `AutoDonationPoints.Amount` | `int32` parsed by `atoi`, then assigned to `uint32` | donation points per completed period | `1` | `100` | No range check. Zero is accepted. Negative values convert to a large unsigned value. |
| `AutoDonationPoints.FlushIntervalMs` | `int32` parsed by `atoi`, then assigned to `uint32` | milliseconds between progress flush opportunities | `300000` | `300000` | No range check. Zero causes a flush attempt every World tick. |

There are no documented allowed ranges. The safely representable positive input
range through `GetIntDefault` is 1 through 2,147,483,647. Inputs outside signed
32-bit range rely on `atoi` overflow behavior and must be rejected operationally.
The runtime counters are `uint32`; arithmetic wraps modulo 2^32. With normal
intervals, each grant subtracts exactly one interval, not all elapsed intervals in
one loop.

## Reload behavior

`reload config` is registered at `Chat.cpp:545` for `SEC_ADMINISTRATOR` and calls
`HandleReloadConfigCommand` (`Commands.cpp:256-261`). That invokes
`sWorld.LoadConfigSettings(true)`, which calls `sConfig.Reload()` at
`World.cpp:857-877`. AutoDonationPoints reads all four keys directly from
`sConfig` on every World update, so a successful admin config reload is
technically sufficient. A restart is not required by the implementation.

The proposed activation procedure still uses a controlled restart to make the
database backup, DDL verification, config identity, startup, and rollback boundary
unambiguous.
