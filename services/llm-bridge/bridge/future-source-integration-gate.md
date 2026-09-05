# Future source-integration gate — not started

`SOURCE_INTEGRATION_GATE=BLOCKED_PENDING_APPROVED_STABLE_REVISION`

Phase 1A deliberately contains no source adapter or patch. It did not modify or compile `mangosd`, and it did not re-enable or call an existing in-source LLM path.

The Phase-0 map recorded `42b8a7f742548793910fe8880463aeeb71627fb9` as the revision it inspected. That value is historical evidence only. Phase 1A does **not** claim that it is the independently approved stable integration revision.

Before any later source integration, a separate task and evidence package must:

1. Obtain the exact approved stable revision through the responsible approval channel and record that approval separately from this prototype.
2. Resolve the repository, remote, branch/ref, commit object, submodule state, and working-tree condition without treating pre-existing local changes as approved source.
3. Re-read every cited source file from the approved commit object, not from an unverified working tree.
4. Revalidate the complete incoming chat path, command/security checks, Bot resolution and GUID capture, chat-channel/target selection, outbound speech path, owning-thread rules, message byte/UTF-8 limits, and safe asynchronous handoff point.
5. Specifically revalidate the Phase-0 citations for `WorldSession::HandleMessagechatOpcode`, `PlayerbotPlayerScript::OnChatCommand`, `PlayerbotMgr::HandleCommand`, `PlayerbotAI::HandleCommand`, `PlayerbotAI::HandleBotOutgoingPacket`, `QueueChatResponse`, `PlayerbotAI::UpdateAIInternal`, `ChatReplyAction::ChatReplyDo`, `ChatReplyAction::SendGeneralResponse`, `PlayerbotAI::GetChatChannelSource`, the `PlayerbotAI::Whisper`/`Say`/`SayTo*` methods, `PlayerbotWorldScript::OnUpdate`, `PlayerbotLLMInterface::Generate`, and the existing detached delayed-packet path.
6. Reconfirm that any later worker carries only copied scalar IDs and immutable bytes—never `Player*`, `PlayerbotAI*`, `WorldSession*`, map/channel objects, or other raw game pointers.
7. Produce a new read-only integration map with exact commit-relative paths and line references, obtain approval on that evidence, and only then propose a separately authorized source patch.

Until all seven items pass, source integration, game-chat emission, database access, and activation of an existing LLM route remain out of scope.
