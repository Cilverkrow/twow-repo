#include "scriptPCH.h"
#include "ThreatManager.h"

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

struct spell_rogue_eviscerate : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        Player* player = spell->m_caster->ToPlayer();
        if (player)
            if (uint32 combo = player->GetComboPoints())
                damage += int32(player->GetTotalAttackPowerValue(BASE_ATTACK) * combo * 0.03f);
    }
};

struct spell_rogue_surprise_attack : public SpellScript
{
    SpellCastResult OnCheckCast(Spell* spell, bool /*strict*/) const override
    {
        if (!spell->m_casterUnit || spell->m_targets.getUnitTargetGuid() == spell->m_casterUnit->GetReactiveTarget(REACTIVE_ROGUE_DODGE))
            return SPELL_CAST_OK;

        return SPELL_FAILED_BAD_TARGETS;
    }

    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return;

        damage += int32(player->GetTotalAttackPowerValue(BASE_ATTACK) * 0.25f);
        player->ModifyAuraState(AURA_STATE_TARGET_DODGED, false);
    }
};

struct spell_rogue_preparation : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex /*effIdx*/) const override
    {
        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return false;

        SpellCooldowns cooldowns = player->GetSpellCooldownMap();
        for (const auto& cooldown : cooldowns)
        {
            SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(cooldown.first);
            if (spellInfo && spellInfo->SpellFamilyName == SPELLFAMILY_ROGUE &&
                    spellInfo->Id != spell->m_spellInfo->Id && spellInfo->GetRecoveryTime() > 0)
                player->RemoveSpellCooldown(cooldown.first, true);
        }

        return false;
    }
};

struct spell_rogue_deadly_throw_poison : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Player* player = spell->m_caster->ToPlayer();
        Unit* target = spell->GetUnitTarget();
        if (!player || !target || target == player)
            return false;

        Item* offhand = player->GetWeaponForAttack(OFF_ATTACK, true, true);
        if (!offhand)
            return false;

        uint32 enchantId = offhand->GetEnchantmentId(TEMP_ENCHANTMENT_SLOT);
        SpellItemEnchantmentEntry const* enchant = sSpellItemEnchantmentStore.LookupEntry(enchantId);
        if (!enchant)
            return false;

        for (int s = 0; s < 3; ++s)
        {
            if (enchant->type[s] != ITEM_ENCHANTMENT_TYPE_COMBAT_SPELL)
                continue;

            uint32 procSpellId = enchant->spellid[s];
            SpellEntry const* spellInfo = sSpellMgr.GetSpellEntry(procSpellId);
            if (!spellInfo)
                continue;

            bool const isRoguePoison = spellInfo->IsFitToFamily<SPELLFAMILY_ROGUE,
                CF_ROGUE_INSTANT_POISON, CF_ROGUE_CRIPPLING_POISON, CF_ROGUE_MIND_NUMBING_POISON,
                CF_ROGUE_DEADLY_POISON, CF_ROGUE_WOUND_POISON>();
            if (!isRoguePoison)
                continue;

            if (spellInfo->IsPositiveSpell())
                player->CastSpell(player, procSpellId, true, offhand);
            else
                player->CastSpell(target, procSpellId, true, offhand);

            uint32 charges = offhand->GetEnchantmentCharges(TEMP_ENCHANTMENT_SLOT);
            if (charges > 1)
                offhand->SetEnchantmentCharges(TEMP_ENCHANTMENT_SLOT, charges - 1);
            else if (charges == 1)
            {
                player->ApplyEnchantment(offhand, TEMP_ENCHANTMENT_SLOT, false);
                offhand->ClearEnchantment(TEMP_ENCHANTMENT_SLOT);
            }
            break;
        }

        return false;
    }
};

struct spell_rogue_vanish : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (spell->m_spellInfo->Effect[effIdx] == SPELL_EFFECT_SANCTUARY)
        {
            Unit* target = spell->GetUnitTarget();
            if (!target)
                return false;

            bool noGuards = true;

            target->InterruptSpellsCastedOnMe(true);
            target->InterruptAttacksOnMe(0.0f, true);
            target->m_lastSanctuaryTime = WorldTimer::getMSTime();
            target->CombatStop();

            HostileReference* reference = target->GetHostileRefManager().getFirst();
            while (reference)
            {
                HostileReference* nextReference = reference->next();
                if (!reference->getSource()->getOwner()->IsContestedGuard())
                {
                    reference->removeReference();
                    delete reference;
                }
                else
                    noGuards = false;

                reference = nextReference;
            }

            if (noGuards && target->IsPlayer())
                static_cast<Player*>(target)->SetCannotBeDetectedTimer(1000);

            spell->AddExecuteLogTarget(effIdx, target->GetObjectGuid());
            return false;
        }

        if (spell->m_spellInfo->Effect[effIdx] != SPELL_EFFECT_TRIGGER_SPELL ||
                spell->m_spellInfo->EffectTriggerSpell[effIdx] != 18461)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        target->RemoveSpellsCausingAura(SPELL_AURA_MOD_ROOT);
        target->RemoveSpellsCausingAura(SPELL_AURA_MOD_DECREASE_SPEED);
        target->RemoveSpellsCausingAura(SPELL_AURA_MOD_STALKED);

        if (Player* player = target->ToPlayer())
            player->CastHighestStealthRank();

        return false;
    }
};

struct spell_rogue_honor_among_thieves : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* /*owner*/, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 cooldown) override
    {
        if (!victim || !victim->IsAlive())
            return SPELL_AURA_PROC_FAILED;

        Unit* auraCaster = aura->GetCaster();
        if (!auraCaster || !auraCaster->IsAlive())
            return SPELL_AURA_PROC_FAILED;

        if (cooldown && auraCaster->HasSpellCooldown(52513))
            return SPELL_AURA_PROC_FAILED;

        int32 comboPoints = aura->GetModifier()->m_amount;
        auraCaster->CastCustomSpell(auraCaster, 52513, &comboPoints, nullptr, nullptr, true, nullptr, aura);

        if (cooldown)
            auraCaster->AddSpellCooldown(52513, 0, time(nullptr) + cooldown);

        return SPELL_AURA_PROC_OK;
    }
};

struct spell_rogue_clean_escape : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim || !victim->IsAlive() || !procSpell || procSpell->Effect[EFFECT_INDEX_0] == SPELL_EFFECT_NONE)
            return SPELL_AURA_PROC_FAILED;

        owner->CastSpell(victim, 23583, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_rogue_blade_flurry : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 damage, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim || !victim->IsAlive() || (procSpell && procSpell->Id == 22482))
            return SPELL_AURA_PROC_FAILED;

        Unit* target = owner->SelectRandomUnfriendlyTarget(victim, 5.0f, false, true);
        if (!target)
            return SPELL_AURA_PROC_FAILED;

        int32 basepoints = damage * 100 / owner->CalcArmorReducedDamage(victim, 100);
        owner->CastCustomSpell(target, 22482, &basepoints, nullptr, nullptr, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_rogue_improved_ambush : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        int32 energy = aura->GetModifier()->m_amount;
        owner->CastCustomSpell(owner, aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()], &energy, nullptr, nullptr, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_rogue_improved_sap_vanish : public SpellScript
{
    void OnEffectExecuted(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (spell->m_spellInfo->Effect[effIdx] != SPELL_EFFECT_SANCTUARY)
            return;

        if (Player* player = ToPlayer(spell->GetUnitTarget()))
            player->CastHighestStealthRank();
    }
};
}

void AddSC_rogue_spell_scripts()
{
    RegisterSpellScript("spell_rogue_eviscerate", &GetSpellScript<spell_rogue_eviscerate>);
    RegisterSpellScript("spell_rogue_surprise_attack", &GetSpellScript<spell_rogue_surprise_attack>);
    RegisterSpellScript("spell_rogue_preparation", &GetSpellScript<spell_rogue_preparation>);
    RegisterSpellScript("spell_rogue_deadly_throw_poison", &GetSpellScript<spell_rogue_deadly_throw_poison>);
    RegisterSpellScript("spell_rogue_vanish", &GetSpellScript<spell_rogue_vanish>);
    RegisterAuraScript("spell_rogue_honor_among_thieves", &GetAuraScript<spell_rogue_honor_among_thieves>);
    RegisterAuraScript("spell_rogue_clean_escape", &GetAuraScript<spell_rogue_clean_escape>);
    RegisterAuraScript("spell_rogue_blade_flurry", &GetAuraScript<spell_rogue_blade_flurry>);
    RegisterAuraScript("spell_rogue_improved_ambush", &GetAuraScript<spell_rogue_improved_ambush>);
    RegisterSpellScript("spell_rogue_improved_sap_vanish", &GetSpellScript<spell_rogue_improved_sap_vanish>);
}
