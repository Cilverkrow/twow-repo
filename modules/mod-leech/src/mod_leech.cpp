// Heals a player for a share of the damage they deal.
//
// Lifted from Unit::DealDamage(), where it lived inline. Behaviour is
// unchanged, including the four restrictions and their defaults.
//
// It hangs off UNITHOOK_ON_DAMAGE_APPLIED rather than the older
// UNITHOOK_ON_DAMAGE for a reason worth keeping: OnDamage fires early, while
// the number can still be changed, and between the two dispatch points the core
// applies hardcore pet scaling and the pet avoidance halving. Leeching a share
// of damage has to use the figure that actually lands, so it needs the late
// hook. Reusing the early one would have quietly changed how much every player
// heals.

#include "ScriptObjects.h"

#include "AccountMgr.h"
#include "Config/Config.h"
#include "Group/Group.h"
#include "Maps/Map.h"
#include "Objects/Player.h"
#include "Objects/Unit.h"
#include "WorldSession.h"

#include <string>

namespace
{
    // Vampiric-style self-heal. Cast on the attacker with the leeched amount as
    // its basepoints.
    uint32 constexpr SPELL_LEECH_HEAL = 18984;

    class LeechScript : public UnitScript
    {
    public:
        LeechScript()
            : UnitScript("mod_leech_unit", { UNITHOOK_ON_DAMAGE_APPLIED })
        {
        }

        void OnDamageApplied(Unit* attacker, Unit* victim, uint32 damage) override
        {
            if (!damage || !attacker || !victim)
                return;

            if (!sConfig.GetBoolDefault("Leech.Enable", false))
                return;

            Player* player = ResolveBeneficiary(attacker);
            if (!player || !IsEligible(player, victim))
                return;

            float const share = float(sConfig.GetFloatDefault("Leech.Amount", 0.05f));
            int32 healed = int32(share * float(damage));
            if (healed <= 0)
                return;

            player->CastCustomSpell(attacker, SPELL_LEECH_HEAL, &healed, nullptr, nullptr, true);
        }

    private:
        // A pet's damage credits its owner; anything else credits itself.
        static Player* ResolveBeneficiary(Unit* attacker)
        {
            Unit* owner = attacker->GetOwner();
            if (owner && owner->GetTypeId() == TYPEID_PLAYER)
                return owner->ToPlayer();
            return attacker->ToPlayer();
        }

        // Without these the leech applies to EVERY player - including the ~1000
        // random bots - and in PvP as well, where a flat heal on damage dealt
        // skews fights. Each restriction switches off on its own; all default to
        // on, so a bare "Leech.Enable = 1" holds no surprises.
        static bool IsEligible(Player* player, Unit* victim)
        {
            // Against non-players only (PvE).
            if (sConfig.GetBoolDefault("Leech.PvEOnly", true) && victim->IsPlayer())
                return false;

            // Solo only: no party, no raid.
            if (sConfig.GetBoolDefault("Leech.SoloOnly", true) && player->GetGroup())
                return false;

            // Instances only. Levelling out in the open world stays untouched;
            // the bonus applies where soloing actually gets hard. Map::IsDungeon
            // covers dungeons and raids.
            if (sConfig.GetBoolDefault("Leech.DungeonOnly", true) &&
                !(player->GetMap() && player->GetMap()->IsDungeon()))
                return false;

            // Real players only. Random bots run on RNDBOT accounts, looked up
            // by account id because bot sessions carry no account name of their
            // own. Compared case insensitively.
            if (sConfig.GetBoolDefault("Leech.RealPlayersOnly", true))
            {
                std::string accountName;
                if (WorldSession* session = player->GetSession())
                    sAccountMgr.GetName(session->GetAccountId(), accountName);
                for (char& c : accountName)
                    if (c >= 'a' && c <= 'z')
                        c = c - 'a' + 'A';
                if (accountName.rfind("RNDBOT", 0) == 0)
                    return false;
            }

            return true;
        }
    };
}

void Addmod_leechScripts()
{
    new LeechScript();
}
