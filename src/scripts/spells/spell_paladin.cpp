#include "scriptPCH.h"

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

void RegisterSpellAndAuraScript(char const* name, SpellScript* (*spellGetter)(SpellEntry const*), AuraScript* (*auraGetter)(SpellEntry const*))
{
    Script* script = new Script;
    script->Name = name;
    script->GetSpellScript = spellGetter;
    script->GetAuraScript = auraGetter;
    script->RegisterSelf();
}

struct spell_paladin_invulnerability_forbearance : public SpellScript
{
    void OnCast(Spell* spell) const override
    {
        if (spell->m_spellInfo->Id != 25771)
            spell->AddPrecastSpell(25771);
    }
};

struct spell_paladin_hammer_of_wrath : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex effIdx, float& damage) const override
    {
        Unit* target = spell->GetUnitTarget();
        if (!target)
            return;

        spell->m_attackType = BASE_ATTACK;
        damage = spell->m_caster->SpellDamageBonusDone(target, spell->m_spellInfo, effIdx, damage, SPELL_DIRECT_DAMAGE);
        damage = target->SpellDamageBonusTaken(spell->m_caster, spell->m_spellInfo, effIdx, damage, SPELL_DIRECT_DAMAGE);
    }
};

struct spell_paladin_judgement_of_command : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex effIdx, float& damage) const override
    {
        Unit* target = spell->GetUnitTarget();
        if (!target)
            return;

        if (!target->HasUnitState(UNIT_STAT_STUNNED | UNIT_STAT_PENDING_STUNNED))
            damage = int32(damage * 0.5f);

        damage = spell->m_caster->SpellDamageBonusDone(target, spell->m_spellInfo, effIdx, damage, SPELL_DIRECT_DAMAGE);
        damage = target->SpellDamageBonusTaken(spell->m_caster, spell->m_spellInfo, effIdx, damage, SPELL_DIRECT_DAMAGE);
    }
};

struct spell_paladin_judgement_of_command_dummy : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        if (spell->m_spellInfo->Id == 45954 || spell->m_spellInfo->Id == 45953)
            return false;

        uint32 spellId = spell->m_currentBasePoints[effIdx];
        SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(spellId);
        if (!spellInfo)
            return false;

        spell->m_caster->CastSpell(target, spellInfo, true, nullptr);
        return false;
    }
};

struct spell_paladin_judgement_of_the_crusader : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (spell->m_spellInfo->Effect[effIdx] != SPELL_EFFECT_DUMMY)
            return true;

        Unit* target = spell->GetUnitTarget();
        Player* player = spell->m_caster->ToPlayer();
        if (!target || !player)
            return false;

        bool hasProc = false;
        if (Item* item = player->GetWeaponForAttack(BASE_ATTACK, true, true))
        {
            float chanceMultiplier = spell->m_currentBasePoints[effIdx];
            for (auto const& spellData : item->GetProto()->Spells)
            {
                if (!spellData.SpellId || spellData.SpellTrigger != ITEM_SPELLTRIGGER_CHANCE_ON_HIT)
                    continue;

                hasProc = true;

                if (SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(spellData.SpellId))
                {
                    if (spellInfo->Id == 16602 ||
                        spellInfo->Id == 16928 ||
                        spellInfo->Id == 16939 ||
                        spellInfo->Id == 23605 ||
                        spellInfo->Id == 48102 ||
                        spellInfo->IsCCSpell() ||
                        spellInfo->HasAura(SPELL_AURA_MOD_CONFUSE) ||
                        spellInfo->HasAura(SPELL_AURA_MOD_DECREASE_SPEED) ||
                        spellInfo->HasAura(SPELL_AURA_MOD_CASTING_SPEED_NOT_STACK))
                        chanceMultiplier *= 0.2f;
                    else if (spellInfo->IsAreaOfEffectSpell())
                        chanceMultiplier *= 0.5f;
                }
            }

            if (chanceMultiplier < 2.0f)
                chanceMultiplier = 2.0f;

            player->CastItemCombatSpell(target, BASE_ATTACK, chanceMultiplier);
        }

        if (!hasProc)
        {
            if (SpellEntry const* judgement = sSpellMgr.GetSpellEntry(20271))
            {
                uint32 manaCost = Spell::CalculatePowerCost(judgement, player);
                player->ModifyPower(POWER_MANA, manaCost);
            }
        }

        return false;
    }
};

struct spell_paladin_holy_shock : public SpellScript
{
    SpellCastResult OnCheckCast(Spell* spell, bool /*strict*/) const override
    {
        Unit* target = spell->m_targets.getUnitTarget();
        if (target && !spell->m_caster->IsFriendlyTo(target) && !spell->m_caster->IsFacingTarget(target))
            return SPELL_FAILED_UNIT_NOT_INFRONT;

        return SPELL_CAST_OK;
    }

    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        uint32 damageSpellId = 0;
        uint32 healSpellId = 0;
        switch (spell->m_spellInfo->Id)
        {
            case 20473: damageSpellId = 25912; healSpellId = 25914; break;
            case 20929: damageSpellId = 25911; healSpellId = 25913; break;
            case 20930: damageSpellId = 25902; healSpellId = 25903; break;
            default:
                sLog.outError("spell_paladin_holy_shock: Spell %u not handled", spell->m_spellInfo->Id);
                return false;
        }

        spell->m_caster->CastSpell(target, spell->m_caster->IsFriendlyTo(target) ? healSpellId : damageSpellId, true);
        return false;
    }
};

struct spell_paladin_holy_strike : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return true;

        Unit::SpellAuraHolderMap const& auraHolders = target->GetSpellAuraHolderMap();
        for (auto const& auraHolder : auraHolders)
        {
            SpellAuraHolder* holder = auraHolder.second;
            if (!holder || Spells::GetSpellSpecific(holder->GetId()) != SPELL_JUDGEMENT)
                continue;

            int32 maxDuration = holder->GetAuraMaxDuration();
            int32 currentDuration = holder->GetAuraDuration();
            if (currentDuration > 0)
                target->RefreshAura(holder->GetId(), maxDuration);

            break;
        }

        return true;
    }
};

struct spell_paladin_judgement : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target || !target->IsAlive() || !spell->m_casterUnit)
            return false;

        uint32 spellId = 0;
        Unit::AuraList const& dummyAuras = spell->m_casterUnit->GetAurasByType(SPELL_AURA_DUMMY);
        for (Aura const* aura : dummyAuras)
        {
            SpellEntry const* auraSpellInfo = aura->GetSpellProto();
            if (!auraSpellInfo || !auraSpellInfo->IsSealSpell() || aura->GetEffIndex() != EFFECT_INDEX_2)
                continue;

            spellId = auraSpellInfo->CalculateSimpleValue(EFFECT_INDEX_2);
            if (spellId <= 1)
                continue;

            spell->m_casterUnit->RemoveAurasDueToSpellByCancel(aura->GetId());
            break;
        }

        if (spellId)
            spell->m_caster->CastSpell(target, spellId, true);

        return false;
    }
};

struct spell_paladin_conviction_seals : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* holder, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procExtra*/, WeaponAttackType /*attType*/, bool /*isVictim*/) override
    {
        if (!procSpell || (procSpell->Id != 45619 && procSpell->Id != 45620))
            return std::nullopt;

        SpellEntry const* auraSpell = holder->GetSpellProto();
        if (auraSpell->IsFitToFamily<SPELLFAMILY_PALADIN, CF_PALADIN_SEAL_OF_THE_CRUSADER, CF_PALADIN_SEAL_OF_WISDOM_LIGHT, CF_PALADIN_SEAL_OF_COMMAND, CF_PALADIN_SEALS>())
            return roll_chance_u(50) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_ROLL_FAILED;

        return std::nullopt;
    }
};

// Deprecated in patch 1.17.2
struct spell_paladin_sanctified_command : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* /*holder*/, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procExtra*/, WeaponAttackType /*attType*/, bool /*isVictim*/) override
    {
        if (!procSpell)
            return SPELL_PROC_TRIGGER_FAILED;

        return (procSpell->SpellIconID == 561 && procSpell->DmgClass == 2 && procSpell->SpellVisual == 0) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_FAILED;
    }

    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!owner->ToPlayer() || !procSpell)
            return SPELL_AURA_PROC_FAILED;

        uint32 sealSpellId = 0;
        switch (procSpell->Id)
        {
            case 20467: sealSpellId = 20375; break;
            case 20963: sealSpellId = 20915; break;
            case 20964: sealSpellId = 20918; break;
            case 20965: sealSpellId = 20919; break;
            case 20966: sealSpellId = 20920; break;
            default: return SPELL_AURA_PROC_FAILED;
        }

        SpellEntry const* seal = sSpellMgr.GetSpellEntry(sealSpellId);
        if (!seal)
            return SPELL_AURA_PROC_FAILED;

        int32 mana = seal->manaCost * aura->GetModifier()->m_amount / 100;
        owner->CastCustomSpell(owner, 45987, &mana, nullptr, nullptr, true);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_eye_for_an_eye : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* /*holder*/, SpellEntry const* /*procSpell*/, uint32 procFlag, uint32 procExtra, WeaponAttackType /*attType*/, bool /*isVictim*/) override
    {
        return ((procFlag & PROC_FLAG_TAKE_HARMFUL_SPELL) && (procExtra & PROC_EX_CRITICAL_HIT)) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_FAILED;
    }
};

struct spell_paladin_improved_lay_on_hands : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* /*holder*/, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procExtra*/, WeaponAttackType /*attType*/, bool isVictim) override
    {
        if (!procSpell)
            return SPELL_PROC_TRIGGER_FAILED;

        return (procSpell->SpellFamilyName == SPELLFAMILY_PALADIN && procSpell->SpellIconID == 79 && procSpell->Category == 56 && !isVictim) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_FAILED;
    }
};

struct spell_paladin_seal_of_righteousness : public AuraScript
{
    std::optional<SpellProcEventTriggerCheck> OnCheckProc(Unit const* /*owner*/, Unit* /*victim*/, SpellAuraHolder* /*holder*/, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procExtra*/, WeaponAttackType /*attType*/, bool /*isVictim*/) override
    {
        if (!procSpell || (procSpell->Id != 45619 && procSpell->Id != 45620))
            return std::nullopt;

        return roll_chance_u(50) ? SPELL_PROC_TRIGGER_OK : SPELL_PROC_TRIGGER_ROLL_FAILED;
    }

    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (aura->GetEffIndex() != EFFECT_INDEX_0 || aura->GetModifier()->m_auraname != SPELL_AURA_PROC_TRIGGER_SPELL)
            return std::nullopt;

        Player* player = owner->ToPlayer();
        if (!victim || !player)
            return SPELL_AURA_PROC_FAILED;

        constexpr float maxWeaponSpeed = 4.0f;
        constexpr float minWeaponSpeed = 1.5f;
        Item* item = player->GetItemByPos(INVENTORY_SLOT_BAG_0, EQUIPMENT_SLOT_MAINHAND);
        float speed = (item ? item->GetProto()->Delay : BASE_ATTACK_TIME) / 1000.0f;

        float minDmg = aura->GetModifier()->m_amount / 87.0f;
        float maxDmg = aura->GetModifier()->m_amount / 25.0f;
        float damageBasePoints = (maxDmg - minDmg) * ((speed - minWeaponSpeed) / (maxWeaponSpeed - minWeaponSpeed)) + minDmg;
        int32 damagePoint = urand(0, 1) ? floor(damageBasePoints) : ceil(damageBasePoints);

        SpellEntry const* auraSpell = aura->GetSpellProto();
        if (damagePoint >= 0)
        {
            int32 const spellPowerBonus = owner->SpellBonusWithCoeffs(auraSpell, EFFECT_INDEX_0, 0,
                owner->SpellBaseDamageBonusDone(auraSpell->GetSpellSchoolMask()), 0, SPELL_DIRECT_DAMAGE, true, owner);
            damagePoint += spellPowerBonus;
        }

        uint32 const triggerSpellId = auraSpell->EffectTriggerSpell[EFFECT_INDEX_0];
        if (!triggerSpellId)
            return SPELL_AURA_PROC_FAILED;

        owner->CastCustomSpell(victim, triggerSpellId, &damagePoint, nullptr, nullptr, true, nullptr, aura);
        player->CastItemCombatSpell(victim, BASE_ATTACK);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_blessed_strikes : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!procSpell || !procSpell->IsFitToFamily<SPELLFAMILY_PALADIN, CF_PALADIN_CRUSADER_STRIKE>())
            return SPELL_AURA_PROC_FAILED;

        uint32 resetChance = uint32(aura->GetSpellProto()->EffectBasePoints[EFFECT_INDEX_2]) + 1;
        if (!roll_chance_i(resetChance))
            return SPELL_AURA_PROC_FAILED;

        Player* player = owner->ToPlayer();
        if (!player)
            return SPELL_AURA_PROC_FAILED;

        std::vector<uint32> spellsToClear;
        for (const auto& cdEntry : player->GetSpellCooldownMap())
        {
            SpellEntry const* cdSpell = sSpellMgr.GetSpellEntry(cdEntry.first);
            if (cdSpell && cdSpell->SpellFamilyName == SPELLFAMILY_PALADIN && cdSpell->IsFitToFamily<SPELLFAMILY_PALADIN, CF_PALADIN_HOLY_SHOCK>())
                spellsToClear.push_back(cdEntry.first);
        }

        for (uint32 spellId : spellsToClear)
            player->RemoveSpellCooldown(spellId, true);

        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_righteous_defense : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!owner->HasAura(25780))
            return SPELL_AURA_PROC_FAILED;

        uint32 triggerSpellId = aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()];
        if (owner->HasAura(triggerSpellId))
            owner->RemoveAurasDueToSpell(triggerSpellId);

        owner->CastSpell(owner, triggerSpellId, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_judgement_of_light_wisdom : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* /*owner*/, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        uint32 triggerSpellId = 0;
        switch (aura->GetId())
        {
            case 20185: triggerSpellId = 20267; break;
            case 20344: triggerSpellId = 20341; break;
            case 20345: triggerSpellId = 20342; break;
            case 20346: triggerSpellId = 20343; break;
            case 20186: triggerSpellId = 20268; break;
            case 20354: triggerSpellId = 20352; break;
            case 20355: triggerSpellId = 20353; break;
        }

        if (!victim || !triggerSpellId)
            return SPELL_AURA_PROC_FAILED;

        victim->CastSpell(victim, triggerSpellId, true, nullptr, aura, victim->GetObjectGuid());
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_judgement_of_light_wisdom_proc : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx == EFFECT_INDEX_0 &&
                spell->m_spellInfo->IsFitToFamilyMask<CF_PALADIN_JUDGEMENT_OF_WISDOM_LIGHT>() &&
                spell->m_spellInfo->SpellIconID == 299 &&
                spell->m_casterUnit && spell->m_casterUnit->HasAura(28775))
            spell->m_currentBasePoints[effIdx] = 20;

        return true;
    }

    bool OnEffectHealCalculate(Spell* spell, SpellEffectIndex effIdx, int32& heal) const override
    {
        if (effIdx == EFFECT_INDEX_0 && spell->m_triggeredByAuraBasePoints > 0)
            heal += spell->m_triggeredByAuraBasePoints;

        return true;
    }
};

struct spell_paladin_reckoning : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

#if SUPPORTED_CLIENT_BUILD <= CLIENT_BUILD_1_2_4
        target->ResetAttackTimer();
#endif

#if SUPPORTED_CLIENT_BUILD > CLIENT_BUILD_1_4_2
        if (target->GetExtraAttacks() < 4)
#endif
            target->AddExtraAttack();

        return false;
    }
};

struct spell_paladin_flash_of_light : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target || !target->IsAlive())
            return false;

        int32 heal = spell->damage;
        if (spell->m_casterUnit)
        {
            if (spell->m_casterUnit->HasAura(28853))
                heal += 53;
            if (spell->m_casterUnit->HasAura(28851))
                heal += 41;
        }

        int32 spellId = spell->m_spellInfo->Id;
        spell->m_caster->CastCustomSpell(target, 19993, &heal, &spellId, nullptr, true);
        return false;
    }
};

struct spell_paladin_seal_of_fury_proc : public SpellScript
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

struct spell_paladin_illumination : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!procSpell || !owner->ToPlayer())
            return SPELL_AURA_PROC_FAILED;

        SpellEntry const* originalSpell = procSpell;
        if (procSpell->IsFitToFamilyMask<CF_PALADIN_HOLY_SHOCK>())
        {
            uint32 originalSpellId = 0;
            switch (procSpell->Id)
            {
                case 25914: originalSpellId = 20473; break;
                case 25913: originalSpellId = 20929; break;
                case 25903: originalSpellId = 20930; break;
                default: return SPELL_AURA_PROC_FAILED;
            }
            originalSpell = sSpellMgr.GetSpellEntry(originalSpellId);
        }

        if (!originalSpell)
            return SPELL_AURA_PROC_FAILED;

        int32 mana = originalSpell->manaCost * aura->GetModifier()->m_amount / 100;
        owner->CastCustomSpell(owner, 20272, &mana, nullptr, nullptr, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_paladin_improved_devotion_aura : public AuraScript
{
    void OnAuraInit(Aura* aura) override
    {
        aura->SetPeriodicTimer(1 * IN_MILLISECONDS);
    }

    void OnAfterApply(Aura* aura, bool apply) override
    {
        if (!apply)
            aura->GetTarget()->RemoveAurasDueToSpell(45073);
    }

    void OnPeriodicDummy(Aura* aura) override
    {
        Unit* target = aura->GetTarget();
        if (HasDevotionAura(target))
        {
            if (!target->HasAura(45073))
                target->CastSpell(target, 45073, true, nullptr, aura);
        }
        else if (target->HasAura(45073))
            target->RemoveAurasDueToSpell(45073);
    }

private:
    static bool HasDevotionAura(Unit const* target)
    {
        return target->HasAura(465) ||
            target->HasAura(10290) ||
            target->HasAura(643) ||
            target->HasAura(10291) ||
            target->HasAura(1032) ||
            target->HasAura(10292) ||
            target->HasAura(10293);
    }
};

struct spell_paladin_shield_specialization : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        int32 const mana = int32(owner->GetMaxPower(POWER_MANA) * 0.02f);
        if (!mana)
            return SPELL_AURA_PROC_FAILED;

        owner->EnergizeBySpell(owner, aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()], mana, POWER_MANA);
        return SPELL_AURA_PROC_OK;
    }
};
}

void AddSC_paladin_spell_scripts()
{
    RegisterSpellScript("spell_paladin_invulnerability_forbearance", &GetSpellScript<spell_paladin_invulnerability_forbearance>);
    RegisterSpellScript("spell_paladin_hammer_of_wrath", &GetSpellScript<spell_paladin_hammer_of_wrath>);
    RegisterSpellScript("spell_paladin_judgement_of_command", &GetSpellScript<spell_paladin_judgement_of_command>);
    RegisterSpellScript("spell_paladin_judgement_of_command_dummy", &GetSpellScript<spell_paladin_judgement_of_command_dummy>);
    RegisterSpellScript("spell_paladin_judgement_of_the_crusader", &GetSpellScript<spell_paladin_judgement_of_the_crusader>);
    RegisterSpellScript("spell_paladin_holy_shock", &GetSpellScript<spell_paladin_holy_shock>);
    RegisterSpellScript("spell_paladin_holy_strike", &GetSpellScript<spell_paladin_holy_strike>);
    RegisterSpellScript("spell_paladin_judgement", &GetSpellScript<spell_paladin_judgement>);
    RegisterAuraScript("spell_paladin_conviction_seals", &GetAuraScript<spell_paladin_conviction_seals>);
    RegisterAuraScript("spell_paladin_sanctified_command", &GetAuraScript<spell_paladin_sanctified_command>);
    RegisterAuraScript("spell_paladin_eye_for_an_eye", &GetAuraScript<spell_paladin_eye_for_an_eye>);
    RegisterAuraScript("spell_paladin_improved_lay_on_hands", &GetAuraScript<spell_paladin_improved_lay_on_hands>);
    RegisterAuraScript("spell_paladin_seal_of_righteousness", &GetAuraScript<spell_paladin_seal_of_righteousness>);
    RegisterAuraScript("spell_paladin_blessed_strikes", &GetAuraScript<spell_paladin_blessed_strikes>);
    RegisterAuraScript("spell_paladin_righteous_defense", &GetAuraScript<spell_paladin_righteous_defense>);
    RegisterSpellAndAuraScript("spell_paladin_judgement_of_light_wisdom", &GetSpellScript<spell_paladin_judgement_of_light_wisdom_proc>, &GetAuraScript<spell_paladin_judgement_of_light_wisdom>);
    RegisterSpellScript("spell_paladin_flash_of_light", &GetSpellScript<spell_paladin_flash_of_light>);
    RegisterSpellScript("spell_paladin_seal_of_fury_proc", &GetSpellScript<spell_paladin_seal_of_fury_proc>);
    RegisterAuraScript("spell_paladin_illumination", &GetAuraScript<spell_paladin_illumination>);
    RegisterSpellScript("spell_paladin_reckoning", &GetSpellScript<spell_paladin_reckoning>);
    RegisterAuraScript("spell_paladin_improved_devotion_aura", &GetAuraScript<spell_paladin_improved_devotion_aura>);
    RegisterAuraScript("spell_paladin_shield_specialization", &GetAuraScript<spell_paladin_shield_specialization>);
}
