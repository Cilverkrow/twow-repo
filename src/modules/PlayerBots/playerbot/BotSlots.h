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
// The slot ids are claimed by name at first use. The function-local statics
// make that a one-time cost; afterwards each accessor is the same array index
// it was when the ids were an enum in the core. The core no longer knows these
// names exist, so adding a module costs no core edit and no rebuild.

inline uint8 BotAiSlot()
{
    static uint8 const slot = ClaimModuleSlot("playerbots.ai");
    return slot;
}

inline uint8 BotMgrSlot()
{
    static uint8 const slot = ClaimModuleSlot("playerbots.mgr");
    return slot;
}

inline PlayerbotAI* GetBotAI(Player const* player)
{
    return player ? player->GetModuleSlotAs<PlayerbotAI>(BotAiSlot()) : nullptr;
}

inline PlayerbotMgr* GetBotMgr(Player const* player)
{
    return player ? player->GetModuleSlotAs<PlayerbotMgr>(BotMgrSlot()) : nullptr;
}

inline void SetBotAI(Player* player, PlayerbotAI* ai)
{
    if (player)
        player->SetModuleSlot(BotAiSlot(), ai);
}

inline void SetBotMgr(Player* player, PlayerbotMgr* mgr)
{
    if (player)
        player->SetModuleSlot(BotMgrSlot(), mgr);
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
