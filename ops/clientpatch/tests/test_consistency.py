import tempfile
import unittest
from pathlib import Path

from synth import binding, pack

from clientpatch import consistency
from clientpatch.delta import Touched
from clientpatch.errors import ConsistencyError
from clientpatch.sqlsrc import SqlData, Source, load_sources
from clientpatch.errors import SqlSourceError
from clientpatch.wdbc import Table

RULES = """
[[rule]]
id = "map-in-client"
kind = "keys_in_dbc"
source = "map_template"
dbc = "Map"

[[rule.accept]]
key = "45"
reason = "#408 test accept"

[[rule]]
id = "trigger-map"
kind = "fields_equal"
source = "areatrigger_template"
dbc = "AreaTrigger"

[[rule.pair]]
sql = "map_id"
dbc = "ContinentID"

[[rule.pair]]
sql = "x"
dbc = "Pos[0]"
tolerance = 1.0

[[rule]]
id = "mod"
kind = "fields_equal"
source = "skill_race_class_info_mod"
dbc = "SkillRaceClassInfo"
skip_sql_value = "-1"

[[rule.pair]]
sql = "RaceMask"
dbc = "RaceMask"

[[rule]]
id = "talent-ranks"
kind = "refs_in_sql"
source = "spell_template"
dbc = "Talent"
scope = "changed"
columns = ["SpellRank[0]", "SpellRank[1]"]
"""


class Consistency(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "rules").mkdir()
        (self.tmp / "rules" / "r.toml").write_text(RULES, encoding="utf-8")
        sql = self.tmp / "sql"
        sql.mkdir()
        (sql / "map_template.tsv").write_text("entry\tmap_name\n0\tAzeroth\n45\tCitadel\n532\tKarazhan\n")
        (sql / "areatrigger_template.tsv").write_text(
            "id\tmap_id\tx\n5340\t0\t10.0\n100\t532\t-5.2\n")
        (sql / "skill_race_class_info_mod.tsv").write_text("Id\tRaceMask\n7\t-1\n8\t4\n")
        (sql / "spell_template.tsv").write_text("entry\tname\n90100\tR1\n")
        names = ["map_template", "areatrigger_template", "skill_race_class_info_mod", "spell_template"]
        self.sql = SqlData({n: Source(n, "SELECT 1", {"map_template": "entry",
                                                      "areatrigger_template": "id",
                                                      "skill_race_class_info_mod": "Id",
                                                      "spell_template": "entry"}[n])
                            for n in names}, sql)
        self.tables = {
            "Map": self.table("Map", [{"ID": 0}, {"ID": 532}]),
            "AreaTrigger": self.table("AreaTrigger", [
                {"ID": 5340, "ContinentID": 532, "Pos[0]": 10.0},
                {"ID": 100, "ContinentID": 532, "Pos[0]": -5.0}]),
            "SkillRaceClassInfo": self.table("SkillRaceClassInfo", [
                {"ID": 7, "RaceMask": 1}, {"ID": 8, "RaceMask": 4}]),
            "Talent": self.table("Talent", [{"ID": 1, "SpellRank[0]": 90100, "SpellRank[1]": 90101}]),
        }
        self.rules = consistency.load_rules(self.tmp / "rules")

    def table(self, name, rows):
        b = binding(name)
        return Table.from_bytes(pack(b, rows), b)

    def test_findings(self):
        touched = {"Talent": Touched(cells={((1,), "SpellRank[1]")})}
        found = consistency.run(self.rules, self.tables, self.sql, touched)
        by_rule = {}
        for f in found:
            by_rule.setdefault(f.rule, []).append(f)
        # map 45 is server-only but accepted with a reason
        self.assertEqual([(f.key, bool(f.accepted)) for f in by_rule["map-in-client"]], [("45", True)])
        # trigger 5340: DB map 0 vs client 532 -> blocking; 100 within tolerance
        self.assertEqual([f.key for f in by_rule["trigger-map"]], ["5340"])
        self.assertFalse(by_rule["trigger-map"][0].accepted)
        # -1 means "keep the DBC value" -> no finding for 7; 8 agrees
        self.assertNotIn("mod", by_rule)
        # rank 90101 does not exist on the server
        self.assertEqual([f.message for f in by_rule["talent-ranks"]],
                         ["Talent.SpellRank[1]=90101 has no server spell_template row"])
        self.assertEqual(len(consistency.blocking(found)), 2)

    def test_stale_accept_is_reported_not_blocking(self):
        self.tables["Map"] = self.table("Map", [{"ID": 0}, {"ID": 45}, {"ID": 532}])
        found = consistency.run(self.rules[:1], self.tables, self.sql, {})
        self.assertEqual([(f.key, f.accepted) for f in found], [("45", "stale")])
        self.assertEqual(consistency.blocking(found), [])

    def test_accept_needs_reason_and_ids_are_unique(self):
        bad = self.tmp / "bad"
        bad.mkdir()
        (bad / "a.toml").write_text(
            '[[rule]]\nid="x"\nkind="keys_in_dbc"\nsource="s"\ndbc="Map"\n'
            '[[rule.accept]]\nkey="1"\n')
        with self.assertRaisesRegex(ConsistencyError, "needs a reason"):
            consistency.load_rules(bad)

    def test_sources_must_be_read_only(self):
        p = self.tmp / "s.toml"
        p.write_text('[source.x]\nquery = "DELETE FROM spell_template"\nkey = "entry"\n')
        with self.assertRaisesRegex(SqlSourceError, "read-only SELECT"):
            load_sources(p)
        p.write_text('[source.x]\nquery = "SELECT 1; DROP TABLE t"\nkey = "entry"\n')
        with self.assertRaises(SqlSourceError):
            load_sources(p)


if __name__ == "__main__":
    unittest.main()
