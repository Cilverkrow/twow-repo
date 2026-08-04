# Verschobene Kreaturen-GUIDs aus Penqles Migrationen

Penqle vergibt in seinen Migrationen wiederholt denselben GUID-Block. Wo bei
uns schon anderer Inhalt darauf sitzt, wandern die neuen Spawns nach oben,
statt die vorhandenen zu ueberschreiben. Die Migrationsdatei im Baum bleibt
dabei unveraendert - sonst kracht jeder kuenftige Merge an derselben Stelle.

| Migration | Original | Bei uns | Inhalt |
|---|---|---|---|
| 20260802123824_world | 2590700-2590713 | 2910000-2910013 | Turm von Azora: Antonas Riftgaze und 13 Lesser Arcane Elementals |

Der Block 2590700-2590713 war seit 20260530203924 von Stonehide Boars und
einem Grimscale Thrasher in der Sengenden Schlucht belegt. Beide Gruppen
existieren jetzt nebeneinander.

Vor dem naechsten Merge pruefen: `SELECT MAX(guid) FROM creature;`
