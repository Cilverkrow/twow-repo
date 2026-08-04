-- ==============================================
-- FILE: shield_specialization_unwire_talents.sql
-- GENERATED: 20260805120000
-- ==============================================
-- Shield Specialization wurde zweimal repariert. Unsere Fassung hing als
-- AuraScript an den fuenf Talentraengen (Migration 20260731180000). Penqle
-- loest dasselbe stromaufwaerts mit einem SpellScript am Ausloeser 23602
-- (Migration 20260802171013).
--
-- Beim Merge haben wir seine Fassung uebernommen, weil sie dort gepflegt wird.
-- Damit zeigt der Skriptname aber auf ein SpellScript, und die Talentraenge
-- duerfen ihn nicht mehr tragen - sonst haengt ein SpellScript an einer Aura.
UPDATE `spell_template`
SET `script_name` = ''
WHERE `entry` IN (12298, 12724, 12725, 12726, 12727)
  AND `script_name` = 'spell_warrior_shield_specialization';
