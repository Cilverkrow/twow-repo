"""Rules that use the client facts (rules/client.toml with rules/client-facts.toml): display ids and map tiles."""

import unittest

from synth import BINDING, MACROS, RULES, insert, world

from dbcheck import engine
from dbcheck.runner import SqliteRunner


def run(con):
    return engine.run(SqliteRunner.from_connection(con), BINDING, RULES, MACROS, [])


def rows(result, rule):
    return [r for res in result.results if res.rule.name == rule for r in res.rows]


class ClientRules(unittest.TestCase):
    def test_gameobject_display_unknown_to_client(self):
        con = world()
        insert(con, "gameobject_template", entry=9001, name="Known Model", displayId=1)
        insert(con, "gameobject_template", entry=9002, name="Unknown Model", displayId=9999999)
        insert(con, "gameobject_template", entry=9003, name="No Model", displayId=0)
        insert(con, "gameobject_template", entry=9004, name="Unknown but never spawned", displayId=9999998)
        for guid, entry in ((1, 9001), (2, 9002), (3, 9002), (4, 9003)):
            insert(con, "gameobject", guid=guid, id=entry, map=0, position_x=0, position_y=0)
        got = [(str(r[0]), str(r[2]), str(r[3])) for r in rows(run(con), "gameobject_spawn_display_unknown_to_client")]
        self.assertEqual(got, [("9002", "9999999", "2")])

    def test_creature_spawn_on_tile_without_client_terrain(self):
        con = world()
        # Goldshire (-9460, 60) is tile 31/49; x = 100000 is far outside the 64 x 64 grid (tile id uses *1000 so it cannot wrap into another column).
        insert(con, "creature", guid=901, id=200, map=0, position_x=-9460.0, position_y=60.0)
        insert(con, "creature", guid=902, id=200, map=0, position_x=100000.0, position_y=0.0)
        insert(con, "creature", guid=903, id=200, map=0, position_x=100000.0, position_y=0.0)
        got = [(str(r[0]), str(r[2])) for r in rows(run(con), "creature_spawn_on_tile_without_client_terrain")]
        self.assertEqual(got, [("0", "2")])

    def test_gameobject_spawn_on_tile_without_client_terrain(self):
        con = world()
        insert(con, "gameobject", guid=901, id=1, map=0, position_x=-9460.0, position_y=60.0)
        insert(con, "gameobject", guid=902, id=1, map=1, position_x=100000.0, position_y=0.0)
        got = [(str(r[0]), str(r[2])) for r in rows(run(con), "gameobject_spawn_on_tile_without_client_terrain")]
        self.assertEqual(got, [("1", "1")])

    def test_missing_position_is_not_a_finding(self):
        con = world()
        insert(con, "creature", guid=904, id=200, map=0)
        self.assertEqual(rows(run(con), "creature_spawn_on_tile_without_client_terrain"), [])


if __name__ == "__main__":
    unittest.main()
