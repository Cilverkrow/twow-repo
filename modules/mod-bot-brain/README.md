# mod-bot-brain

Asks the out-of-process planner in `services/bot-brain` where a bot should
travel next, and applies the answer through the travel-target chooser that
already exists. Implements ADR-0012: external process, disabled by default,
fail-closed admission, and no World or AI object crossing the worker boundary.

Off by default. With `BotBrain.Enable = 0` — the shipped value — the module
compiles in, registers its context, and changes nothing: every bot runs the
stock chooser.

## The seam it uses

Nothing under `core/modules/mod-playerbots` is edited. That tree is a vendored copy
of upstream (`Shyalya/tortoise-wow`, `playerbots-integration-gh`) and every line
changed in it is permanent merge friction.

Two existing mechanisms carry the whole feature:

* `RegisterAiContextAugmenter` (`playerbot/AiContextAugment.h`) hands this module
  every bot's AI context as it is built, and walks the bots that already exist.
* Registering a `NamedObjectContext<Action>` under the **existing** name
  `"choose travel target"` overrides the stock action, because
  `AiObjectContext::AddShared` inserts with `AddFront` and `GetObject` takes the
  first context that answers. `ChooseTravelTargetAction.cpp` is never touched.

`mod-dungeon-clear` is the precedent for both; this is the second user of that
seam, which is the point of having one.

Contexts are handed out **fresh per bot**. A function-local static would be
`delete`d by `NamedObjectContextList`'s destructor on the first relogin (glibc
aborts) and would bind every later bot's action to the first bot's
`PlayerbotAI`.

## The pipeline

Two things here are slow and neither may run on a map thread:
`sTravelMgr.GetPartitions()` blocks on a five-permit semaphore, and the HTTP
round trip is a network call. So one planning round is four phases:

| phase | thread | what |
|---|---|---|
| A | worker | `GetPartitions` for this bot |
| B | map | build the POI table and the snapshot JSON, bot alive |
| C | worker | `POST /v1/plan` — a string in, a string out |
| D | map | parse, hold the intent until the chooser asks |

Phase C's worker captures three `std::string`s and an integer. It cannot name a
`Player`, a `PlayerbotAI` or a `WorldSession`, which is ADR-0012's rule
expressed as a type signature rather than as a comment. Compare
`PlayerbotAI.cpp:7986` (`SendDelayedPacket`), which detaches a thread holding a
raw `WorldSession*` and calls `QueuePacket` after a sleep — a use-after-free on
logout (LLM-012, present upstream too).

Bot state is keyed by `ObjectGuid` and re-resolved on the map thread. A bot that
logs out mid-flight costs a discarded result, never a dangling pointer.

## Failure is always the stock chooser

No service, a slow service, a version-skewed service, a malformed response, an
expired intent, an unknown POI, an intent addressed to another bot: every one of
them falls through to `ChooseTravelTargetAction::Execute()` unchanged. Killing
the service is a supported operation.

Admission is fail-closed: the pipeline stays inert until `GET /v1/contract` at
`WORLDHOOK_ON_STARTUP` confirms a peer serving contract major 1, so version skew
is one boot-time log line instead of a silent stream of dropped intents.

The handshake happens **once, at startup, and is not retried**. A service that
comes up after the worldserver did will not be picked up until the worldserver
restarts. That is a deliberate consequence of "find skew at boot rather than
mid-run": a periodic re-handshake would either block the world thread on a
network call or need a fourth worker for a check that only matters once. Start
the brain before the worldserver.

## Turning it on

1. Run the service: `cd services/bot-brain && go run ./cmd/bot-brain`
   (listens on `127.0.0.1:8085`).
2. `BotBrain.Enable = 1` in `mod_bot_brain.conf`.
3. Give the bots the strategy: append `,+bot brain` to
   `AiPlayerbot.RandomBotNonCombatStrategies`, or call
   `botAI->ChangeStrategy("+bot brain", BOT_STATE_NON_COMBAT)` from your own
   `PlayerScript::OnLogin`.

Applied intents are logged at BASIC level with the intent id and the POI id.
Note where they land: `playerbot.h` redefines `sLog` to `BotLog::Instance()`,
so this line goes to `logs/bots.log` when `AiPlayerbot.BotLogFile` is set, and
to the main log otherwise.

```
mod-bot-brain: Grimblade (guid 4242) travel target set from intent i-... -> poi p3 (kind repair, source rule, confidence 0.90)
```

## Contract details that have already caused bugs

* the array is `pois`, not `poi`;
* `durability_pct` is nested under `vitals`, not `char`, and is a pointer on the
  Go side — absent is not zero;
* percentages are 0–100, not 0–1 (`Intent.confidence` is the one 0–1 field);
* angles are radians;
* `bot.guid` and `bot.realm` must both be non-zero or `Validate()` rejects the
  snapshot.

All five are asserted in `t/bot_brain_wire_tests.cpp`.

## Tests

`src/BotBrainWire.{h,cpp}` is hermetic by construction: `<cstdint>`, `<string>`,
`<vector>` and rapidjson, and nothing else. That is what makes the contract
testable with no world server, no database and no bot.

```
cmake -B build -DBUILD_TESTING=ON && cmake --build build --target bot_brain_wire_tests
ctest --test-dir build -R bot_brain_wire
```

The binary also answers `--dump-request`, which prints the sample plan request
the encoder produces. That is how the encoder is checked against the **real**
service rather than against this repository's idea of it:

```
go run ./services/bot-brain/cmd/bot-brain &
./build/bot_brain_wire_tests --dump-request | curl -s -XPOST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8085/v1/plan
```

A `"unknown_fields":0` in the response `stats` is the check: it means the
service recognised every key this module sent.
