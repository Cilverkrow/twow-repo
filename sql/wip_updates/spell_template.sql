-- Issue #314: bind Shadow of Death (52710) to its new spell script.
UPDATE `spell_template` SET `script_name` = 'spell_rogue_shadow_of_death' WHERE `entry` = 52710;
