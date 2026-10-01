"""Client interface files we patch (Lua/XML), taken from the client at build time.

Turtle's talent frame (Interface\\AddOns\\Blizzard_TalentUI, last copy in
patch-9.mpq) has 20 talent buttons per tree; our extended trees have up to 26
(#455), and the owner wants room for more (30, #409 of 2026-10-01). Like the
DBCs, the original file is client data: it never enters Git. extract-base
copies it out of the base archives into <base>/ui/<path>; build checks its
sha256 against clientpatch.toml (a changed Turtle file stops the build, so we
never ship our edit over a newer Turtle version), applies a named transform
whose every replacement must match exactly once, and packs the result.

Configuration (clientpatch.toml):

    [ui]
    talent_buttons = 30

    [[ui.file]]
    path = "Interface\\AddOns\\Blizzard_TalentUI\\Blizzard_TalentUI.lua"
    sha256 = "..."
    transform = "talent_buttons_lua"
"""

import hashlib
import re
from pathlib import Path

from .errors import ClientPatchError


class UiError(ClientPatchError):
    """A client interface file is missing, changed or does not fit its transform."""


def local_path(base_dir: Path, member: str) -> Path:
    return base_dir / "ui" / Path(*member.replace("\\", "/").split("/"))


def _once(pattern: str, repl, text: str, what: str) -> str:
    out, n = re.subn(pattern, repl, text, flags=re.M)
    if n != 1:
        raise UiError(f"{what}: expected exactly one match, found {n}")
    return out


def talent_buttons_lua(text: str, buttons: int) -> str:
    return _once(r"^MAX_NUM_TALENTS = 20;", f"MAX_NUM_TALENTS = {buttons};", text, "MAX_NUM_TALENTS")


def talent_buttons_xml(text: str, buttons: int) -> str:
    """Append buttons 21..N after button 20, same indentation and line ending."""
    m = re.search(r'^([ \t]*)<Button name="TalentFrameTalent20" inherits="TalentButtonTemplate" id="20"/>(\r?\n)',
                  text, flags=re.M)
    if not m or len(re.findall(r'name="TalentFrameTalent\d+"', text)) != 20:
        raise UiError("talent buttons: expected exactly TalentFrameTalent1..20")
    indent, eol = m.group(1), m.group(2)
    extra = "".join(f'{indent}<Button name="TalentFrameTalent{i}" inherits="TalentButtonTemplate" id="{i}"/>{eol}'
                    for i in range(21, buttons + 1))
    return text[:m.end()] + extra + text[m.end():]


TRANSFORMS = {"talent_buttons_lua": talent_buttons_lua, "talent_buttons_xml": talent_buttons_xml}


def files(cfg_data: dict) -> list[dict]:
    return cfg_data.get("ui", {}).get("file", [])


def talent_buttons(cfg_data: dict) -> int | None:
    return cfg_data.get("ui", {}).get("talent_buttons")


def build_files(cfg_data: dict, base_dir: Path, staging: Path) -> list[dict]:
    """Patch every configured file into staging/<path>. Returns build-info rows."""
    buttons = talent_buttons(cfg_data)
    rows = []
    for entry in files(cfg_data):
        member, want, name = entry["path"], entry["sha256"].lower(), entry["transform"]
        src = local_path(base_dir, member)
        if not src.is_file():
            raise UiError(f"{member}: not in the base ({src}); run extract-base with this configuration")
        raw = src.read_bytes()
        have = hashlib.sha256(raw).hexdigest()
        if have != want:
            raise UiError(f"{member}: client copy has sha256 {have}, configuration expects {want} "
                          f"(Turtle changed the file: review the transform before updating the hash)")
        if name not in TRANSFORMS:
            raise UiError(f"{member}: unknown transform {name!r}")
        if not buttons or buttons < 20:
            raise UiError("[ui] talent_buttons must be set (>= 20)")
        out = TRANSFORMS[name](raw.decode("latin-1"), buttons).encode("latin-1")
        dst = staging / Path(*member.replace("\\", "/").split("/"))
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(out)
        rows.append({"path": member.replace("\\", "/"), "transform": name, "source_sha256": have,
                     "sha256": hashlib.sha256(out).hexdigest()})
    return rows


def check_talents_per_tab(talent_table, buttons: int | None) -> None:
    """Every talent tree must fit the talent frame (#455: 26 talents on 20 buttons
    showed an incomplete tree with 'Too many talents in talent frame!')."""
    limit = buttons or 20
    counts: dict[int, int] = {}
    tab = talent_table.binding.index("TabID")
    for row in talent_table.rows:
        counts[row.values[tab]] = counts.get(row.values[tab], 0) + 1
    over = {tab: n for tab, n in sorted(counts.items()) if n > limit}
    if over:
        raise UiError(f"talent trees with more talents than the talent frame has buttons ({limit}): {over}")
