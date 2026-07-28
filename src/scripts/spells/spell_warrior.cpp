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

struct spell_warrior_bloodthirst : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        if (!spell->m_casterUnit)
            return;

        float attackPower = spell->m_casterUnit->GetTotalAttackPowerValue(BASE_ATTACK);
        if (Unit* target = spell->GetUnitTarget())
            attackPower += spell->m_casterUnit->GetTotalAuraModifierByMiscMask(SPELL_AURA_MOD_MELEE_ATTACK_POWER_VERSUS, target->GetCreatureTypeMask());

        damage = uint32(damage * attackPower / 100);
    }
};

struct spell_warrior_shield_slam : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        if (spell->m_casterUnit)
            damage += int32(spell->m_casterUnit->GetShieldBlockValue());
    }
};

struct spell_warrior_execute_trigger : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& /*damage*/) const override
    {
        if (spell->m_casterUnit)
            spell->m_casterUnit->SetPower(POWER_RAGE, 0);
    }
};

struct spell_warrior_execute : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target || !spell->m_casterUnit)
            return false;

        int32 basePoints0 = spell->damage + int32(spell->m_casterUnit->GetPower(POWER_RAGE) * spell->m_spellInfo->DmgMultiplier[effIdx]);
        spell->m_casterUnit->CastCustomSpell(target, 20647, &basePoints0, nullptr, nullptr, true, nullptr);
        return false;
    }
};

struct spell_warrior_warriors_wrath : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        if (Unit* target = spell->GetUnitTarget())
            spell->m_caster->CastSpell(target, 21887, true);

        return false;
    }
};

struct spell_warrior_deep_wounds : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex /*effIdx*/) const override
    {
        Unit* target = spell->GetUnitTarget();
        if (!target || !spell->m_casterUnit)
            return false;

        float damage;
        if (spell->m_casterUnit->HaveOffhandWeapon() && spell->m_casterUnit->GetAttackTimer(BASE_ATTACK) > spell->m_casterUnit->GetAttackTimer(OFF_ATTACK))
            damage = (spell->m_casterUnit->GetFloatValue(UNIT_FIELD_MINOFFHANDDAMAGE) + spell->m_casterUnit->GetFloatValue(UNIT_FIELD_MAXOFFHANDDAMAGE)) / 2;
        else
            damage = (spell->m_casterUnit->GetFloatValue(UNIT_FIELD_MINDAMAGE) + spell->m_casterUnit->GetFloatValue(UNIT_FIELD_MAXDAMAGE)) / 2;

        switch (spell->m_spellInfo->Id)
        {
            case 12162: damage *= 0.2f; break;
            case 12850: damage *= 0.4f; break;
            case 12868: damage *= 0.6f; break;
        }

        int32 deepWoundsDotBasePoints0 = int32(damage / 4);
        spell->m_casterUnit->CastCustomSpell(target, 12721, &deepWoundsDotBasePoints0, nullptr, nullptr, true, nullptr);
        return false;
    }
};

struct spell_warrior_last_stand : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex /*effIdx*/) const override
    {
        if (spell->m_casterUnit)
        {
            int32 healthModSpellBasePoints0 = int32(spell->m_casterUnit->GetMaxHealth() * 0.3f);
            spell->m_casterUnit->CastCustomSpell(spell->m_casterUnit, 12976, &healthModSpellBasePoints0, nullptr, nullptr, true, nullptr);
        }

        return false;
    }
};

struct spell_warrior_bloodrage : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx == EFFECT_INDEX_0)
            if (Unit* target = spell->GetUnitTarget())
                target->SetInCombatState();

        return true;
    }
};

struct spell_warrior_intimidating_shout : public SpellScript
{
    bool OnCheckTarget(Spell const* spell, Unit* target, SpellEffectIndex /*eff*/) const override
    {
        return target != spell->m_targets.getUnitTarget();
    }
};

struct spell_warrior_sweeping_strikes : public AuraScript
{
    void OnHolderInit(SpellAuraHolder* holder, WorldObject* /*caster*/) override
    {
        holder->SetRemovedOnShapeLost(false);
    }

    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        Unit* target = owner->SelectRandomUnfriendlyTarget(nullptr, 5.0f, false, true);
        if (!target)
            return SPELL_AURA_PROC_FAILED;

        owner->CastSpell(target, 26654, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_warrior_retaliation : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim || !owner->HasInArc(victim) || owner->HasUnitState(UNIT_STAT_CAN_NOT_REACT))
            return SPELL_AURA_PROC_FAILED;

        owner->CastSpell(victim, 22858, true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_adrift_strikes : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 damage, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim || !victim->IsAlive())
            return SPELL_AURA_PROC_FAILED;

        if (procSpell && (procSpell->Id == 26654 || procSpell->Id == 12723))
            return SPELL_AURA_PROC_FAILED;

        if (procSpell && !procSpell->IsDirectDamageSpell())
            return SPELL_AURA_PROC_FAILED;

        if (!damage)
            return SPELL_AURA_PROC_FAILED;

        float radius = ATTACK_DISTANCE;
        if (procSpell && procSpell->Id == 1680)
            radius = 8.0f;

        Unit* target = owner->SelectRandomUnfriendlyTarget(victim, radius, false, true, true);
        if (!target)
            return SPELL_AURA_PROC_OK;

        int32 basepoints = 0;
        uint32 triggerSpellId = 12723;
        if (procSpell && procSpell->Id == 20647)
        {
            if (victim->GetHealthPercent() <= 20.0f && target->GetHealthPercent() <= 20.0f)
            {
                int32 const initialDamage = damage * 100 / owner->CalcArmorReducedDamage(victim, 100);
                basepoints = initialDamage * owner->CalcArmorReducedDamage(target, 100) / 100;
            }
            else if (victim->GetHealthPercent() <= 20.0f)
                triggerSpellId = 26654;
            else
            {
                int32 const initialDamage = damage * 100 / owner->CalcArmorReducedDamage(victim, 100);
                basepoints = initialDamage * owner->CalcArmorReducedDamage(target, 100) / 100;
            }
        }
        else
        {
            int32 const initialDamage = damage * 100 / owner->CalcArmorReducedDamage(victim, 100);
            basepoints = initialDamage * owner->CalcArmorReducedDamage(target, 100) / 100;
        }

        if (basepoints)
            owner->CastCustomSpell(target, triggerSpellId, &basepoints, nullptr, nullptr, true, nullptr, aura);
        else
            owner->CastSpell(target, triggerSpellId, true, nullptr, aura);

        return SPELL_AURA_PROC_OK;
    }
};
}

void AddSC_warrior_spell_scripts()
{
    RegisterSpellScript("spell_warrior_bloodthirst", &GetSpellScript<spell_warrior_bloodthirst>);
    RegisterSpellScript("spell_warrior_shield_slam", &GetSpellScript<spell_warrior_shield_slam>);
    RegisterSpellScript("spell_warrior_execute_trigger", &GetSpellScript<spell_warrior_execute_trigger>);
    RegisterSpellScript("spell_warrior_execute", &GetSpellScript<spell_warrior_execute>);
    RegisterSpellScript("spell_warrior_warriors_wrath", &GetSpellScript<spell_warrior_warriors_wrath>);
    RegisterSpellScript("spell_warrior_deep_wounds", &GetSpellScript<spell_warrior_deep_wounds>);
    RegisterSpellScript("spell_warrior_last_stand", &GetSpellScript<spell_warrior_last_stand>);
    RegisterSpellScript("spell_warrior_bloodrage", &GetSpellScript<spell_warrior_bloodrage>);
    RegisterSpellScript("spell_warrior_intimidating_shout", &GetSpellScript<spell_warrior_intimidating_shout>);
    RegisterAuraScript("spell_warrior_sweeping_strikes", &GetAuraScript<spell_warrior_sweeping_strikes>);
    RegisterAuraScript("spell_warrior_retaliation", &GetAuraScript<spell_warrior_retaliation>);
    RegisterAuraScript("spell_adrift_strikes", &GetAuraScript<spell_adrift_strikes>);
}
