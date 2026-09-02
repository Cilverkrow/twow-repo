#ifndef BOT_SLOTS_H
#define BOT_SLOTS_H

#include "ModuleSlots.h"
#include "Objects/Player.h"

class PlayerbotAI;
class PlayerbotMgr;

// Typed access to the two player slots this module claims.
//
// These replace Player::GetPlayerbotAI() and Player::GetPlayerbotMgr(). The
// pointers live in the same place they always did - one load from a fixed
// offset in Player - so reading them costs what it used to. What changed is
// that Player.h no longer names a bot type.
//
// Free functions rather than members because a module cannot add members to a
// core class, which is the whole point of the slots.
//
// The slot ids come from the core's ModuleSlots.h enum, which upstream owns.
//
// This module used to claim them at runtime by name, so that adding a module
// cost no core edit. We gave that up on 2026-09-02 to stop diverging from a
// file upstream owns -- it removed our ModuleSlots.h delta and our extra
// ModuleSlots.cpp. Read the trade-off before adding a third slot:
//
//   - a NEW module needing per-player state now needs a line in
//     core/src/game/ModuleSlots.h, which is a submodule, so that is a pull
//     request in twow-core, not a commit here;
//   - ModuleSlots.h is included by Player.h, so that one line rebuilds
//     ~1060 of the 1171 translation units;
//   - two modules must never share a number, and nothing checks at runtime.
//
// Acceptable today because mod-playerbots is the only one of seven modules
// that uses a slot. If a second one needs one, revisit the decision --
// docs/adr/ADR-0021, "Update 2026-09-02".
//
// The accessors below are unchanged on purpose: 442 references to GetBotAI /
// GetBotMgr across 85 files see the same signatures and the same cost, one
// load from a fixed offset in Player.

inline PlayerbotAI* GetBotAI(Player const* player)
{
    return player ? player->GetModuleSlotAs<PlayerbotAI>(MODULE_SLOT_BOT_AI) : nullptr;
}

inline PlayerbotMgr* GetBotMgr(Player const* player)
{
    return player ? player->GetModuleSlotAs<PlayerbotMgr>(MODULE_SLOT_BOT_MGR) : nullptr;
}

inline void SetBotAI(Player* player, PlayerbotAI* ai)
{
    if (player)
        player->SetModuleSlot(MODULE_SLOT_BOT_AI, ai);
}

inline void SetBotMgr(Player* player, PlayerbotMgr* mgr)
{
    if (player)
        player->SetModuleSlot(MODULE_SLOT_BOT_MGR, mgr);
}

// Lifecycle. Were Player::Create/RemovePlayerbotAI and ...Mgr.
void CreateBotAI(Player* player);
void RemoveBotAI(Player* player);
void CreateBotMgr(Player* player);
void RemoveBotMgr(Player* player);

// Was Player::isRealPlayer(). Out of line because it has to ask the AI whether
// a real session sits behind it - having an AI attached is not the same as
// being machine driven.
bool IsRealPlayer(Player const* player);

#endif
