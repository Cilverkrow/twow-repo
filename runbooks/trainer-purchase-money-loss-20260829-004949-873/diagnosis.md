# Trainer purchase money-loss finding

## Primary classification

`INSUFFICIENT_EVIDENCE`

Confidence in this classification: **high**. The ability is absent from persistence and the source contains a real charge-without-learn gap, but the event-specific opcode, cast/effect outcome, packets, pre/post balances, and current in-memory spell map were not captured. Assigning that code gap as the observed cause would exceed the evidence.

## Resolved event facts

- Sanitized character: `CHAR-2DD856EFD1A1`
- Persisted identity/state: human (race 1), paladin (class 2), level 4, online.
- Trainer: entry 925, spawn GUID 79967, local canonical name `Brother Sammuel`, Paladin Trainer, map 0 at `(-8914.57, -215.016, 82.2996)` in the Northshire Abbey area. The client spelling supplied by the reporter differs by one `m`.
- Trainer spell/service ID: 1875.
- Learned spell ID: 465, Devotion Aura rank 1.
- Rank chain: learned ranks 465 -> 10290 -> 643 -> 10291 -> 1032 -> 10292 -> 10293. Rank 1 has no previous-rank prerequisite.
- Trainer row: 10 copper base cost, required level 1, no required skill. Trainer class 2 matches; trainer race 0 permits the persisted human race.
- The same server price function populates the trainer list and recalculates the purchase price. The observed 10-copper display is consistent with the 10-copper base row and a 1.0 discount factor; no event packet was captured to prove the exact runtime factor.
- Spell 1875 is a valid effect-36 learning spell whose effect-1 trigger is 465. Spell 465 is a paladin class ability (class mask 2), not a talent. No talent-table match exists.
- No matching `spell_learn_spell` row is required: the taught spell is embedded in effect 36 of spell 1875.
- No duplicate, direct/template collision, invalid learning effect, or mismatched row was found for trainer 925. The trainer uses direct rows and no trainer template.
- No persisted Devotion Aura rank, disabled rank, dual-spec rank, already-known higher rank, or superseding rank is present for the sanitized character.
- Source-evaluated availability is green from the persisted facts: correct class/race, level 4 >= 1, no skill requirement, no prior/additional spell requirement, and no known rank. The online in-memory map could still differ.

## Money and ability state

- Money deduction: confirmed only by the reporter's client display. There is no pre-purchase balance, packet capture, server-memory snapshot, or database before/after pair. The final read-only database snapshot at `2026-08-28T23:14:07.6187298Z` contains 393 copper, but concurrent looting/selling changed the persisted balance during diagnosis, so it cannot isolate a 10-copper delta.
- Ability absence: confirmed immediately in the client UI by the reporter and absent from `character_spell`/`character_spell_dual_spec` in the later persisted snapshot.
- In-memory ability state: unknown. No GM query/command or intrusive runtime inspection was used. Because the character remained online, persistence and memory are not asserted to be identical.
- Persistence failure: no character-spell, database, SQL, assertion, or handler error was present in the bounded logs. Absence of such a line is weak negative evidence because prepared persistence statements and DEBUG trainer messages are not fully logged at the active level.

## Source conclusion

The normal handler can deduct money after a downstream failure to learn:

- it saves the result of `Spell::prepare()`;
- it calls the void `spell->update(1)`;
- execution can still fail in `Spell::cast()` or return before the learning effect;
- `EffectLearnSpell` calls a void `LearnSpell`, which does not propagate `AddSpell` failure;
- the handler then checks only the earlier prepare result, deducts money, and sends trainer success without verifying spell 465 in the player spell map;
- later persistence is not transactionally coupled to the deduction and has no refund path.

For this specific valid, instant (0 ms) trainer spell, the normal case executes the learning effect during `update(1)` before the charge. The gap is therefore feasible but not event-proven.

## Log correlation

- Candidate purchase window: after the last login at 00:38:45 and before diagnostic capture began at 00:49:49 server-local time. No later relog occurred in that interval.
- Exact trainer selected at 00:40:05: entry 925 / spawn GUID 79967.
- Trainer-buy opcode records: 0.
- Trainer success/failure records: 0.
- Learned-spell packet/effect records: 0.
- Trainer-specific `-10c` trade-log records: 0. This is expected to be inconclusive because the handler calls `ModifyMoney`, not the security-aware `LogModifyMoney` wrapper.
- Failed persistence or relevant assertion records: 0.
- PlayerBot comparison: three current-session `TrainerAction` announcements for service 1875 were present. PlayerBots use a separate direct-learning implementation and do not validate the normal player handler.

## GM-account hypothesis

Evidence for relevance:

- Account security rank is 3.
- The login path applies configured GM state only to accounts above normal security.
- At 00:38:45 the server logged persisted extra flags 19, which includes the `PLAYER_EXTRA_GM_ON` bit.
- At 00:40:05 the session logged `gm on` while trainer entry 925 / GUID 79967 was selected; `gm off` was not logged until 00:50:26, after diagnostic capture began.
- Consequently, the supplied recollection that GM mode was disabled cannot be used as established event evidence. The exact purchase instant is unlogged, but GM mode was likely on for the most probable interval.

Evidence against a causal GM branch:

- The handler, trainer eligibility, trainer class/race checks, effect-36 learning, `AddSpell`, and `LearnSpell` have no account-security or GM-mode branch.
- Spell 1875 is trainer-cast because its visual is 107, so the generic player-caster GM outdoor bypass is not traversed.
- The generic target check only protects GM targets from non-positive spells; the learning spell is positive.
- The later persisted extra flags are 54, whose GM-on bit is clear, and `isGMCharacter` is 0. This describes the later persisted state, not the likely purchase-time state.

Conclusion: GM state is an unresolved event variable and the session evidence conflicts with the recollection, but no source branch currently explains the missing spell as a GM-specific outcome.

## Potential scope

- Trainer data does not indicate a trainer-925-specific defect.
- Spell service 1875 appears on 13 distinct direct trainer entries and no trainer templates; the row itself is structurally valid.
- The source-level verification gap is shared by normal-player trainer purchases generally, so any normal player could be exposed if a post-prepare cast/effect/persistence failure occurs.
- No evidence establishes that another real character suffered the loss. Successful bot training is not a normal-handler control.

## Controlled reproduction proposal — not executed

Separate authorization would be required for every state-changing or server-instrumentation step.

1. Use a disposable, logged-out/safely snapshotted level-4 paladin on a normal-security account. Confirm Devotion Aura rank 1 is absent and give it only the minimum known test funds through an explicitly authorized preparation plan.
2. Capture exact byte offsets and hashes for the active server, character, trade, error, and packet/targeted diagnostic logs. If packet-level proof is required, deploy a narrowly instrumented handler build in a separately authorized maintenance window; current logging is insufficient.
3. Record read-only pre-event snapshots of `characters.money`, the complete Devotion Aura learned-rank set in `character_spell`/dual-spec, relevant skills, account security, character extra flags, and trainer row 925/1875.
4. Perform exactly one 10-copper purchase of the missing service 1875, recording client video/message state and exact wall-clock time. Do not batch-click.
5. Immediately record post-event client money/spellbook state, bounded log offsets, and read-only database snapshots. Then perform a normal logout of the disposable character and repeat the persisted snapshot so memory-versus-save can be distinguished.
6. Compare a matched GM-security account only if the normal account does not reproduce. Record GM mode explicitly both through its flag and the GM command log before the click.
7. Restoration plan: keep the disposable character isolated; after separate authorization, restore its exact pre-event money/spell rows from the snapshot inside a reviewed transaction or delete only that disposable character if deletion was explicitly approved. Do not apply restoration or refund to the affected live character as part of the reproduction.

No reproduction, teaching, refund, money change, relog, server control, or restoration was performed in this diagnosis.
