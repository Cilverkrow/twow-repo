# Compiler warning triage

This is the canonical triage record for REF-005 / GitHub issue #83. It classifies
the warning families exposed when `--no-warnings` was removed. It does not authorize
a core, module, deployment, database, or runtime change.

## Evidence status

The issue records a first Linux Release build with GCC 14.2, PlayerBots enabled,
zero errors, and 105 warnings. No raw compiler log for that build is retained in the
repository or runbooks. Its class table accounts for only 95 warnings:

| class | recorded count |
|---|---:|
| `-Wdeprecated-declarations` | 50 |
| `-Wwrite-strings` | 28 |
| `-Wmultichar` | 8 |
| `-Wattributes` | 4 |
| `-Wpointer-arith` | 2 |
| `-Wenum-compare` | 2 |
| `-Woverflow` | 1 |
| **classified by the historical table** | **95** |
| **not represented in that table** | **10** |

The number 105 is therefore not reproducible from its own summary. The missing raw
log means it cannot be confirmed, disproved, or silently replaced by 95.

A newer partial capture corroborates and locates most of the table. CI run 27, job
[`99840214991`](https://github.com/Cilverkrow/twow-repo/actions/runs/33502896141/job/99840214991),
compiled commit `b5ed273c48dccd34c6e7e31426bb433adca8bdec` with GCC 14.2 before it was
cancelled during the full-build step. Its completed portion contains 80 compiler
diagnostics: 47 deprecations, 28 write-string warnings, two enum comparisons, two
pointer-arithmetic warnings, and one overflow. Cancellation makes it source evidence,
not a complete count baseline.

The current baseline is CI run 28, successful `build + test` job
[`99852777192`](https://github.com/Cilverkrow/twow-repo/actions/runs/33506790816/job/99852777192),
at commit `f5e11a9ceb49ca9153d99e0bc8a9505c8ad63911`. The compiled paths under
`CMakeLists.txt`, `cmake/`, `dep/`, `modules/`, and `src/` are unchanged between
that commit and this triage's base `91ae697159f20bc6ac30d2be0ae22f3920ce8477`.
The downloaded job log is 757,650 bytes with SHA-256
`6AD7582E45F908489BC012132E775BA4FA580E96BEABADDCA8F8083E33B31948`.

The build emitted 462 compiler diagnostics at 94 unique source locations:

| class | emissions | unique locations | disposition |
|---|---:|---:|---|
| `-Wreturn-type` | 357 | 17 | **FIX** via existing REF-010 / issue #90 |
| `-Wdeprecated-declarations` | 50 | 32 | **FIX** 28 project sites; **SUPPRESS WITH REASON** four vendor sites |
| `-Wwrite-strings` | 28 | 28 | **FIX** |
| unflagged incomplete `Player` type | 9 | 3 | **FIX** |
| `-Wmultichar` | 8 | 4 | **FIX** |
| `-Wattributes` | 4 | 4 | **FIX** |
| `-Wenum-compare` | 2 | 2 | **FIX** |
| `-Wpointer-arith` | 2 | 2 | **FIX** |
| `-Woverflow` | 1 | 1 | **FIX** |
| `-Wstringop-overflow=` | 1 | 1 | **FIX / investigate before changing code** |
| **total** | **462** | **94** | **all assigned** |

The normalized inventory is
[`evidence/ref-005-gcc14-warning-inventory.tsv`](evidence/ref-005-gcc14-warning-inventory.tsv).
Its 90 `FIX` locations account for 440 emissions; its four narrowly suppressible
vendor locations account for 22. The current capture reconciles the old total: the
historical table's 95 flagged emissions, nine unflagged `World.h` emissions, and one
libstdc++-reported `-Wstringop-overflow=` emission add up to 105. This is a current,
source-equivalent reconstruction, not the unavailable historical raw log. The 357
additional current emissions are 17 `ServerFacade.h` locations repeated in 21
`mod-dungeon-clear` translation units.

## Decisions

`FIX` means the diagnostic points to project or upstream-owned code and must be
resolved without changing intended behaviour. `SUPPRESS WITH REASON` means only a
target- or include-scoped exclusion for verified third-party code. `ACCEPT` records
an intentional technical constraint; it never means hiding its compiler diagnostic.

| family / source | decision | rationale and required proof |
|---|---|---|
| OpenSSL low-level SHA-1 calls in `src/shared/Auth/Sha1.*` | **FIX in `twow-core`** | Move the implementation to the incremental EVP digest API, check every API result fail-closed, preserve the 20-byte output, and add known-vector and reinitialization tests. |
| OpenSSL low-level HMAC calls in `src/shared/Auth/Hmac.*` and `HMACSHA1.*` | **FIX in `twow-core`** | Use `EVP_MAC` on OpenSSL 3 and keep a guarded OpenSSL 1.1.1 implementation for the Windows compile target. Add RFC 2202 vectors and explicit ownership/copy tests for context objects. Do not apply a global deprecation suppression. |
| OpenSSL low-level MD5 calls in `WardenMac.cpp`, `WardenModule.cpp`, and `PatchHandler.cpp` | **FIX API in `twow-core`; accept compatibility digest** | The current capture proves nine OpenSSL-3 deprecations. Preserve the exact Warden- and patch-compatible 16-byte digest while moving to a supported EVP API and add known-vector tests. Do not silently substitute another digest. |
| SHA-1 and HMAC-SHA1 as algorithms | **ACCEPT** | They are part of the WoW authentication protocol. Modernize the API, not the wire algorithm; substituting SHA-256 would break compatibility. |
| `-Wwrite-strings` in `Config.cpp`, `AddonHandler.cpp`, and `SpellEntry.cpp` | **FIX in `twow-core`** | The partial capture accounts for all recorded 28 warnings: 23- and four-entry read-only string tables use writable `char *`, and `SpellEntry::GetIcon()` returns a literal through `char *`. Make the tables and API const-correct and compile all consumers. |
| `src/realmd/AuthSocket.h` platform and CPU tags | **FIX in `twow-core`** | The four multi-character literals are implementation-defined and are emitted from two translation units, matching the recorded eight warnings. Replace them with an explicit constexpr byte-packing operation or fixed-width values and assert the exact protocol values. |
| `[[nodiscard]]` in the three Scarlet Citadel boss headers | **FIX in `twow-core`** | GCC ignores the attribute in its current position at `boss_daelus.hpp:91`, `boss_ardaeus.hpp:112`, and `boss_mariella.hpp:100,158`. Move it to a valid declaration position and compile those scripts with GCC 14. |
| RapidJSON and utf8cpp under `dep/include` | **SUPPRESS WITH REASON** | The partial capture proves 18 RapidJSON and four utf8cpp emissions. They are vendored code. Mark only the relevant include roots as `SYSTEM`/external on each consuming target. Do not edit the vendors and prove a deliberate project warning remains visible. |
| `modules/mod-playerbots/src/playerbot/ServerFacade.h` seen through `mod-dungeon-clear` | **FIX in `twow-repo`; already REF-010 / issue #90** | Seventeen non-void wrappers lose every return branch because `mod-playerbots` keeps `CMANGOS`, `MANGOSBOT_ZERO`, and `ENABLE_PLAYERBOTS` private while 21 `mod-dungeon-clear` translation units include the same headers. The 357 emissions are a build-visible symptom of the already documented cross-module ODR/layout defect. Do not duplicate #90 or change its `agent-claude` assignment. |
| `src/game/World.h:1065,1083,1107` | **FIX in `twow-core`** | Three inline/template sites dereference a forward-declared `Player` and are emitted from three translation units. Give the definitions a complete type without creating an include cycle; compile the affected include orders and the header-self-containment gate. |
| `src/game/Commands/Commands.cpp:18904,18911` | **FIX in `twow-core`** | Both `-Wpointer-arith` diagnostics are `strcmp()` results compared with `NULL`. Compare with zero and add command tests for equal and unequal email values. This is project code, so suppression is not permitted. |
| `src/game/Battlegrounds/BattleGroundSV.cpp:521,542` | **FIX in `twow-core`** | `BattleGroundTeamIndex` is compared with `TeamId`. Both currently encode Alliance as zero, but the domains are distinct. Use `BG_TEAM_ALLIANCE` and cover both sound-selection branches. |
| `src/shared/Log.cpp:405` | **FIX in `twow-core`; highest correctness priority** | `50 * GB` overflows `int` to `-1539607552`, so the file-split threshold is wrong. Use a deliberate 64-bit size expression and a file-size API/type valid on every supported platform; test values below, at, and above 50 GB. |
| `instance_temple_of_ahnqiraj.cpp:560` through libstdc++ `new_allocator.h:191` | **FIX / investigate in `twow-core`** | GCC reports a one-byte write into a zero-sized region while reallocating `playersInStomach`. Minimize the `vector<pair<ObjectGuid, StomachTimers>>` construction, run ASan/UBSan and boundary tests, and inspect object size/alignment before changing code. Reclassify to a narrow GCC-version suppression only if a reproducible minimal case proves a compiler false positive. |

## Repository ownership and review sequence

Under the repository split proposed by ADR-0020, follow-up changes to `src/**` and
`dep/**` are routed to the existing `twow-core` repository. This routing does not
promote ADR-0020 from Proposed to Accepted. The copies still visible in the
transition branch do not justify duplicate fixes in both repositories.

Use separate review units in this order:

1. Resolve REF-010 / issue #90 before using the remaining warning count as a trend:
   its 357 emissions are one macro-boundary defect, not 357 independent fixes.
2. In `twow-core`, modernize SHA-1/HMAC/MD5 APIs and the `SendProof` copy boundary, with
   known-vector, reinitialization, ownership, Linux/OpenSSL-3, and Windows/OpenSSL-
   1.1.1 compile tests.
3. In a separate `twow-core` PR, replace the protocol multi-character constants and
   test their exact numeric and byte representations.
4. In focused `twow-core` PRs, fix the three constness sites, misplaced attributes,
   email comparisons, battleground enum domain, and log-size overflow. Do not combine
   unrelated behaviour changes.
5. Mark vendor include roots external at the narrowest target scope. A core consumer
   is changed in `twow-core`; `modules/mod-playerbots/mod-playerbots.cmake` is changed
   separately in `twow-repo`. Shared module targets must not gain blanket warning
   options.
6. Update the project repository's pinned core commit only after the corresponding
   core PR is merged and its Linux and Windows gates pass.

The default constructor in `src/shared/Auth/Hmac.h` also leaves its context pointer
uninitialized. That is a latent ownership defect, not a diagnostic proven by this
warning baseline. Characterize or remove the apparently dead `AuthCrypt::GenerateKey`
path in its own issue; do not smuggle a guessed key or lifecycle change into an API-
modernization PR.

## Guardrails and completion gate

- Do not restore `--no-warnings`.
- Do not enable `-Werror` until the accepted current backlog is zero.
- Do not add a repository-wide `-Wno-*` flag.
- Do not edit vendored headers merely to quiet diagnostics.
- Do not mix `twow-core` source changes and a `twow-repo` core-pin update in one
  repository PR.
- Treat a compiler-log URL as transient. The normalized text inventory is retained
  in Git and records its producing job and commit here.
- REF-005's classification is complete: every current diagnostic has a decision,
  owner, and follow-up gate. Its follow-up fixes remain separate review units and
  must not be folded into this documentation PR.

## Static evidence used for this triage

- `CMakeLists.txt` records the removal of `--no-warnings`.
- `src/game/Anticheat/Config.cpp` contains the 23-entry writable-pointer string
  table.
- `src/game/Anticheat/AddonHandler.cpp` contains the four-entry writable-pointer
  table; `src/game/Spells/SpellEntry.cpp` returns a literal through `char *`.
- `src/realmd/AuthSocket.h` contains the four implementation-defined protocol tags.
- `src/shared/Auth/{Sha1,Hmac,HMACSHA1}.*` use the deprecated low-level OpenSSL APIs.
- `src/game/Anticheat/Warden/{WardenMac,WardenModule}.cpp` and
  `src/realmd/PatchHandler.cpp` use deprecated low-level MD5 APIs.
- `src/game/Commands/Commands.cpp`, `src/game/Battlegrounds/BattleGroundSV.cpp`, and
  `src/shared/Log.cpp` are the proven pointer, enum, and overflow diagnostic sites.
- `src/scripts/dungeons/temple_of_ahnqiraj/instance_temple_of_ahnqiraj.cpp:560`
  is the project call site for the libstdc++ `-Wstringop-overflow=` diagnostic.
- `modules/mod-playerbots/src/playerbot/ServerFacade.h` plus
  `modules/mod-playerbots/mod-playerbots.cmake` prove the already tracked REF-010
  cross-module macro boundary.
- `src/scripts/dungeons/scarlet_citadel/boss_{daelus,ardaeus,mariella}.hpp` contain
  the four ignored attribute placements.
- Proposed ADR-0020 describes the two-repository routing used by this triage;
  accepted ADR-0028 defines GCC/Linux as the complete build gate and Windows as
  compile-only.
