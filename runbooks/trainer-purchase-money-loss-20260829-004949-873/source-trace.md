# Trainer purchase source trace

Read-only trace captured 2026-08-29. No build, migration, server control, character command, or data mutation was performed.

## Source identity

- Repository: `C:\TW\ComTW\source`
- Branch: `playerbots-integration-gh`
- Commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Commit date: `2026-08-25T15:22:11+01:00`
- Subject: `dc: load recorded routes at runtime, and raise the instance gate`
- Running `mangosd.exe` SHA-256: `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`
- The traced files below are clean relative to HEAD. The repository has unrelated pre-existing changes outside this traced set.

## Normal player path

1. `src/game/Handlers/NPCHandler.cpp:282-288` handles `CMSG_TRAINER_BUY_SPELL` and reads trainer GUID plus trainer spell ID.
2. `NPCHandler.cpp:290-321` validates interaction, trainer identity/LOS, and membership in `npc_trainer` or `npc_trainer_template`.
3. `NPCHandler.cpp:323-340` requires `TRAINER_SPELL_GREEN`, calculates `floor(baseCost * reputationDiscount)`, and rejects insufficient money.
4. `NPCHandler.cpp:342-365` constructs the learning-spell cast. Because trainer spell 1875 has visual 107, the trainer is the caster; only visual 222 uses the player as caster. A seated trainer uses a triggered cast.
5. `NPCHandler.cpp:365-383` stores only the result from `Spell::prepare`, calls `spell->update(1)`, then deducts money and sends `SMSG_TRAINER_BUY_SUCCEEDED` if the earlier prepare result was `SPELL_CAST_OK`. The explicit failure path sends `SMSG_TRAINER_BUY_FAILED` and does not deduct money.
6. `src/game/Spells/Spell.cpp:3505-3677` implements `prepare`. It performs the first cast check and returns `SPELL_CAST_OK` before later execution.
7. `Spell.cpp:4184-4286` implements `update`; for an instant spell it invokes `cast()`.
8. `Spell.cpp:3767-3860` shows that `cast()` can still fail after successful preparation: it can lose its target, fail the cast counter, fail power, or fail the second `CheckCast(false)`. `update()` is void and none of these outcomes is returned to the trainer handler.
9. `Spell.cpp:3867-3982` shows additional pre-effect exits: target-map construction may finish the spell, or immediate handling may throw and return.
10. `src/game/Spells/SpellEffects.cpp:2239-2257` implements effect 36. It returns without learning if the unit target is missing/not a player; otherwise it calls `Player::LearnSpell` and logs a DEBUG-only message.
11. `src/game/Objects/Player.cpp:4332-4610` implements `AddSpell`. It returns false for invalid, already-known, disabled, or superseded states. `Player.cpp:4630-4661` implements the void `LearnSpell` wrapper; it uses the boolean only to decide whether to send `SMSG_LEARNED_SPELL`. The return is not propagated to `EffectLearnSpell` or the trainer handler.
12. `Player.cpp:18985-19011` persists changed/new non-dependent spells in `character_spell`. Persistence happens during character save, after the trainer transaction; this path has no refund coupling.

### Can money be deducted without learning?

Yes, the source contains such paths. The handler verifies only the result of `prepare()`. It does not verify the later `cast()` result, `HasSpell(learnedSpellId)`, `HasActiveSpell(learnedSpellId)`, or persistence success before charging and sending trainer success. A post-prepare cast failure, an effect that returns early, an `AddSpell` rejection, or a later persistence failure therefore has no refund path here.

For trainer spell 1875, `castingTimeIndex=1`; the pinned `SpellCastTimes.dbc` maps index 1 to 0 ms, so the normal execution is immediate during `update(1)`. The vulnerable gap still exists because execution has failure/early-return branches not reflected in the saved `prepare` result.

This proves a code-level possibility, not that this exact event traversed it. The active log level did not record the opcode, the second cast result, the learned-spell packet, or the trainer success packet.

## Eligibility, rank, and trainer-data path

- `src/game/ObjectMgr.cpp:8062-8167` loads trainer rows, rejects missing/non-learning/broken/talent rows, rejects direct/template duplicates, and stores cost/skill/level.
- `src/game/Objects/Creature.cpp:1250-1307` enforces class-trainer compatibility; trainer entry 925 is class 2 and the affected persisted class is 2.
- `src/game/Objects/Player.cpp:5357-5425` rejects an already-known taught spell, class/race mismatch, insufficient level, missing previous/additional spell-chain prerequisite, and insufficient skill.
- Local database evidence identifies trainer row 925/1875 as base cost 10 copper, required level 1, no skill requirement. Spell 1875 is effect 36 and triggers learned spell 465, Devotion Aura rank 1.
- `skill_line_ability` maps learned spell 465 to class mask 2, race mask 0, and successor 10290. No matching talent row exists. No learned Devotion Aura rank is persisted for the sanitized character.
- No invalid, duplicate, cross-source, or mismatched trainer row was found for trainer entry 925.

## Success/failure packets

- `NPCHandler.cpp:265-271`: `SMSG_TRAINER_BUY_SUCCEEDED`.
- `NPCHandler.cpp:273-280`: `SMSG_TRAINER_BUY_FAILED`.
- `NPCHandler.cpp:292-340`: explicit failure packets for unavailable trainer/spell, eligibility, or money.
- `NPCHandler.cpp:368-383`: success is based on the saved prepare result; an explicit prepare failure is logged and sends unavailable.
- `Player.cpp:4637-4648`: `SMSG_LEARNED_SPELL` is sent only when `AddSpell` returned true.

## GM/security branches relevant to this path

- The trainer handler, `Creature::IsTrainerOf`, `Player::GetTrainerSpellState`, `EffectLearnSpell`, `AddSpell`, and `LearnSpell` contain no account-security or GM-mode branch for trainer learning.
- `src/game/MapNodes/AbstractPlayer.h:9-24` defines `PLAYER_EXTRA_GM_ON = 0x0001`; `src/game/Objects/Player.h:1203-1215` makes `IsGameMaster()` depend on that bit.
- `Player.cpp:3494-3518` toggles GM mode and the bit. `Player.cpp:17182-17242` applies configured GM login state only for security above player.
- Generic spell checks have two GM references in the traversed files: `Spell.cpp:5628-5636` bypasses indoor/outdoor restrictions only when the caster is a GM player, but spell 1875 is trainer-cast because visual 107 is not 222; `Spell.cpp:7851-7857` protects GM player targets from non-positive spells, while the learning spell is positive.
- `Player.cpp:16333-16356` logs GM money changes only when callers use `LogModifyMoney`. The trainer handler uses `ModifyMoney` directly, so a trainer deduction is absent from `trades.log` even on a GM-security account.
- Database evidence confirms security rank 3. The current persisted extra flags have the GM-on bit clear, but the bounded session logs show extra flags 19 after the 00:38:45 login and a `gm on` command at 00:40:05 with trainer 925 selected, followed by `gm off` only at 00:50:26. Exact mode at the unlogged purchase instant is therefore unresolved and likely on in the most probable interval.

## Turtle and PlayerBot differences

- `NPCHandler.cpp:346-360` is the Turtle seated-trainer modification introduced by commit `48aa08585dc055fd750377985f6c19eee521c6e7`.
- `NPCHandler.cpp:375-383` adds explicit prepare-failure logging from commit `0610e9b91df6678338fc282f8329622e1f089708`.
- `CMakeLists.txt:710-718` compiles PlayerBots with `MANGOSBOT_ZERO`.
- `src/modules/PlayerBots/playerbot/strategy/actions/TrainerAction.cpp:9-63` is a separate training implementation. In the active Vanilla branch (`:26-44`), it deducts directly and calls `learnSpell` for the trigger spell rather than sending `CMSG_TRAINER_BUY_SPELL` through the player handler. It then logs/announces “learned” without receiving a boolean learning result.
- `TrainerAction.cpp:81-128` uses `GetTrainerSpellState` to filter candidates, but the purchase/learning execution is still separate. Successful bot announcements therefore validate much of the shared data, not the normal player opcode path.

## File hashes (SHA-256)

- `CMakeLists.txt`: `FB579305F342F83611B1F794F5510B163FAF803A500FF1385901ED512227BAF1`
- `src/game/Handlers/NPCHandler.cpp`: `484C9995BF8CA174C19FD3AF589CBDF03A09D778278FC4BE9A28F0BC9AA77F7F`
- `src/game/Spells/Spell.cpp`: `8D81C51FA7386A990B8365AE1F2AE5B126EC4E5CCE800AB8D0A128430317AD4A`
- `src/game/Spells/SpellEffects.cpp`: `631344AE3698C98623003D7CB59A771E6F6D54684F187A34DAEF1619BE8BBCC9`
- `src/game/Objects/Player.cpp`: `6F9240C9BA27276CFFBD74ADF425AFD2D451A6ADA58BF26727CA400A5B3F293F`
- `src/game/Objects/Player.h`: `692B3B30C0A0C2745FA7C99C74665A5E7EB38E119B2F894A197B3CD99E3A2D91`
- `src/game/Objects/Creature.cpp`: `9CEF910C5DBB142001EC3CE884069C4F33DE30A2BD7EA3DB184C5459CE0A8CEF`
- `src/game/Objects/Creature.h`: `1FA6689B839725E68723F3C72300A3BEAE07237312291B74D93B27E3167FDF06`
- `src/game/ObjectMgr.cpp`: `51BCB3CFCD216D77B215AB1BC1C29FA4942707184C9625682DCE8400B07EDE12`
- `src/game/MapNodes/AbstractPlayer.h`: `A92286796EE141C02CBA484388088E7126D9F808E0C885B941D0A7E36F2CA6B7`
- `src/modules/PlayerBots/playerbot/strategy/actions/TrainerAction.cpp`: `0CBD3E80035AD8E79137EFA15C5208751A7243855B075578A9D6C2D7D59C15C6`
- `C:\TW\ComTW\data\dbc\SpellCastTimes.dbc`: `D80AF2009FD1ACD0A2C78A7AF1604703C2639796CEB2267747C49F1D234BA27F`
