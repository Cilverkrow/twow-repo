-- Improved Ambush (14079/14080/14081): SpellFamilyMask0 also matched non-Ambush combo moves; restrict to CF_ROGUE_AMBUSH only.
UPDATE `spell_proc_event` SET `SpellFamilyMask0` = 512 WHERE `entry` IN (14079, 14080, 14081) AND `SpellFamilyMask0` = 8389120;
