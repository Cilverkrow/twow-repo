#include "scriptPCH.h"

namespace
{
enum DruidSpells
{
    SPELL_DRUID_WOLFSHEAD_HELM_ENERGY = 17770,
    SPELL_DRUID_SWIFTMEND = 18562,
    SPELL_DRUID_FRENZIED_REGENERATION = 22842,
    SPELL_DRUID_FRENZIED_REGENERATION_RANK_2 = 22895,
    SPELL_DRUID_FRENZIED_REGENERATION_RANK_3 = 22896,
    SPELL_DRUID_RESHIFT = 47379,
    SPELL_DRUID_AESSINAS_BLOOM = 52567,
};

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

uint32 CountDruidBleedsOnTarget(Unit* target, Player* caster)
{
    if (!target || !caster)
        return 0;

    static uint32 const bleedSpellIds[] =
    {
        1822, 1823, 1824, 9904,
        1079, 9493, 9752, 9894, 9896,
        9007, 9824, 9826
    };

    uint32 bleedCount = 0;
    ObjectGuid casterGuid = caster->GetObjectGuid();
    for (uint32 bleedId : bleedSpellIds)
    {
        if (target->GetSpellAuraHolder(bleedId, casterGuid))
            ++bleedCount;
    }

    if (!bleedCount)
    {
        Unit::AuraList const& periodic = target->GetAurasByType(SPELL_AURA_PERIODIC_DAMAGE);
        for (Aura const* aura : periodic)
        {
            if (aura->GetCasterGuid() != casterGuid)
                continue;

            SpellEntry const* auraSpell = aura->GetSpellProto();
            if (auraSpell && (auraSpell->IsFitToFamilyMask<CF_DRUID_RAKE_CLAW>() || auraSpell->IsFitToFamilyMask<CF_DRUID_RIP_BITE>()))
                ++bleedCount;
        }
    }

    return bleedCount;
}

int32 GetOpenWoundsBonus(Player* caster, bool forClaw)
{
    static uint32 const openWoundsRanks[] = {51402, 51403, 51404};
    int32 bonus = 0;
    for (uint32 openWoundsId : openWoundsRanks)
    {
        if (!caster->HasSpell(openWoundsId) && !caster->HasAura(openWoundsId))
            continue;

        if (SpellEntry const* openWoundsInfo = sSpellMgr.GetSpellEntry(openWoundsId))
            bonus = std::max(bonus, openWoundsInfo->EffectBasePoints[forClaw ? EFFECT_INDEX_0 : EFFECT_INDEX_1] + 1);
    }

    return bonus;
}

SpellEntry const* GetCurrentShapeshiftSpell(Unit* caster)
{
    if (!caster)
        return nullptr;

    ShapeshiftForm const form = caster->GetShapeshiftForm();
    if (form == FORM_NONE)
        return nullptr;

    Unit::AuraList const& shapeshiftAuras = caster->GetAurasByType(SPELL_AURA_MOD_SHAPESHIFT);
    for (Aura const* aura : shapeshiftAuras)
        if (aura->GetModifier()->m_miscvalue == form)
            return sSpellMgr.GetSpellEntry(aura->GetId());

    return nullptr;
}

struct spell_druid_reshift : public SpellScript
{
    SpellCastResult OnCheckCast(Spell* spell, bool /*strict*/) const override
    {
        if (!spell->m_casterUnit || spell->m_casterUnit->GetShapeshiftForm() == FORM_NONE)
            return SPELL_FAILED_ONLY_SHAPESHIFT;

        return SPELL_CAST_OK;
    }

    std::optional<uint32> OnCalculatePowerCost(SpellEntry const* /*spellInfo*/, Unit* caster, Spell* spell, Item* /*castItem*/) const override
    {
        if (SpellEntry const* shapeshiftSpellInfo = GetCurrentShapeshiftSpell(caster))
            return Spell::CalculatePowerCost(shapeshiftSpellInfo, caster, spell);

        return 0;
    }

    bool OnTakePower(Spell* spell) const override
    {
        if (spell->IsTriggered() && spell->m_triggeredBySpellInfo && spell->m_triggeredBySpellInfo->Id == SPELL_DRUID_RESHIFT &&
                spell->m_spellInfo->HasAura(SPELL_AURA_MOD_SHAPESHIFT))
            return false;

        return true;
    }

    bool OnEffectExecute(Spell* spell, SpellEffectIndex /*effIdx*/) const override
    {
        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return false;

        SpellEntry const* shapeshiftSpellInfo = GetCurrentShapeshiftSpell(player);
        if (!shapeshiftSpellInfo)
            return false;

        player->RemoveSpellsCausingAura(SPELL_AURA_MOD_SHAPESHIFT, AURA_REMOVE_BY_CANCEL);
        player->CastSpell(player, shapeshiftSpellInfo, true, nullptr, nullptr, ObjectGuid(), spell->m_spellInfo);
        return false;
    }
};

struct spell_druid_swiftmend : public SpellScript
{
    SpellCastResult OnCheckCast(Spell* spell, bool /*strict*/) const override
    {
        Unit* target = spell->m_targets.getUnitTarget();
        return target && target->GetAura(SPELL_AURA_PERIODIC_HEAL, SPELLFAMILY_DRUID, UI64LIT(0x50)) ? SPELL_CAST_OK : SPELL_FAILED_TARGET_AURASTATE;
    }

    bool OnEffectHealCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, int32& heal) const override
    {
        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        Unit::AuraList const& periodicHeals = target->GetAurasByType(SPELL_AURA_PERIODIC_HEAL);
        Aura* targetAura = nullptr;
        for (Aura* aura : periodicHeals)
        {
            if (aura->GetSpellProto()->IsFitToFamily<SPELLFAMILY_DRUID, CF_DRUID_REJUVENATION, CF_DRUID_REGROWTH>())
                if (!targetAura || aura->GetAuraDuration() < targetAura->GetAuraDuration())
                    targetAura = aura;
        }

        if (!targetAura)
        {
            sLog.outError("Target (GUID: %u TypeId: %u) has aurastate AURA_STATE_SWIFTMEND but no matching aura.", target->GetGUIDLow(), target->GetTypeId());
            return false;
        }

        int32 tickheal = targetAura->GetModifier()->m_amount;
        int32 tickcount = 0;
        if (targetAura->GetSpellProto()->IsFitToFamilyMask<CF_DRUID_REGROWTH>())
            tickcount = 6;
        if (targetAura->GetSpellProto()->IsFitToFamilyMask<CF_DRUID_REJUVENATION>())
            tickcount = 4;

        target->RemoveAurasDueToSpell(targetAura->GetId());
        heal += tickheal * tickcount;
        return true;
    }
};

struct spell_druid_aessinas_bloom : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        Unit* target = spell->GetUnitTarget();
        if (!target || !spell->m_casterUnit)
            return;

        Unit::AuraList const& periodicHeals = target->GetAurasByType(SPELL_AURA_PERIODIC_HEAL);
        for (Aura* aura : periodicHeals)
        {
            if (aura->GetCasterGuid() == spell->m_casterUnit->GetObjectGuid() &&
                    aura->GetSpellProto()->IsFitToFamily<SPELLFAMILY_DRUID, CF_DRUID_REGROWTH>())
            {
                int32 tickAmount = aura->GetSpellProto()->CalculateSimpleValue(EFFECT_INDEX_1);
                if (tickAmount > 0)
                    spell->m_casterUnit->DealHeal(target, uint32(tickAmount * 2), spell->m_spellInfo);
                break;
            }
        }

        damage = -1;
    }
};

struct spell_druid_berserk : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Player* player = spell->m_caster->ToPlayer();
        if (!player || !spell->m_casterUnit)
            return false;

        if (player->GetShapeshiftForm() == FORM_CAT)
            player->CastSpell(player, 45710, true);

        if (player->GetShapeshiftForm() == FORM_BEAR || player->GetShapeshiftForm() == FORM_DIREBEAR)
        {
            int32 healthModSpellBasePoints0 = int32(spell->m_casterUnit->GetMaxHealth() * 0.2f);
            spell->m_casterUnit->CastCustomSpell(spell->m_casterUnit, 45709, &healthModSpellBasePoints0, nullptr, nullptr, true, nullptr);
        }

        return false;
    }
};

struct spell_druid_berserk_form_swap : public AuraScript
{
    void OnAfterShapeshift(Aura* aura, ShapeshiftForm /*oldForm*/, ShapeshiftForm newForm) override
    {
        Unit* target = aura->GetTarget();
        if (!target)
            return;

        switch (aura->GetId())
        {
            case 45709:
            {
                if (newForm != FORM_CAT)
                    return;

                int32 const duration = aura->GetAuraDuration();
                target->m_Events.AddLambdaEventAtOffset([target, duration]()
                {
                    if (SpellAuraHolder* newBerserk = target->AddAura(45710, ADD_AURA_POSITIVE))
                    {
                        newBerserk->SetAuraDuration(duration);
                        newBerserk->UpdateAuraDuration();
                    }
                }, 1);
                target->RemoveAurasDueToSpellByCancel(45709);
                break;
            }
            case 45710:
            {
                if (newForm != FORM_BEAR && newForm != FORM_DIREBEAR)
                    return;

                int32 const duration = aura->GetAuraDuration();
                target->m_Events.AddLambdaEventAtOffset([target, duration]()
                {
                    int32 healthModSpellBasePoints0 = int32(target->GetMaxHealth() * 0.2f);
                    if (SpellAuraHolder* newBerserk = target->AddAura(45709, ADD_AURA_POSITIVE, nullptr, &healthModSpellBasePoints0))
                    {
                        newBerserk->SetAuraDuration(duration);
                        newBerserk->UpdateAuraDuration();
                    }
                }, 1);
                target->RemoveAurasDueToSpellByCancel(45710);
                break;
            }
            default:
                break;
        }
    }
};

struct spell_druid_tree_of_life_aura : public AuraScript
{
    int32 OnAuraValueCalculate(Aura* aura, Unit* caster, Unit* /*target*/, SpellEntry const* /*spellProto*/, SpellEffectIndex /*effIdx*/, Item* /*castItem*/, int32 value) override
    {
        if (!caster || !aura->GetHolder()->IsAddedBySpell())
            return value;

        return caster->GetStat(STAT_SPIRIT) * (float(value) / 100.0f);
    }
};

struct spell_druid_enrage : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_1)
            return true;

        Unit* target = spell->GetUnitTarget();
        if (!target)
            return false;

        int32 reductionMod = target->HasAura(9634) ? -16 : -27;
        target->CastCustomSpell(target, 25503, nullptr, &reductionMod, nullptr, true);
        return false;
    }
};

struct spell_druid_shapeshift_root_snare_removal : public SpellScript
{
    bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx) const override
    {
        if (effIdx != EFFECT_INDEX_0)
            return true;

        Unit* target = spell->GetUnitTarget() ? spell->GetUnitTarget() : spell->m_casterUnit;
        if (!target)
            return false;

        target->RemoveNegativeSpellsCausingAura(SPELL_AURA_MOD_ROOT);
        Unit::AuraList const& slowingAuras = target->GetAurasByType(SPELL_AURA_MOD_DECREASE_SPEED);
        for (auto iter = slowingAuras.begin(); iter != slowingAuras.end();)
        {
            SpellEntry const* auraSpellInfo = (*iter)->GetSpellProto();
            if ((*iter)->IsPositive() || auraSpellInfo->HasAttribute(SPELL_ATTR_NEGATIVE))
            {
                ++iter;
                continue;
            }

            uint32 auraMechanicMask = auraSpellInfo->GetAllSpellMechanicMask();
            if ((auraMechanicMask & MECHANIC_NOT_REMOVED_BY_SHAPESHIFT) ||
                    (auraSpellInfo->SpellIconID == 15 && auraSpellInfo->Dispel == 0 &&
                    (auraMechanicMask & (1 << (MECHANIC_SNARE - 1))) == 0))
            {
                ++iter;
                continue;
            }

            target->RemoveAurasDueToSpellByCancel(auraSpellInfo->Id);
            iter = slowingAuras.begin();
        }

        return false;
    }
};

struct spell_druid_open_wounds : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex /*effIdx*/, float& damage) const override
    {
        if (spell->m_spellInfo->SpellVisual != 3882)
            return;

        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return;

        if (uint32 bleeds = CountDruidBleedsOnTarget(spell->GetUnitTarget(), player))
        {
            int32 bonusPerBleed = GetOpenWoundsBonus(player, true);
            if (bonusPerBleed > 0)
                damage = int32(float(damage) * (100.0f + bonusPerBleed * bleeds) / 100.0f);
        }
    }
};

struct spell_druid_ferocious_bite : public SpellScript
{
    void OnEffectDamageCalculate(Spell* spell, SpellEffectIndex effIdx, float& damage) const override
    {
        if (spell->m_spellInfo->SpellVisual != 6587)
            return;

        Player* player = spell->m_caster->ToPlayer();
        if (!player)
            return;

        if (uint32 combo = player->GetComboPoints())
            damage += int32(player->GetTotalAttackPowerValue(BASE_ATTACK) * combo * 0.03f);

        damage += int32(player->GetPower(POWER_ENERGY) * spell->m_spellInfo->DmgMultiplier[effIdx]);
        player->SetPower(POWER_ENERGY, 0);

        if (spell->m_spellInfo->Id == 22567 || spell->m_spellInfo->Id == 22568 || spell->m_spellInfo->Id == 22827 ||
                spell->m_spellInfo->Id == 22828 || spell->m_spellInfo->Id == 22829)
        {
            static uint32 const feralAggressionRanks[] = {16858, 16859, 16860, 16861, 16862};
            for (uint32 feralAggressionId : feralAggressionRanks)
            {
                if (!player->HasSpell(feralAggressionId))
                    continue;

                if (SpellEntry const* feralAggressionInfo = sSpellMgr.GetSpellEntry(feralAggressionId))
                {
                    int32 damageBonusPct = feralAggressionInfo->EffectBasePoints[EFFECT_INDEX_1] + 1;
                    damage = int32(float(damage) * (100.0f + damageBonusPct) / 100.0f);
                }
                break;
            }
        }

        if (uint32 bleeds = CountDruidBleedsOnTarget(spell->GetUnitTarget(), player))
        {
            int32 bonusPerBleed = GetOpenWoundsBonus(player, false);
            if (bonusPerBleed > 0)
                damage = int32(float(damage) * (100.0f + bonusPerBleed * bleeds) / 100.0f);
        }
    }
};

struct spell_druid_thorns_explosion : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* victim, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* /*procSpell*/, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (!victim)
            return SPELL_AURA_PROC_FAILED;

        if (aura->GetId() == 46431 && !owner->HasAuraType(SPELL_AURA_DAMAGE_SHIELD))
            return SPELL_AURA_PROC_CANT_TRIGGER;

        owner->CastSpell(victim, aura->GetSpellProto()->EffectTriggerSpell[aura->GetEffIndex()], true, nullptr, aura);
        return SPELL_AURA_PROC_OK;
    }
};

struct spell_druid_frenzied_regeneration : public AuraScript
{
    void OnPeriodicTrigger(Aura* aura, Unit* /*caster*/, Unit* target, WorldObject* /*targetObject*/, SpellEntry const*& spellInfo) override
    {
        if (!target)
        {
            spellInfo = nullptr;
            return;
        }

        int32 lifePerRage = aura->GetModifier()->m_amount;
        int32 rage = target->GetPower(POWER_RAGE);
        if (rage > 100)
            rage = 100;

        target->ModifyPower(POWER_RAGE, -rage);
        int32 heal = int32(rage * lifePerRage / 10);
        heal += int32((rage / 10.0f) * (target->GetStat(STAT_STAMINA) / 10.0f));
        target->CastCustomSpell(target, 22845, &heal, nullptr, nullptr, true, nullptr, aura);
        spellInfo = nullptr;
    }
};

struct spell_druid_moonclaw : public AuraScript
{
    void OnAfterApply(Aura* aura, bool apply) override
    {
        Unit* target = aura->GetTarget();
        UpdateAura(target, 24932, apply);
        UpdateAura(target, 24907, apply);
    }

private:
    static void UpdateAura(Unit* target, uint32 spellId, bool apply)
    {
        Aura* aura = target->GetAura(spellId, EFFECT_INDEX_0);
        if (!aura || aura->GetCasterGuid() != target->GetObjectGuid())
            return;

        aura->ApplyModifier(false);
        if (!apply && aura->GetModifier()->m_amount > 3)
            aura->GetModifier()->m_amount -= 1;
        aura->ApplyModifier(true);
    }
};

struct spell_druid_glyph_of_the_moon : public AuraScript
{
    void OnAfterShapeshift(Aura* aura, ShapeshiftForm oldForm, ShapeshiftForm newForm) override
    {
        Player* target = aura->GetTarget()->ToPlayer();
        if (!target)
            return;

        if (newForm == FORM_MOONKIN && !target->HasAura(22650))
            target->AddAura(22650);
        else if (oldForm == FORM_MOONKIN && newForm != FORM_MOONKIN)
            target->RemoveAurasDueToSpell(22650);
    }
};

struct spell_druid_primal_fury : public AuraScript
{
    std::optional<SpellAuraProcResult> OnProc(Unit* owner, Unit* /*victim*/, uint32 /*damage*/, int32 /*originalAmount*/, Aura* aura, SpellEntry const* procSpell, uint32 /*procFlag*/, uint32 /*procEx*/, uint32 /*cooldown*/) override
    {
        if (owner->GetShapeshiftForm() == FORM_CAT)
        {
            if (aura->GetEffIndex() == EFFECT_INDEX_0)
                return SPELL_AURA_PROC_FAILED;

            if (!procSpell || !procSpell->HasEffect(SPELL_EFFECT_ADD_COMBO_POINTS))
                return SPELL_AURA_PROC_FAILED;
        }
        else if (aura->GetEffIndex() == EFFECT_INDEX_1)
            return SPELL_AURA_PROC_FAILED;

        return std::nullopt;
    }
};
}

void AddSC_druid_spell_scripts()
{
    RegisterSpellScript("spell_druid_reshift", &GetSpellScript<spell_druid_reshift>);
    RegisterSpellScript("spell_druid_swiftmend", &GetSpellScript<spell_druid_swiftmend>);
    RegisterSpellScript("spell_druid_aessinas_bloom", &GetSpellScript<spell_druid_aessinas_bloom>);
    RegisterSpellScript("spell_druid_berserk", &GetSpellScript<spell_druid_berserk>);
    RegisterSpellScript("spell_druid_enrage", &GetSpellScript<spell_druid_enrage>);
    RegisterSpellScript("spell_druid_shapeshift_root_snare_removal", &GetSpellScript<spell_druid_shapeshift_root_snare_removal>);
    RegisterSpellScript("spell_druid_open_wounds", &GetSpellScript<spell_druid_open_wounds>);
    RegisterSpellScript("spell_druid_ferocious_bite", &GetSpellScript<spell_druid_ferocious_bite>);
    RegisterAuraScript("spell_druid_thorns_explosion", &GetAuraScript<spell_druid_thorns_explosion>);
    RegisterAuraScript("spell_druid_frenzied_regeneration", &GetAuraScript<spell_druid_frenzied_regeneration>);
    RegisterAuraScript("spell_druid_moonclaw", &GetAuraScript<spell_druid_moonclaw>);
    RegisterAuraScript("spell_druid_berserk_form_swap", &GetAuraScript<spell_druid_berserk_form_swap>);
    RegisterAuraScript("spell_druid_tree_of_life_aura", &GetAuraScript<spell_druid_tree_of_life_aura>);
    RegisterAuraScript("spell_druid_glyph_of_the_moon", &GetAuraScript<spell_druid_glyph_of_the_moon>);
    RegisterAuraScript("spell_druid_primal_fury", &GetAuraScript<spell_druid_primal_fury>);
}
