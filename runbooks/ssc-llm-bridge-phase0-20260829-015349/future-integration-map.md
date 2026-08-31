# SSC LLM Bridge — read-only future integration map

## Scope and source identity

This is analysis only. No source file was edited or compiled.

- Repository: `C:\TW\ComTW\source`
- Branch recorded by discovery: `playerbots-integration-gh`
- Pinned commit: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Local `HEAD` exactly matched the discovery commit.
- The working tree already contained unrelated modified/untracked files. Every citation below was read from the pinned commit with `git show <commit>:<path>`, so working-tree changes were not used as evidence.

## Incoming player chat

The normal packet path starts at `CMSG_MESSAGECHAT`:

1. `src/game/Protocol/Opcodes.cpp:205` registers `CMSG_MESSAGECHAT` to `WorldSession::HandleMessagechatOpcode`.
2. `src/game/WorldSession.cpp:255-285` assigns chat work by channel: whisper/channel/party/guild/raid use `PACKET_PROCESS_DB_QUERY`, while say/emote/yell use `PACKET_PROCESS_MAP`; addon chat stays on the world path.
3. `src/game/WorldSession.cpp:295-320` puts the packet into the corresponding mutex-backed receive queue (`LockedQueue` is declared at `src/game/WorldSession.h:1059`).
4. `src/game/Handlers/ChatHandler.cpp:176-314` parses type, language, target/channel and message. `ProcessChatMessageAfterSecurityCheck` at lines 83-96 applies validity hooks and command parsing first.
5. After mute, addon, level and character checks, `WorldSession::HandleMessagechatOpcode` calls `PLAYERHOOK_ON_CHAT_COMMAND` at `src/game/Handlers/ChatHandler.cpp:403-412`, before normal broadcast.

The hook is therefore the earliest module-owned point after core validation. It must stay non-blocking.

## PlayerBot command and dialogue interpretation

There are two distinct paths and they should remain distinct.

### Master command path

`WorldSession::HandleMessagechatOpcode`
→ `PlayerbotPlayerScript::OnChatCommand` (`src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp:189-198`)
→ `PlayerbotMgr::HandleCommand` (`PlayerbotMgr.cpp:1247-1298`)
→ `PlayerbotAI::HandleCommand` (`PlayerbotAI.cpp:1469-1634`)
→ `chatCommands`
→ `ReactionEngine::FindReaction` calling `PlayerbotAI::HandleCommands` (`strategy/ReactionEngine.cpp:37-47`)
→ `ExternalEventHelper::ParseChatCommand` (`strategy/ExternalEventHelper.h:14-59`).

This route contains security checks, addon filtering, command-prefix handling and command parsing. Free-form LLM dialogue must not bypass or reinterpret command text as instructions.

### Observed chat and reply path

Packets that would be sent to a Bot session are intercepted by `PlayerbotServerScript::CanPacketSend` at `PlayerbotScripts.cpp:63-87` and passed to `PlayerbotAI::HandleBotOutgoingPacket`.

For `SMSG_MESSAGECHAT`, `PlayerbotAI.cpp:1686-1796` parses the source GUID, channel, text and tag. Reply eligibility and cooldown logic live at `PlayerbotAI.cpp:1847-1935`. Eligible dialogue is put into `QueueChatResponse`; that queue is guarded by `chatRepliesMutex` at `PlayerbotAI.cpp:8678-8682` and drained from `PlayerbotAI::UpdateAIInternal` at lines 1233-1255. The drain calls `ChatReplyAction::ChatReplyDo` (`strategy/actions/SayAction.cpp:451-672`).

This is the closest existing semantic boundary for a later dialogue request.

## Resolving the addressed Bot and its GUID

- For a master whisper, `PlayerbotMgr::HandleCommand` compares the packet's `to` name with each controlled Bot's `bot->GetName()` at `PlayerbotMgr.cpp:1267-1280` and again for mastered random Bots at lines 1283-1298. Once the lambda selects `bot`, its authoritative identity is `bot->GetGUIDLow()` / `bot->GetObjectGuid()`; no database lookup is needed.
- For observed chat, each `PlayerbotAI` already owns the addressed `bot` pointer. The message's sender GUID is decoded at `PlayerbotAI.cpp:1698-1743`, and the Bot identity must be copied into the request envelope while still on the owning thread.
- A future worker must carry only scalar identifiers and immutable strings. It must not retain `Player*`, `PlayerbotAI*`, `WorldSession*`, map objects or channel pointers.
- On completion, resolve the Bot again by GUID and reject the result if the Bot/session no longer exists, the request is stale, the channel is no longer valid, or the request ID does not match the Bot's outstanding request.

## Existing Bot speech and channel selection

`PlayerbotAI::GetChatChannelSource` at `PlayerbotAI.cpp:3072-3169` maps named channels plus whisper, say, yell, guild, party, raid and emote types into `ChatChannelSource`.

`ChatReplyAction::SendGeneralResponse` at `strategy/actions/SayAction.cpp:976-1049` maps that source to existing outbound methods such as:

- `PlayerbotAI::Whisper` (`PlayerbotAI.cpp:3588-3617`)
- `PlayerbotAI::Say` (`PlayerbotAI.cpp:3552-3585`)
- `PlayerbotAI::Yell` (`PlayerbotAI.cpp:3520-3549`)
- `SayToGuild`, `SayToWorld`, `SayToGeneral`, `SayToParty` and `SayToRaid` (`PlayerbotAI.cpp:3172-3518`)

The low-level core methods `Player::Say` and `Player::Whisper` build and send normal chat packets at `src/game/Objects/Player.cpp:19327-19338` and `19377-19387`.

## Can existing Bot announcements be reused?

Partly.

`BroadcastHelper::BroadcastToChannelWithGlobalChance` (`playerbot/BroadcastHelper.cpp:72-180`) already delegates to the same `PlayerbotAI::SayTo*` methods, so those low-level outbound methods and the normal packet path are reusable after a completion returns to the owning thread.

The announcement selector itself should not be used for an LLM reply: it applies random global chances and may choose broad public channels. A conversational response must preserve the validated source channel and target. `ChatReplyAction::SendGeneralResponse` is the closer reusable mapping, with an additional Phase-1 allowlist and exact target revalidation.

## Thread ownership and blocking restrictions

- `PACKET_PROCESS_WORLD` is explicitly described as non-thread-safe work that must run in `World::UpdateSessions` (`src/game/WorldSession.h:124-152`). Map work has only current-map mutation rights.
- Whisper/channel/party/guild chat can be processed by `World::ProcessAsyncPackets` (`src/game/World.cpp:2515-2539`), which is paused around `World::UpdateSessions` at `World.cpp:2662-2672`. A module hook must still not perform a multi-second HTTP call there.
- PlayerBot AI updates are driven from `PlayerbotWorldScript::OnUpdate` (`PlayerbotScripts.cpp:48-55`). `PlayerbotAI::UpdateAIInternal` reads and mutates live Bot, map, group, session and AI state; it must not block on inference.
- The pinned `PlayerbotLLMInterface::Generate` is deliberately a no-response stub at `PlayerbotLLMInterface.cpp:376-382`; therefore the pinned build has no active LLM network client.
- `DebugAction::HandleLLM` calls `Generate` synchronously at `strategy/actions/DebugAction.cpp:1233-1247`. Re-enabling network I/O inside that function would block its owning update path and must be prohibited.
- The existing chat experiment launches `std::async` in `SayAction.cpp:653-655`, then `PlayerbotAI::SendDelayedPacket` starts a detached thread which holds a raw `WorldSession*`, waits, sleeps and queues packets (`PlayerbotAI.cpp:7978-7992`). Although `WorldSession::QueuePacket` feeds a mutex-backed queue, the detached raw pointer has lifetime/cancellation risks and the path lacks GUID/request-ID revalidation. It is not a sufficient production boundary.

## Message length and encoding

- Chat payloads are `std::string` byte sequences. `ChatHandler::BuildChatPacket` writes `messageFinal.length() + 1` at `src/game/Chat/Chat.cpp:2258-2320`.
- With strict link checking enabled, `ChatHandler::isValidChatMessage` rejects more than 255 bytes (`Chat.cpp:1881-1896`); this is not a universal outbound guard.
- The legacy fallback truncates with `respondsText.resize(255)` at `SayAction.cpp:1522-1525`, and `LinesToPackets` splits at byte position 200 at lines 355-396. Either operation can split a multibyte UTF-8 character.
- Valid UTF-8 helpers already exist: `utf8length` and `utf8truncate` at `src/shared/Util.cpp:413-444`. A later bridge should reject invalid UTF-8, remove controls/newlines, cap sentences, then enforce both a character limit and a conservative packet byte limit without cutting a code point.
- `PlayerbotLLMInterface::SanitizeForJson` at `PlayerbotLLMInterface.cpp:233-270` treats invalid UTF-8 as Windows-1251. That fallback is not an appropriate German-text contract; the bridge should require valid UTF-8 end to end.

## Recommended asynchronous boundary for Phase 1

1. On the owning chat/AI path, after eligibility and target selection, build an immutable request containing `request_id`, `bot_guid`, speaker GUID, source channel, target identity, sanitized user text and an immutable personality snapshot.
2. Push it to a bounded queue owned by a bridge service. For the first live phase, keep queue capacity and active inference count at one. Never enqueue raw game pointers.
3. A dedicated worker performs the loopback HTTP request with finite connect/response deadlines and no tools. It returns a sanitized completion containing the same request ID and Bot GUID.
4. Push the completion to a second mutex-protected queue. Do not call game APIs from the worker.
5. Drain completions from `PlayerbotWorldScript::OnUpdate` (`PlayerbotScripts.cpp:48-55`) or an equivalent manager-owned world-tick hook. Resolve the Bot by GUID, revalidate lifetime, outstanding request, permissions, channel and target, then invoke the existing `PlayerbotAI::Whisper`/`Say`/`SayTo*` path.
6. Drop stale, duplicate, mismatched, timed-out or oversized completions silently to evidence/logging; never retry automatically into game chat.

This design keeps network latency outside world/map/AI execution while preserving authoritative game-state access and existing outbound chat behavior on the proper thread.
