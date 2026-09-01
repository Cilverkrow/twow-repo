// Returns a player who died alone inside an instance to its entrance, alive,
// instead of starting a corpse run.
//
// Lifted from Player::RepopAtGraveyard(), where it lived inline. Unlike the
// other extracted features this one had no hook to attach to: it has to
// pre-empt the core's graveyard selection entirely, so it needed a new veto
// hook (PLAYERHOOK_ON_REPOP_AT_GRAVEYARD). Returning true from OnRepopAtGraveyard
// means "handled"; the core stops before choosing a graveyard.
//
// The target is the instance ENTRANCE trigger, not a graveyard: instance
// graveyards sit outside the instance -- that is what the corpse run is for --
// so resurrecting at one would drop the player out of the dungeon.

#include "ScriptObjects.h"

#include "Config/Config.h"
#include "Group/Group.h"
#include "Maps/Map.h"
#include "Objects/Player.h"
#include "ObjectMgr.h"
#include "ScriptMgr.h"

namespace
{
    class SoloDungeonRepopScript : public PlayerScript
    {
    public:
        SoloDungeonRepopScript()
            : PlayerScript("mod_solo_dungeon_player", { PLAYERHOOK_ON_REPOP_AT_GRAVEYARD })
        {
        }

        bool OnRepopAtGraveyard(Player* player) override
        {
            if (!player || player->IsAlive())
                return false;

            // Map::IsDungeon() covers raids and excludes battlegrounds, which
            // are their own map type.
            if (!player->GetMap() || !player->GetMap()->IsDungeon())
                return false;

            if (!ShouldRepopAtEntrance(player))
                return false;

            AreaTriggerTeleport const* entrance = sObjectMgr.GetMapEntranceTrigger(player->GetMapId());
            if (!entrance)
                return false;

            player->ResurrectPlayer(1.0f);
            player->SpawnCorpseBones();
            player->TeleportTo(entrance->destination, TELE_TO_NOT_UNSUMMON_PET);
            return true;
        }

    private:
        static bool ShouldRepopAtEntrance(Player* player)
        {
            // Bots get this regardless of the config and regardless of a group:
            // they cannot walk back in through an instance portal
            // (LfgTeleportAction is MANGOSBOT_TWO only), so a wipe would strand
            // them as ghosts at the outdoor graveyard for good and the group
            // would be over. Not a perk - the only way back to the party.
            if (Script_IsAIControlled(player))
                return true;

            if (!sConfig.GetBoolDefault("SoloDungeonRepopAlive.Enable", false))
                return false;

            return !HasHumanHelp(player);
        }

        // "Solo" means nobody who could resurrect you: no group, or a group
        // whose only other members are bots. After a wipe a bot party is no
        // more help than an empty one, and releasing the spirit already means
        // you chose not to wait for a resurrection.
        //
        // Deliberately solo only - with a group present someone can resurrect,
        // and this would be a free pass.
        static bool HasHumanHelp(Player* player)
        {
            Group* group = player->GetGroup();
            if (!group)
                return false;

            for (GroupReference* itr = group->GetFirstMember(); itr; itr = itr->next())
            {
                Player* member = itr->getSource();
                if (member && member != player && !Script_IsAIControlled(member))
                    return true;
            }
            return false;
        }
    };
}

void Addmod_solo_dungeonScripts()
{
    new SoloDungeonRepopScript();
}
