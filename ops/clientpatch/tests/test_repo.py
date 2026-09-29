"""The committed configuration itself must be valid (runs without a client)."""

import contextlib
import io
import json
import unittest

from synth import ROOT

from clientpatch.cli import main


class RepoConfig(unittest.TestCase):
    def test_check_passes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(main(["check"]), 0)
        self.assertIn("ok:", out.getvalue())

    def test_templates_are_json_with_placeholders_only(self):
        for p in (ROOT / "templates").rglob("*.json"):
            text = p.read_text(encoding="utf-8")
            json.loads(text)
            # Real host names and IPs never go into Git (public repository).
            self.assertNotRegex(text, r"https://(?!<patch-host>|github\.com/)", p.name)
            self.assertNotRegex(text, r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", p.name)

    def test_no_client_files_in_the_tool_tree(self):
        for p in ROOT.rglob("*"):
            self.assertNotIn(p.suffix.lower(), {".dbc", ".mpq"}, str(p))


if __name__ == "__main__":
    unittest.main()
