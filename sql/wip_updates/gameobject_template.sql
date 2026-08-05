-- Add missing Blazing Forge Kit objects for existing world databases.

INSERT INTO `gameobject_template`
    (`entry`, `type`, `displayId`, `name`, `size`, `data0`, `data1`)
VALUES
    (3000684, 8, 209, 'Blazing Forge Kit: Forge', 0.5, 3, 10),
    (3000685, 8, 273, 'Blazing Forge Kit: Anvil', 0.5, 1, 10)
ON DUPLICATE KEY UPDATE
    `type`      = VALUES(`type`),
    `displayId` = VALUES(`displayId`),
    `name`      = VALUES(`name`),
    `size`      = VALUES(`size`),
    `data0`     = VALUES(`data0`),
    `data1`     = VALUES(`data1`);
