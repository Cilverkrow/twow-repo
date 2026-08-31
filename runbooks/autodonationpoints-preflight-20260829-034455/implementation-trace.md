# AutoDonationPoints implementation trace

## Primary implementation

- `C:\TW\ComTW\source\src\game\World.cpp`
  - Bytes: 218,813
  - SHA-256: `1BCAE4A208726DA52076E54B422648C19BCA20A68C7017EB492122D065209E89`
  - `World::Update(uint32 diff)`: starts at line 2628.
  - Feature block: lines 2890-2997.
  - Config reads and zero-interval guard: 2906-2924.
  - Global flush timer: 2926-2933.
  - Eligible session iteration: 2935-2955.
  - First-seen progress load: 2957-2969.
  - Accumulation and grant decision: 2971-2976.
  - shop_coins grant: 2977-2982.
  - progress reset write: 2983-2986.
  - periodic progress flush: 2989-2994.
  - World shutdown: lines 215-227; no AutoDonationPoints flush is present.
- `C:\TW\ComTW\source\src\game\World.h`
  - Bytes: 65,248
  - SHA-256: `669402AA25885ADE8A9C100CBB3AEFDE2A24CEEC7F75E8F2B7C87F1BB9905569`
  - Per-account `uint32` accumulator map: line 1369.
  - `uint32` flush timer initialized to zero: line 1374.
- `C:\TW\ComTW\source\src\mangosd\WorldRunnable.cpp`
  - Bytes: 4,676
  - SHA-256: `5A8B9BB16575DD8299DE019E4EDEC301456683A39B0DA489F05D1AFDAF24617C`
  - The dedicated `World` thread is named at line 46 and calls
    `sWorld.Update(diff)` at line 90.

Every AutoDonationPoints/donationPoint source reference is confined to the
World.cpp block and the two World.h members. There are no feature-specific login,
logout, shutdown, or initialization handlers.

## Eligibility

An account accrues only while its `WorldSession` has a non-null `Player` that is
in the world. The account name is converted from ASCII lowercase to uppercase.
Names beginning with `RNDBOT` and the exact name `DISCORD` are excluded.

There is no generalized PlayerBot-object check. The claimed bot exclusion depends
on the RNDBOT account-naming convention. A bot/session outside that convention is
not excluded by this block.

- GM-security accounts receive points if otherwise eligible; no security/rank
  check exists.
- Active GM mode is irrelevant; no GM-mode check exists.
- AFK time counts; no AFK check exists.
- Offline time does not count because only an in-world player increments by
  `diff`.
- Multiple characters on one account cannot accelerate accrual: `m_sessions` is
  keyed by account ID, `AddSession_` removes/kicks an existing same-account
  session (`World.cpp:318-351`), and progress is keyed by account ID.
- Multiboxed characters on different account IDs accrue separately.

## Persistence and failure behavior

- On first observation after process start, a synchronous `PQuery` loads
  `accumulated_ms`. This query executes in the World thread and can block that
  thread on database latency.
- A missing row and a failed query both produce a null result to this feature and
  are treated as zero. The database layer logs SQL errors, but the feature does
  not distinguish error from no row.
- Progress is not erased from the in-memory map on logout. A same-process relogin
  resumes the map value. There is no logout flush.
- There is no shutdown flush. Restart persistence is limited to the most recent
  successfully executed periodic or grant-time progress UPSERT.
- The nominal unpersisted window for a continuously online account is less than
  `FlushIntervalMs`, but asynchronous queued writes, database errors, and absence
  of a shutdown flush mean this is not a transactional guarantee.
- `PExecute` queues asynchronous SQL after startup. Both return values are
  ignored. The player receives the success chat message even if SQL later fails.
- The interval is subtracted in memory before the shop update result is known.
  A failed shop update does not preserve the consumed progress.
- The shop grant and progress reset are separate statements without a transaction:
  shop success plus progress failure can permit a duplicate grant after restart;
  shop failure plus progress success can lose a grant.
- Concurrent mutation of the map is confined to the World thread. SQL execution
  is asynchronous, but completion is not fed back into the feature.

## Database layer references

- `Database.cpp` (18,551 bytes,
  `EADB868E3DC3439A6FD9E67A70D1993442C9503E570A3C14B0A1A64287537C0A`):
  `PQuery` lines 355-371; `PExecute` lines 426-444; async queue path 393-423.
- `DatabaseMysql.cpp` (17,434 bytes,
  `327515363182B632FD4E2D7C00AC97981F18CB4B4D9BD6E3056B79DD4AB96670`):
  query errors are logged at lines 215-225; execute errors at 344-353.
