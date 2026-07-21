#include "scriptPCH.h"
#include "Pet.h"
#include "Totem.h"

namespace
{
template <class T>
SpellScript* GetSpellScript(SpellEntry const*)
{
    return new T();
}

template <class T>
AuraScript* GetAuraScript(SpellEntry const*)
{
    return new T();
}

void RegisterSpellScript(char const* name, SpellScript* (*getter)(SpellEntry const*))
{
    Script* script = new Script;
    script->Name = name;
    script->GetSpellScript = getter;
    script->RegisterSelf();
}

void RegisterAuraScript(char const* name, AuraScript* (*getter)(SpellEntry const*))
{
    Script* script = new Script;
    script->Name = name;
    script->GetAuraScript = getter;
    script->RegisterSelf();
}

uint32 GetLightningShieldDamageSpell(uint32 spellId)
{
    switch (spellId)
    {
        case 324: return 26364;
        case 325: return 26365;
        case 905: return 26366;
        case 945: return 26367;
        case 8134: return 26369;
        case 10431: return 26370;
        case 10432: return 26363;
        default: return 0;
    }
}

struct spell_shaman_thunderhead : public SpellScript
{
    void OnSetTargetMap(Spell* spell, SpellEffectIndex /*effIdx*/, uint32& targetMode, float& /*radius*/, uint32& /*unMaxTargets*/, bool& /*selectClosestTargets*/) const override
    {
        if (!spell->m_casterUnit || !spell->m_casterUnit->HasAura(45508) || spell->m_casterUnit->GetTargetGuid().IsEmpty())
            return;

        Unit* friendlyTarget = spell->m_casterUnit->GetMap()->GetUnit(spell->m_casterUnit->GetTargetGuid());
        if (!friendlyTarget || !friendlyTarget->IsFriendlyTo(spell->m_casterUnit) ||
                !friendlyTarget->IsCharmerOrOwnerPlayerOrPlayerItself() ||
                spell->m_spellInfo->MinTargetLevel > friendlyTarget->GetLevel() ||
                (!spell->m_casterUnit->IsPvP() && friendlyTarget->IsPvP()))
            return;

        targetMode = TARGET_UNIT_FRIEND;
        spell->m_targets.setUnitTarget(friendlyTarget);
    }
};

struct spell_shaman_lightning_shield : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim)
            return SPELL_AURA_PROC_FAILED;

        uint32 triggerSpellId = GetLightningShieldDamageSpell(aura->GetId());
        if (!triggerSpellId)
            return SPELL_AURA_PROC_FAILED;

        Unit* caster = owner;
        if (Unit* auraCaster = aura->GetCaster())
            if (owner->IsWithinDistInMap(auraCaster, VISIBILITY_DISTANCE_NORMAL))
                caster = auraCaster;

        caster->CastSpell(victim, triggerSpellId, true, nullptr, aura, caster->GetObjectGuid(), nullptr, procSpell);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_shaman_elemental_focus : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        uint32 triggerSpellId = aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()];
        if (owner->HasAura(triggerSpellId))
            owner->RemoveAurasDueToSpellByCancel(triggerSpellId);

        return std::nullopt;
    }
};

struct spell_shaman_lightning_speed : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* /*holder*/, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procExtra*/, WeaponAttackType /*attType*/, bool /*isVictim*/) override
    {
        if (!procSpell)
            return SPELL_PROC_TRIGGER_FAILED;

        if (procSpell->IsFitToFamily<SPELLFAMILY_SHAMAN, CF_SHAMAN_LIGHTNING_BOLT>())
            return roll_chance_u(10) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_ROLL_FAILED;

        if (procSpell->SpellIconID == 2210)
            return roll_chance_u(50) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_ROLL_FAILED;

        return SPELL_PROC_TRIGGER_FAILED;
    }
};

struct spell_shaman_rockbiter_proc : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target || !target->CanHaveThreatList() || !spell->m_casterUnit)
            return false;

        if (target->GetThreatManager().getThreat(spell->m_casterUnit))
            target->GetThreatManager().addThreat(spell->m_casterUnit, spell->damage * spell->m_casterUnit->GetAttackTime(BASE_ATTACK) / 1000);

        return false;
    }
};

struct spell_shaman_rockbiter_weapon : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex /*effIdx*/) const override
    {
        uint32 enchantSpellId = 0;
        switch (spell->m_spellInfo->Id)
        {
            case 8017:  enchantSpellId = 36494; break;
            case 8018:  enchantSpellId = 36750; break;
            case 8019:  enchantSpellId = 36755; break;
            case 10399: enchantSpellId = 36759; break;
            case 16314: enchantSpellId = 36763; break;
            case 16315: enchantSpellId = 36766; break;
            case 16316: enchantSpellId = 36771; break;
            default:
                sLog.outError("spell_shaman_rockbiter_weapon: Spell %u not handled.", spell->m_spellInfo->Id);
                return false;
        }

        SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(enchantSpellId);
        if (!spellInfo)
        {
            sLog.outError("spell_shaman_rockbiter_weapon: unknown spell id %u", enchantSpellId);
            return false;
        }

        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return false;

        for (int j = BASE_ATTACK; j <= OFF_ATTACK; ++j)
        {
            Item* item = player->GetWeaponForAttack(WeaponAttackType(j));
            if (!item || !item->IsFitToSpellRequirements(spell->m_spellInfo))
                continue;

            Spell* enchantSpell = new Spell(player, spellInfo, true);
            enchantSpell->m_currentBasePoints[EFFECT_INDEX_1] = spell->damage;

            SpellCastTargets targets;
            targets.setItemTarget(item);
            enchantSpell->prepare(std::move(targets));
        }

        return false;
    }
};

struct spell_shaman_flametongue_proc : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        if (!spell->m_CastItem)
        {
            sLog.outError("spell_shaman_flametongue_proc: spell %u requires cast item", spell->m_spellInfo->Id);
            return false;
        }

        int32 spellDamage = spell->m_caster->SpellBaseDamageBonusDone(spell->m_spellInfo->GetSpellSchoolMask());
        float weaponSpeed = (1.0f / IN_MILLISECONDS) * spell->m_CastItem->GetProto()->Delay;
        int32 totalDamage = int32((spell->damage + 3.85f * spellDamage) * 0.01f * weaponSpeed);
        spell->m_caster->CastCustomSpell(target, 10444, &totalDamage, nullptr, nullptr, true, spell->m_CastItem);
        return false;
    }
};

// Deprecated in patch 1.17.2
struct spell_shaman_mana_tide : public AuraScript
{
    void OnPeriodicTrigger(Aura* aura, Unit* /*caster*/, Unit* target, WorldObject* /*targetObject*/, SpellEntry const*& spellInfo) override
    {
        uint32 triggerSpellId = aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()];
        if (!triggerSpellId)
            return;

        int32 amount = aura->GetModifier()->m_amount;
        target->CastCustomSpell(target, triggerSpellId, &amount, nullptr, nullptr, true, nullptr, aura);
        spellInfo = nullptr;
    }
};

struct spell_shaman_feral_spirit : public SpellScript
{
    void OnSummonBeforeAdd(Spell* spell, Pet* summon, uint32 summonIndex) const override
    {
        if (!spell->m_casterUnit)
            return;

        summon->InitStatsForLevel(spell->m_casterUnit->GetLevel());
        summon->SetFollowAngle(PET_FOLLOW_ANGLE + summonIndex * M_PI_F);
    }
};

struct spell_shaman_ghost_wolf_speed : public AuraScript
{
    void OnAfterApply(Aura* aura, bool /*apply*/) override
    {
        Unit* target = aura->GetTarget();
        SpellAuraHolder* ghostWolf = target->GetSpellAuraHolder(2645);
        if (!ghostWolf)
            return;

        Aura* speedAura = ghostWolf->GetAuraByEffectIndex(EFFECT_INDEX_1);
        if (!speedAura)
            return;

        speedAura->GetModifier()->m_amount = target->CalculateSpellDamage(target, ghostWolf->GetSpellProto(), EFFECT_INDEX_1);
        target->UpdateSpeed(MOVE_RUN, false, target->GetSpeedRatePersistance(MOVE_RUN));
    }
};

struct spell_shaman_calming_river : public AuraScript
{
    void OnAuraInit(Aura* aura) override
    {
        aura->SetPeriodicTimer(5000);
    }

    void OnPeriodicDummy(Aura* aura) override
    {
        Unit* target = aura->GetTarget();
        if (target->HasAura(45527) && target->GetPower(POWER_MANA) != target->GetMaxPower(POWER_MANA))
            target->CastSpell(target, 47358, true, nullptr, aura);
    }
};

struct spell_shaman_totemic_recall : public SpellScript
{
    void OnDestroyTotem(Spell* spell, Totem* totem) const override
    {
        if (!spell->m_casterUnit || !totem)
            return;

        uint32 const spellId = totem->GetUInt32Value(UNIT_CREATED_BY_SPELL);
        SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(spellId);
        if (!spellInfo)
            return;

        spell->m_casterUnit->ModifyPower(POWER_MANA, spellInfo->GetManaCost() / 100 * 25);
    }
};

struct spell_spirit_armor : public AuraScript
{
    void OnAfterApply(Aura* aura, bool /*apply*/) override
    {
        aura->GetTarget()->UpdateArmor();
    }
};
}

void AddSC_shaman_spell_scripts()
{
    RegisterSpellScript("spell_shaman_thunderhead", &GetSpellScript<spell_shaman_thunderhead>);
    RegisterSpellScript("spell_shaman_rockbiter_proc", &GetSpellScript<spell_shaman_rockbiter_proc>);
    RegisterSpellScript("spell_shaman_rockbiter_weapon", &GetSpellScript<spell_shaman_rockbiter_weapon>);
    RegisterSpellScript("spell_shaman_flametongue_proc", &GetSpellScript<spell_shaman_flametongue_proc>);
    RegisterAuraScript("spell_shaman_lightning_shield", &GetAuraScript<spell_shaman_lightning_shield>);
    RegisterAuraScript("spell_shaman_elemental_focus", &GetAuraScript<spell_shaman_elemental_focus>);
    RegisterAuraScript("spell_shaman_lightning_speed", &GetAuraScript<spell_shaman_lightning_speed>);
    RegisterAuraScript("spell_shaman_mana_tide", &GetAuraScript<spell_shaman_mana_tide>);
    RegisterSpellScript("spell_shaman_feral_spirit", &GetSpellScript<spell_shaman_feral_spirit>);
    RegisterAuraScript("spell_shaman_ghost_wolf_speed", &GetAuraScript<spell_shaman_ghost_wolf_speed>);
    RegisterAuraScript("spell_shaman_calming_river", &GetAuraScript<spell_shaman_calming_river>);
    RegisterSpellScript("spell_shaman_totemic_recall", &GetSpellScript<spell_shaman_totemic_recall>);
    RegisterAuraScript("spell_spirit_armor", &GetAuraScript<spell_spirit_armor>);
}
