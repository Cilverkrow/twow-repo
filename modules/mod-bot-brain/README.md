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

### In the Compose stack

The three steps above are a local build. Under `deploy/compose` they are one
setting, because the rendered config supplies the other two:

1. `BOT_BRAIN_ENABLE=1` in `deploy/compose/.env`.
2. `docker compose -f deploy/compose/docker-compose.yml -f deploy/compose/bot-brain.yml up -d`
   (this is what `make up` runs, plus the planner's own file).

`make config` renders `deploy/compose/config/mod_bot_brain.conf` from
`conf/mod_bot_brain.conf.dist` plus `config/canonical/compose/bot-brain.overlay.conf`
and bind-mounts it onto `/opt/turtle/etc/modules/mod_bot_brain.conf`; that
overlay also points `BotBrain.Endpoint` at the `bot-brain` Compose service, and
`config/canonical/compose/aiplayerbot.overlay.conf` already carries the
`,+bot brain` strategy. Until this existed the file was seeded inside the
container from its `.dist` and there was no supported way to change it.

Applied intents are logged at BASIC level with the intent id and the POI id.
Note where they land: `playerbot.h` redefines `sLog` to `BotLog::Instance()`,
so this line goes to `logs/bots.log` when `AiPlayerbot.BotLogFile` is set, and
to the main log otherwise.

```
mod-bot-brain: Grimblade (guid 4242) travel target set from intent i-... -> poi p3 (kind repair, source rule, confidence 0.90)
```

## Dialogue: bots answering chat

A second thing this module does, through a second endpoint and a second seam.

`PlayerbotLLMInterface::Generate` in the core submodule returns `""`. Everything
above it in `ChatReplyAction::ChatReplyDo` still runs — the gating, the channel
mirroring, the `std::async` worker, the tick-polled delivery — and produces
nothing. mod-playerbots declares a provider seam above that stub
(`playerbot/BotDialogueProvider.h`); `BotBrainDialogue.cpp` registers into it and
answers by calling `POST /v1/dialogue`.

The seam is at the call site rather than inside `Generate` on purpose. `Generate`
receives a rendered request body built from `AiPlayerbot.LLMApiJson` and shaped
for one particular completion API; at the call site the facts are still facts —
who said what, in which channel, to which bot, with which trait keys — and the
service builds its own prompt from the catalog's German instruction sentences.

What crosses the seam is scalars and strings. No `Player`, no `PlayerbotAI`, no
session: the bot may have logged out by the time the worker runs, and the
identity is looked up by low guid through `LookupBotIdentity`, which copies the
cached uuid and trait keys under `g_statesMutex`. Same ADR-0012 rule as the
planning workers, same reason.

**Two sides have to be on**, and this module owns only one of them:

| Switch | Owner | Default |
| --- | --- | --- |
| `AiPlayerbot.LLMEnabled` (non-zero) | mod-playerbots | `0` |
| the `ai chat` strategy, or `LLMEnabled = 3` | mod-playerbots | off |
| `BotBrain.Enable` | this module | `0` |
| `BotBrain.Dialogue.Enable` | this module | `0` |
| `BotBrain.Dialogue.Commands.Enable` | this module | `0` |

`BotBrain.Dialogue.Enable` is separate from `BotBrain.Enable` because planning is
local and free while dialogue spends model tokens every time a player types.
Turning the brain on is not agreeing to pay for conversation.

### Commands: telling a bot to do something in chat

With `BotBrain.Dialogue.Commands.Enable` on, a reply may also carry one value
from a closed set — `follow`, `stay`, `flee`, `attack`, `equip_upgrades` — and
the bot obeys it. The reply and the command are independent: a bot may speak
without acting, act without speaking, or do neither.

The rule this rests on, and the one worth checking rather than trusting:

> The model may only cause what the speaker could already have caused by typing
> the command themselves.

Each value names a chat command mod-playerbots already accepts from a player who
types it. This module maps the wire spelling onto core's `BotDialogueCommand`,
and the **worldserver** runs it through `PlayerbotAI::HandleCommand` with the
speaker as the commanding player, on the bot's own tick. Both `PlayerbotSecurity`
gates apply unchanged, and the second needs `PLAYERBOT_SECURITY_ALLOW_ALL` —
which only a GM, the account owning the bot, or someone sharing a group with it
has. A stranger's "come here" is refused in exactly the place a stranger's typed
`follow` is refused, by the same code. Prompt injection therefore buys an
attacker nothing they did not already have.

There is no target field, no item field and no free text: a command selects one
fixed string on the C++ side and nothing else. `attack` is in the set because it
resolves its victim from the **speaker's own client selection**, so the player
picks the target by clicking it. `equip_upgrades` maps to `do equip upgrades`,
and still does nothing for a player-owned bot unless
`AiPlayerbot.AutoEquipUpgradeLoot` is on.

Three things drop a command, all silently and none of them a reply failure:
`allow_commands` was not sent (so the vocabulary was never in the model's
prompt), the value is not in this build's closed set, or the chat path could not
say who spoke. That last one covers a **bot** speaker: `speakerGuidLow` is left
at zero for one, because a bot never typed anything and so has no typed command
to inherit permission from.

Channels are mapped conservatively: say and yell → `say`, party and raid →
`party`, guild → `guild`, whisper → `whisper`. World, general, trade, LFG, the
defence channels, guild recruitment and both emote sources map to nothing and
the bot stays quiet — the contract's style rules are written for conversations,
and a bot writing German prose into trade chat is a feature nobody designed.

Every failure is silence and no command, and silence is a 200: dialogue off, no
handshake, an unmapped channel, too many calls in flight, a dead socket, a
non-200, an undecodable body, or a reply carrying a newline. `DecodeDialogueResponse` is the
last gate before text this process did not write reaches a game channel, and it
turns a reply it will not vouch for into `filtered` rather than into an error.

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
