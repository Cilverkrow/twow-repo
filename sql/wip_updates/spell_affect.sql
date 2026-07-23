-- Issue #314: Envenom (52531) should also affect Wound Poison, matching Improved Poisons.
INSERT INTO `spell_affect` (`entry`, `effectId`, `SpellFamilyMask`) VALUES
(52531, 1, 268558336),
(52531, 2, 268558336);
