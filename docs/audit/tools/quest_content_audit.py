#!/usr/bin/env python3
"""Static quest/content audit for twow-core world data (twow-repo#408).

Read-only: runs SELECTs against a scratch MariaDB and reads the C++ sources.
Report: docs/audit/quest-content-audit.md.

Build the two schemas from a twow-core checkout (disposable database only, never live):

    mariadb -e "create database tw_world; create database tw_base"
    for f in sql/base/*.sql; do mariadb tw_world < $f; mariadb tw_base < $f; done
    # world/ and top-level migrations, merged by file name (= timestamp)
    for f in $( (for f in sql/database_updates/world/*.sql sql/database_updates/*.sql; do
                 echo "$(basename $f) $f"; done) | sort | awk '{print $2}'); do
        mariadb tw_world < $f
    done

Run:

    quest_content_audit.py --core <twow-core checkout> --db tw_world --base-db tw_base \
        [--defaults-file my.cnf] --out quest-content-audit.csv [--json summary.json]

`--base-db` is optional; with it, gaps that sql/base did not have are marked REGRESSION.
"""
import argparse, collections, csv, json, os, re, subprocess, sys

# ---------------------------------------------------------------- db helpers
ARGS = None


def rows(sql):
    cmd = ['mariadb']
    if ARGS.defaults_file:
        cmd.append('--defaults-file=' + ARGS.defaults_file)
    cmd += ['-B', '-N', ARGS.db, '-e', sql]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    res = []
    for line in out.split('\n'):
        if line == '':
            continue
        res.append([None if c == 'NULL' else c for c in line.split('\t')])
    return res


def ints(sql):
    return {int(r[0]) for r in rows(sql) if r[0] is not None}


def colmap(sql, n=2):
    d = collections.defaultdict(set)
    for r in rows(sql):
        d[int(r[0])].add(int(r[1]) if r[1] is not None and re.fullmatch(r'-?\d+', r[1]) else r[1])
    return d


# ---------------------------------------------------------------- C++ scan
def scan_cpp(core):
    """Integer literals + registered script names in src/scripts (and modules)."""
    nums = collections.defaultdict(lambda: collections.defaultdict(set))   # kind -> literal -> files
    names = {}
    cm = open(os.path.join(core, 'src/scripts/CMakeLists.txt')).read()
    compiled = set(re.findall(r'^\s*([\w/.\-]+\.cpp)', cm, re.M))
    called = set()
    srcs = []
    for base in ('src', 'modules'):
        for dp, _, fn in os.walk(os.path.join(core, base)):
            for f in fn:
                if f.endswith(('.cpp', '.h')):
                    srcs.append(os.path.join(dp, f))
    for p in srcs:
        t = open(p, errors='ignore').read()
        called.update(re.findall(r'(AddSC_\w+)\s*\(\s*\)\s*;', t))
    sroot = os.path.join(core, 'src/scripts')
    kinds = {'quest': re.compile(r'quest', re.I),
             'creature': re.compile(r'npc|creature|mob|boss|summon|entry|spawn|add|guard|trigger|minion|cre_|credit|killed|monster', re.I),
             'go': re.compile(r'go_|gob|object|door|chest|lever|brazier|bowl|portal|altar|gate|crystal|stone', re.I),
             'item': re.compile(r'item|key|reward|token', re.I)}
    for p in srcs:
        in_scripts = p.startswith(sroot)
        rel = os.path.relpath(p, os.path.join(core))
        t = open(p, errors='ignore').read()
        tc = re.sub(r'/\*.*?\*/', ' ', t, flags=re.S)
        for line in tc.split('\n'):
            line = line.split('//')[0]
            lits = re.findall(r'(?<![\w.])(\d{3,6})(?![\w.])', line)
            if not lits:
                continue
            for l in lits:
                nums['any'][int(l)].add(rel)
                if in_scripts or re.search(r'Summon|Credit|AddItem|StoreNewItem|Quest', line):
                    nums['weak'][int(l)].add(rel)
                if re.search(r'CompleteQuest|AreaExploredOrEventHappens|GroupEventHappens|FullQuestComplete|QUEST_', line):
                    nums['qcomplete'][int(l)].add(rel)
            if not in_scripts and not re.search(r'#define|\w+\s*=\s*\d+\s*,|case\s+\d+|==\s*\d+', line):
                continue
            for k, rx in kinds.items():
                if rx.search(line):
                    for l in lits:
                        nums[k][int(l)].add(rel)
    for p in srcs:
        in_scripts = p.startswith(sroot)
        rel = os.path.relpath(p, sroot) if in_scripts else os.path.relpath(p, core)
        t = open(p, errors='ignore').read()
        for m in re.finditer(r'void\s+(AddSC_\w+)\s*\(\s*\)\s*\{', t):
            i, depth = m.end(), 1
            while depth and i < len(t):
                depth += {'{': 1, '}': -1}.get(t[i], 0)
                i += 1
            body = t[m.end():i]
            ok = m.group(1) in called and (not in_scripts or rel in compiled or p.endswith('.h'))
            for n in re.findall(r'->Name\s*=\s*"([^"]+)"', body) + re.findall(r'Register\w*Script\(\s*"([^"]+)"', body):
                names.setdefault(n, []).append((rel, m.group(1), ok))
    registered = {n for n, v in names.items() if any(x[2] for x in v)}
    return nums, registered, names


# ---------------------------------------------------------------- constants
QUEST_SORT = {1: 'Epic', 21: 'Wynnfall', 22: 'Seasonal', 23: 'Undercity One Shots', 24: 'Herbalism',
              25: 'Battlegrounds', 41: 'Day of the Dead', 61: 'Warlock', 81: 'Warrior', 82: 'Shaman',
              101: 'Fishing', 121: 'Blacksmithing', 141: 'Paladin', 161: 'Mage', 162: 'Rogue',
              181: 'Alchemy', 182: 'Leatherworking', 201: 'Engineering', 221: 'Treasure Map',
              241: 'Tournament', 261: 'Hunter', 262: 'Priest', 263: 'Druid', 264: 'Tailoring',
              284: 'Special', 304: 'Cooking', 324: 'First Aid', 344: 'Legendary', 364: 'Darkmoon Faire',
              365: "Ahn'Qiraj War", 366: 'Lunar Festival', 367: 'Reputation', 368: 'Invasion',
              369: 'Midsummer'}
SUMMON_CRE_EFFECTS = (28, 41, 42, 56, 73, 74, 87, 88, 89, 90, 93, 97, 112)
SUMMON_GO_EFFECTS = (50, 76, 104, 105, 106, 107, 86)
SCRIPT_TABLES = ['quest_start_scripts', 'quest_end_scripts', 'event_scripts', 'gameobject_scripts',
                 'gossip_scripts', 'generic_scripts', 'creature_movement_scripts', 'creature_ai_scripts',
                 'spell_scripts', 'creature_spells_scripts']
# numbers that the weak C++ match hits by coincidence (verified by hand): a quest-status check and gossip text ids
FALSE_CPP_MATCH = {60070, 70001, 70002, 70003}
# where an unspawned boss belongs, when the data alone does not say (inferred from quest text / loot / C++ folder)
BOSS_HINT = {93333: 'Tower of Karazhan (inferred)', 65148: 'Blackwing Lair (inferred)', 59812: 'Tower of Karazhan (inferred)'}
DEPRECATED_RE = re.compile(r'deprecated|unused|\bOLD\b|zzOLD|\[PH\]|<NYI>|NYI|<TXT>|<TEST>|\btest\b|DND|\[DNT\]',
                           re.I)


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument('--core', required=True)
    ap.add_argument('--db', default='tw_world')
    ap.add_argument('--defaults-file')
    ap.add_argument('--out', required=True)
    ap.add_argument('--json')
    ap.add_argument('--base-db', help='schema with sql/base only (no migrations), to detect regressions')
    ARGS = ap.parse_args()

    cpp_nums, cpp_registered, cpp_all_names = scan_cpp(ARGS.core)

    # ------------------------------------------------------------ world data
    ct = {}
    for r in rows("select entry,name,`rank`,loot_id,pickpocket_loot_id,skinning_loot_id,vendor_id,npc_flags,script_name,ai_name,faction,level_min from creature_template"):
        ct[int(r[0])] = dict(name=r[1], rank=int(r[2]), loot=int(r[3]), pp=int(r[4]), skin=int(r[5]),
                             vendor=int(r[6]), npcflags=int(r[7]), script=r[8] or '', ai=r[9] or '', level=int(r[11]))
    gt = {}
    for r in rows("select entry,type,name,data0,data1,data2,data3,data6,data10,script_name,flags from gameobject_template"):
        gt[int(r[0])] = dict(type=int(r[1]), name=r[2], d0=int(r[3]), d1=int(r[4]), d2=int(r[5]), d3=int(r[6]),
                             d6=int(r[7]), d10=int(r[8]), script=r[9] or '', flags=int(r[10]))
    it = {}
    for r in rows("select entry,name,start_quest,spellid_1,spellid_2,spellid_3,spellid_4,spellid_5,script_name,class,flags from item_template"):
        it[int(r[0])] = dict(name=r[1], start_quest=int(r[2]), spells=[int(x) for x in r[3:8] if int(x)],
                             script=r[8] or '', cls=int(r[9]), flags=int(r[10]))

    # --- spawns (creature ids 1..4), honouring SPAWN_FLAG_DISABLED unless a script loads the guid
    loaded_cre_guids = set()
    loaded_go_guids = set()
    for t in SCRIPT_TABLES:
        loaded_cre_guids |= ints(f"select datalong from {t} where command=91")
        loaded_go_guids |= ints(f"select datalong from {t} where command in (82,9)")
    event_cre = colmap("select guid,event from game_event_creature")
    event_go = colmap("select guid,event from game_event_gameobject")
    cre_spawn = collections.defaultdict(list)     # entry -> [(guid,map,flags)]
    for r in rows("select guid,id,id2,id3,id4,map,spawn_flags from creature"):
        guid, mp, fl = int(r[0]), int(r[5]), int(r[6])
        for e in {int(x) for x in r[1:5] if int(x) > 0}:
            cre_spawn[e].append((guid, mp, fl))
    go_spawn = collections.defaultdict(list)
    for r in rows("select guid,id,map,spawn_flags from gameobject"):
        go_spawn[int(r[1])].append((int(r[0]), int(r[2]), int(r[3])))

    ge_disabled = ints("select entry from game_event where disabled<>0")
    ge_entry_swap = collections.defaultdict(set)   # creature entry -> events that morph a spawned guid into it
    for r in rows("select guid,entry_id,event from game_event_creature_data where entry_id>0"):
        ge_entry_swap[int(r[1])].add(int(r[2]))

    def spawn_state(entry, spawns, loaded, events):
        s = spawns.get(entry, [])
        if not s:
            return 'none', set()
        live = [x for x in s if not (x[2] & 2) or x[0] in loaded]
        maps = {x[1] for x in s}
        if not live:
            return 'disabled', maps
        if all(x[0] in events and all(ev > 0 for ev in events[x[0]]) for x in live):
            if all(all(ev in ge_disabled for ev in events[x[0]]) for x in live):
                return 'event_off', maps
            return 'event', maps
        return 'yes', maps

    # --- summons / credits from DB scripts
    sc_summon_cre = collections.defaultdict(set)  # entry -> sources
    sc_summon_go = collections.defaultdict(set)
    sc_killcredit = collections.defaultdict(set)
    sc_explored = collections.defaultdict(set)    # quest -> sources
    sc_createitem = collections.defaultdict(set)
    sc_castspell = set()
    script_ids = {}
    for t in SCRIPT_TABLES:
        script_ids[t] = ints(f"select distinct id from {t}")
        for r in rows(f"select id,command,datalong,datalong2 from {t} where command in (7,8,10,15,17,27,76,83)"):
            sid, cmd, dl = int(r[0]), int(r[1]), int(r[2])
            src = f"{t}#{sid}"
            if cmd == 10 or cmd == 27:
                sc_summon_cre[dl].add(src)
            elif cmd == 76:
                sc_summon_go[dl].add(src)
            elif cmd == 8:
                sc_killcredit[dl].add(src)
            elif cmd in (7, 83):
                sc_explored[dl].add(src)
            elif cmd == 17:
                sc_createitem[dl].add(src)
            elif cmd == 15:
                sc_castspell.add(dl)
    # creature_ai_events -> creature_ai_scripts link (a script row is live if some event references it)
    ai_script_owner = collections.defaultdict(set)
    for r in rows("select creature_id,action1_script,action2_script,action3_script from creature_ai_events"):
        for a in r[1:]:
            if a and int(a):
                ai_script_owner[int(a)].add(int(r[0]))

    # --- spells
    sp = {}
    for r in rows("select entry,name,effect1,effect2,effect3,effectMiscValue1,effectMiscValue2,effectMiscValue3,"
                  "effectItemType1,effectItemType2,effectItemType3,effectTriggerSpell1,effectTriggerSpell2,effectTriggerSpell3,script_name from spell_template"):
        e = int(r[0])
        sp[e] = dict(name=r[1], eff=[int(x) for x in r[2:5]], misc=[int(x) for x in r[5:8]],
                     item=[int(x) for x in r[8:11]], trig=[int(x) for x in r[11:14]], script=r[14] or '')
    sp_summon_cre = collections.defaultdict(set)
    sp_summon_go = collections.defaultdict(set)
    sp_create_item = collections.defaultdict(set)
    sp_quest_complete = collections.defaultdict(set)
    sp_send_event = collections.defaultdict(set)
    for e, s in sp.items():
        for i in range(3):
            ef, mv, itm = s['eff'][i], s['misc'][i], s['item'][i]
            if ef in SUMMON_CRE_EFFECTS and mv > 0:
                sp_summon_cre[mv].add(e)
            if ef in SUMMON_GO_EFFECTS and mv > 0:
                sp_summon_go[mv].add(e)
            if itm > 0 and ef in (6, 24, 34, 59):
                sp_create_item[itm].add(e)
            if ef == 16 and mv > 0:
                sp_quest_complete[mv].add(e)
            if ef == 61 and mv > 0:
                sp_send_event[mv].add(e)

    # --- castable spell set (approximate): anything a player/creature/script/item/GO can cast, plus triggers
    castable = set()
    for ent in it.values():
        castable.update(ent['spells'])
    castable |= ints("select spell from npc_trainer") | ints("select spell from npc_trainer_template")
    castable |= ints("select spell_id from skill_line_ability") | ints("select spell from playercreateinfo_spell")
    castable |= ints("select SpellID from spell_learn_spell")
    for c in ('RewSpell', 'RewSpellCast', 'SrcSpell'):
        castable |= ints(f"select {c} from quest_template where {c}>0")
    for i in range(1, 5):
        castable |= ints(f"select spell_id{i} from creature_template where spell_id{i}>0")
    for i in range(1, 9):
        castable |= ints(f"select spellId_{i} from creature_spells where spellId_{i}>0")
    castable |= sc_castspell
    for g in gt.values():
        if g['type'] == 22:
            castable.add(g['d0'])       # spellcaster
        if g['type'] == 6:
            castable.add(g['d3'])       # trap
        if g['type'] == 10 and g['d10']:
            castable.add(g['d10'])      # goober
        if g['type'] == 18:
            castable.update([g['d1']])  # summoning ritual spell
    castable |= set(k for k in cpp_nums['any'] if k in sp)
    changed = True
    while changed:
        n = len(castable)
        for e in list(castable):
            s = sp.get(e)
            if s:
                for t in s['trig']:
                    if t:
                        castable.add(t)
        changed = len(castable) != n

    # --- loot
    loot_tables = {}
    item_in = collections.defaultdict(list)   # item -> [(table, entry, chance)]
    ref_parents = collections.defaultdict(set)  # ref entry -> (table, entry)
    for tbl in ('creature_loot_template', 'gameobject_loot_template', 'reference_loot_template', 'item_loot_template',
                'pickpocketing_loot_template', 'skinning_loot_template', 'fishing_loot_template',
                'disenchant_loot_template', 'mail_loot_template'):
        for r in rows(f"select entry,item,mincountOrRef,ChanceOrQuestChance from {tbl}"):
            en, itm, mc, ch = int(r[0]), int(r[1]), int(r[2]), float(r[3])
            if mc < 0:
                ref_parents[-mc].add((tbl, en))
            else:
                item_in[itm].append((tbl, en, ch))
    # owners of loot entries
    cre_by_loot = collections.defaultdict(set)
    cre_by_pp = collections.defaultdict(set)
    cre_by_skin = collections.defaultdict(set)
    for e, c in ct.items():
        if c['loot']:
            cre_by_loot[c['loot']].add(e)
        if c['pp']:
            cre_by_pp[c['pp']].add(e)
        if c['skin']:
            cre_by_skin[c['skin']].add(e)
    go_by_loot = collections.defaultdict(set)
    for e, g in gt.items():
        if g['type'] in (3, 25) and g['d1']:
            go_by_loot[g['d1']].add(e)
    bg_player_loot = ints("select player_loot_id from battleground_template where player_loot_id>0")
    mail_by_loot = ints("select RewMailTemplateId from quest_template where RewMailTemplateId>0")

    vendor_items = collections.defaultdict(set)
    for r in rows("select entry,item from npc_vendor"):
        vendor_items[int(r[1])].add(('npc', int(r[0])))
    vt_owner = collections.defaultdict(set)
    for e, c in ct.items():
        if c['vendor']:
            vt_owner[c['vendor']].add(e)
    for r in rows("select entry,item from npc_vendor_template"):
        for owner in vt_owner.get(int(r[0]), {None}):
            vendor_items[int(r[1])].add(('tmpl', owner if owner else -int(r[0])))
    shop_items = ints("select item from shop_items")
    create_items = ints("select itemid from playercreateinfo_item")

    # ------------------------------------------------------------ regression lookup against sql/base
    base_loot = collections.defaultdict(set)
    base_cre = collections.Counter()
    base_go = collections.Counter()
    if ARGS.base_db:
        live_db = ARGS.db
        ARGS.db = ARGS.base_db
        for tbl in ('creature_loot_template', 'gameobject_loot_template', 'reference_loot_template',
                    'item_loot_template', 'pickpocketing_loot_template', 'skinning_loot_template'):
            for r in rows(f"select entry,item from {tbl} where mincountOrRef>=0"):
                base_loot[int(r[1])].add(f'{tbl}:{r[0]}')
        for r in rows("select id,count(*) from creature group by id"):
            base_cre[int(r[0])] = int(r[1])
        for r in rows("select id,count(*) from gameobject group by id"):
            base_go[int(r[0])] = int(r[1])
        ARGS.db = live_db

    def base_note_item(i):
        if i in base_loot and not item_in.get(i):
            return f'; REGRESSION: sql/base had loot rows {sorted(base_loot[i])[:3]} that the migrations removed'
        return ''

    def base_note_spawn(kind, e):
        c = (base_cre if kind == 'creature' else base_go).get(e, 0)
        now = len((cre_spawn if kind == 'creature' else go_spawn).get(e, ()))
        if c and not now:
            return f'; REGRESSION: sql/base had {c} spawn(s) that the migrations removed'
        return ''

    # ------------------------------------------------------------ creature/GO availability
    def cre_avail(e, depth=0):
        """(state, detail). state: spawned | event | summon | script | cpp | disabled | none | missing_tpl"""
        if e not in ct:
            return 'missing_tpl', f'creature_template {e} does not exist'
        st, maps = spawn_state(e, cre_spawn, loaded_cre_guids, event_cre)
        if st == 'yes':
            return 'spawned', f'spawned on map(s) {sorted(maps)}'
        srcs = []
        if sc_summon_cre.get(e):
            srcs.append('db-script summon ' + ','.join(sorted(sc_summon_cre[e])[:3]))
        cs = [s for s in sp_summon_cre.get(e, ()) if s in castable]
        if cs:
            srcs.append('summon spell ' + ','.join(map(str, sorted(cs)[:3])))
        if st == 'event':
            return 'event', f'spawned only via game_event (maps {sorted(maps)})' + ('; ' + '; '.join(srcs) if srcs else '')
        if st == 'event_off' and not srcs:
            return 'event_off', f'spawned only by game_event(s) that are disabled in game_event (maps {sorted(maps)})'
        if ge_entry_swap.get(e):
            evs = sorted(ge_entry_swap[e])
            if all(ev in ge_disabled for ev in evs):
                srcs_d = f'only via game_event_creature_data entry swap in disabled event(s) {evs}'
            else:
                return 'event', f'game_event_creature_data entry swap in event(s) {evs}'
        if srcs:
            return 'summon', '; '.join(srcs)
        if e in cpp_nums['creature']:
            return 'cpp', 'entry literal in C++ ' + ','.join(sorted(cpp_nums['creature'][e])[:2])
        if e in cpp_nums['weak'] and e not in FALSE_CPP_MATCH:
            return 'cpp', 'number appears in C++ (weak match, verify) ' + ','.join(sorted(cpp_nums['weak'][e])[:2])
        if st == 'disabled':
            return 'disabled', f'only SPAWN_FLAG_DISABLED spawns (maps {sorted(maps)}), no script loads them'
        uncast = sp_summon_cre.get(e)
        if uncast:
            return 'none', f'no spawn; only summon spell(s) {sorted(uncast)[:3]} which nothing casts'
        return 'none', 'no spawn, no summon (db scripts/spells), no C++ reference' + base_note_spawn('creature', e)

    def go_avail(e):
        if e not in gt:
            return 'missing_tpl', f'gameobject_template {e} does not exist'
        st, maps = spawn_state(e, go_spawn, loaded_go_guids, event_go)
        if st == 'yes':
            return 'spawned', f'spawned on map(s) {sorted(maps)}'
        srcs = []
        if sc_summon_go.get(e):
            srcs.append('db-script summon ' + ','.join(sorted(sc_summon_go[e])[:3]))
        cs = [s for s in sp_summon_go.get(e, ()) if s in castable]
        if cs:
            srcs.append('summon spell ' + ','.join(map(str, sorted(cs)[:3])))
        if st == 'event':
            return 'event', f'spawned only via game_event (maps {sorted(maps)})'
        if st == 'event_off' and not srcs:
            return 'event_off', f'spawned only by game_event(s) that are disabled in game_event (maps {sorted(maps)})'
        if srcs:
            return 'summon', '; '.join(srcs)
        if e in cpp_nums['go']:
            return 'cpp', 'entry literal in C++ ' + ','.join(sorted(cpp_nums['go'][e])[:2])
        if e in cpp_nums['weak'] and e not in FALSE_CPP_MATCH:
            return 'cpp', 'number appears in C++ (weak match, verify) ' + ','.join(sorted(cpp_nums['weak'][e])[:2])
        if st == 'disabled':
            return 'disabled', f'only SPAWN_FLAG_DISABLED spawns (maps {sorted(maps)})'
        return 'none', 'no spawn, no summon, no C++ reference' + base_note_spawn('go', e)

    GOOD = ('spawned', 'event', 'summon')

    ref_cache = {}

    def ref_reachable(ref, seen=None):
        """Is a reference_loot entry reachable from a live owner?"""
        if ref in ref_cache:
            return ref_cache[ref]
        seen = seen or set()
        if ref in seen:
            return None
        seen.add(ref)
        res = f'battleground_template.player_loot_id={ref} (player corpse loot)' if ref in bg_player_loot else None
        for tbl, en in ([] if res else ref_parents.get(ref, ())):
            r = owner_reachable(tbl, en, seen)
            if r:
                res = r
                break
        ref_cache[ref] = res
        return res

    def owner_reachable(tbl, en, seen=None):
        if tbl == 'creature_loot_template':
            for c in cre_by_loot.get(en, ()):
                if cre_avail(c)[0] in GOOD + ('cpp',):
                    return f'drops from creature {c} ({ct[c]["name"]})'
            return None
        if tbl == 'pickpocketing_loot_template':
            for c in cre_by_pp.get(en, ()):
                if cre_avail(c)[0] in GOOD:
                    return f'pickpocket creature {c}'
            return None
        if tbl == 'skinning_loot_template':
            for c in cre_by_skin.get(en, ()):
                if cre_avail(c)[0] in GOOD:
                    return f'skinning creature {c}'
            return None
        if tbl == 'gameobject_loot_template':
            for g in go_by_loot.get(en, ()):
                if go_avail(g)[0] in GOOD + ('cpp',):
                    return f'GO loot {g} ({gt[g]["name"]})'
            return None
        if tbl == 'item_loot_template':
            if en in it and item_source(en, depth=1)[0]:
                return f'contained in item {en}'
            return None
        if tbl == 'reference_loot_template':
            r = ref_reachable(en, seen)
            return f'reference {en} <- {r}' if r else None
        if tbl == 'fishing_loot_template':
            return f'fishing zone {en}'
        if tbl == 'mail_loot_template':
            return f'mail loot {en}' if en in mail_by_loot else None
        if tbl == 'disenchant_loot_template':
            return f'disenchant {en}'
        return None

    quest_rew_items = collections.defaultdict(set)
    quest_src_items = collections.defaultdict(set)

    item_cache = {}

    def item_source(i, depth=0):
        """(found:bool, detail)"""
        if i in item_cache:
            return item_cache[i]
        if i not in it:
            return (False, f'item_template {i} does not exist')
        item_cache[i] = (False, 'recursion')
        found = []
        unreach = []
        for tbl, en, ch in item_in.get(i, ()):
            r = owner_reachable(tbl, en)
            if r:
                found.append(f'{tbl}:{en} {r}' + (' (quest drop)' if ch < 0 else ''))
                break
            else:
                unreach.append(f'{tbl}:{en}')
        if vendor_items.get(i):
            found.append('vendor ' + ','.join(f'{a}:{b}' for a, b in sorted(vendor_items[i])[:2]))
        if quest_src_items.get(i):
            found.append('quest SrcItemId of ' + ','.join(map(str, sorted(quest_src_items[i])[:3])))
        if quest_rew_items.get(i):
            found.append('quest reward of ' + ','.join(map(str, sorted(quest_rew_items[i])[:3])))
        cs = [s for s in sp_create_item.get(i, ()) if s in castable]
        if cs:
            found.append('create-item spell ' + ','.join(map(str, sorted(cs)[:3])))
        if sc_createitem.get(i):
            found.append('db-script create ' + ','.join(sorted(sc_createitem[i])[:2]))
        if i in create_items:
            found.append('playercreateinfo_item')
        if i in shop_items:
            found.append('shop_items')
        if found:
            res = (True, '; '.join(found))
        else:
            det = []
            if unreach:
                det.append('loot rows only on unreachable owners: ' + ','.join(unreach[:4]))
            if sp_create_item.get(i):
                det.append('create spell(s) not castable: ' + ','.join(map(str, sorted(sp_create_item[i])[:3])))
            if i in cpp_nums['item'] or i in cpp_nums['weak']:
                det.append('item id literal in C++ ' + ','.join(sorted(cpp_nums['item'].get(i) or cpp_nums['weak'][i])[:2]))
                res = (None, '; '.join(det))
            else:
                res = (False, ('; '.join(det) or 'no loot/vendor/quest/spell/script source') + base_note_item(i))
        item_cache[i] = res
        return res

    # ------------------------------------------------------------ quests
    qcols = ['entry', 'Title', 'QuestLevel', 'MinLevel', 'ZoneOrSort', 'Type', 'RequiredClasses', 'RequiredRaces',
             'SpecialFlags', 'QuestFlags', 'PrevQuestId', 'NextQuestId', 'ExclusiveGroup', 'NextQuestInChain',
             'SrcItemId', 'SrcSpell', 'Method', 'StartScript', 'CompleteScript', 'RewMailTemplateId', 'RequiredCondition',
             'RepObjectiveFaction', 'RepObjectiveValue'] + \
            [f'ReqItemId{i}' for i in range(1, 5)] + [f'ReqItemCount{i}' for i in range(1, 5)] + \
            [f'ReqSourceId{i}' for i in range(1, 5)] + \
            [f'ReqCreatureOrGOId{i}' for i in range(1, 5)] + [f'ReqCreatureOrGOCount{i}' for i in range(1, 5)] + \
            [f'ReqSpellCast{i}' for i in range(1, 5)] + \
            [f'RewItemId{i}' for i in range(1, 5)] + [f'RewChoiceItemId{i}' for i in range(1, 7)] + ['Objectives']
    Q = {}
    for r in rows("select " + ','.join(qcols) + " from quest_template"):
        d = dict(zip(qcols, r))
        for k in qcols:
            if k not in ('Title', 'Objectives') and d[k] is not None:
                d[k] = int(d[k])
        Q[d['entry']] = d
    for q in Q.values():
        for k in [f'RewItemId{i}' for i in range(1, 5)] + [f'RewChoiceItemId{i}' for i in range(1, 7)]:
            if q[k]:
                quest_rew_items[q[k]].add(q['entry'])
        if q['SrcItemId']:
            quest_src_items[q['SrcItemId']].add(q['entry'])

    cqr = colmap("select quest,id from creature_questrelation")
    cir = colmap("select quest,id from creature_involvedrelation")
    gqr = colmap("select quest,id from gameobject_questrelation")
    gir = colmap("select quest,id from gameobject_involvedrelation")
    item_starts = collections.defaultdict(set)
    for e, i in it.items():
        if i['start_quest']:
            item_starts[i['start_quest']].add(e)
    atr = colmap("select quest,id from areatrigger_involvedrelation")
    at_tpl = ints("select id from areatrigger_template")
    ev_quests = colmap("select quest,event from game_event_quest")
    cast_obj = colmap("select entry,spell_id from quest_cast_objective")
    # Spell.cpp: a spell in quest_cast_objective cast on a player gives KilledMonsterCredit(questId + idx*10)
    for r in rows("select entry,idx,spell_id,player_guid from quest_cast_objective"):
        if int(r[3]) <= 0:
            sc_killcredit[int(r[0]) + int(r[1]) * 10].add(f'quest_cast_objective quest {r[0]} idx {r[1]} spell {r[2]}')
        else:
            sc_killcredit[int(r[3])].add(f'quest_cast_objective quest {r[0]} spell {r[2]} (player guid credit)')
    zones = {int(r[0]): r[1] for r in rows("select entry,name from area_template")}
    zone_map = {}
    for r in rows("select entry,map_id from area_template"):
        zone_map[int(r[0])] = int(r[1])
    maps = {int(r[0]): r[1] for r in rows("select entry,map_name from map_template")}

    def zone_name(z):
        if z > 0:
            return zones.get(z, f'zone {z}')
        if z < 0:
            return QUEST_SORT.get(-z, f'sort {z}')
        return 'none'

    findings = []

    def add(q, cat, cause, evidence, effort, sev_rank, verdict='', follow=0):
        findings.append(dict(quest_id=q['entry'] if q else '', title=q['Title'] if q else '',
                             level=q['QuestLevel'] if q else '', zone=zone_name(q['ZoneOrSort']) if q else '',
                             category=cat, cause=cause, evidence=evidence, effort=effort, verdict=verdict,
                             blocked_follow_ups=follow, _rank=sev_rank))

    per_quest = {}
    for qid, q in sorted(Q.items()):
        issues = []   # (cat, cause, evidence, effort, blocking)
        title = q['Title'] or ''
        deprecated = bool(DEPRECATED_RE.search(title))
        givers_c = cqr.get(qid, set())
        givers_g = gqr.get(qid, set())
        givers_i = item_starts.get(qid, set())
        enders_c = cir.get(qid, set())
        enders_g = gir.get(qid, set())
        has_giver_rel = bool(givers_c or givers_g or givers_i)
        # ---- giver
        live_givers = []
        dead_givers = []
        for c in givers_c:
            st, det = cre_avail(c)
            (live_givers if st in GOOD + ('cpp',) else dead_givers).append(f'creature {c} ({ct.get(c, {}).get("name", "?")}): {det}')
        for g in givers_g:
            st, det = go_avail(g)
            (live_givers if st in GOOD + ('cpp',) else dead_givers).append(f'GO {g} ({gt.get(g, {}).get("name", "?")}): {det}')
        for i in givers_i:
            ok, det = item_source(i)
            (live_givers if ok or ok is None else dead_givers).append(f'item {i} ({it[i]["name"]}): {det}')
        orphan = not has_giver_rel
        unoffered = not orphan and not live_givers
        event_off = unoffered and all('disabled in game_event' in d for d in dead_givers)
        if unoffered:
            issues.append(('SPAWN_GAP', 'quest giver exists in *_questrelation/start_quest but is not obtainable, so the quest is never offered',
                           ' | '.join(dead_givers), 'S', 'U'))
        # ---- ender
        live_enders, dead_enders = [], []
        for c in enders_c:
            st, det = cre_avail(c)
            (live_enders if st in GOOD + ('cpp',) else dead_enders).append(f'creature {c} ({ct.get(c, {}).get("name", "?")}): {det}')
        for g in enders_g:
            st, det = go_avail(g)
            (live_enders if st in GOOD + ('cpp',) else dead_enders).append(f'GO {g} ({gt.get(g, {}).get("name", "?")}): {det}')
        autocomplete = q['Method'] == 0
        if not (enders_c or enders_g):
            if not orphan and not autocomplete:
                issues.append(('BROKEN', 'no quest ender (no creature/gameobject_involvedrelation row)',
                               f'select * from creature_involvedrelation where quest={qid} -> empty; gameobject_involvedrelation -> empty',
                               'S', True))
        elif not live_enders:
            issues.append(('SPAWN_GAP', 'quest ender is not spawned/summonable', ' | '.join(dead_enders), 'S', True))
        # ---- scripts
        for col, tbl in (('StartScript', 'quest_start_scripts'), ('CompleteScript', 'quest_end_scripts')):
            sid = q[col]
            if sid and sid not in script_ids[tbl]:
                cpp_hit = sorted(cpp_nums['quest'].get(qid, ()))
                if cpp_hit:
                    issues.append(('OK_SUSPICIOUS', f'{col}={sid} dangles ({tbl} has no id={sid}) but quest id is referenced in C++ (effect probably scripted there)',
                                   f'select * from {tbl} where id={sid} -> empty; C++: {cpp_hit[:2]}', 'S', False))
                else:
                    issues.append(('SCRIPT_GAP', f'{col}={sid} but {tbl} has no rows with id={sid}: the scripted {"start" if col == "StartScript" else "completion"} effect never happens',
                                   f'select * from {tbl} where id={sid} -> empty', 'M', 'P'))
        # ---- exploration / event-driven completion
        if q['SpecialFlags'] & 2:
            srcs = []
            for at in atr.get(qid, ()):
                srcs.append(f'areatrigger {at}' + ('' if at in at_tpl else ' (missing in areatrigger_template!)'))
            if sc_explored.get(qid):
                srcs.append('db-script ' + ','.join(sorted(sc_explored[qid])[:3]))
            if sp_quest_complete.get(qid):
                srcs.append('spell QUEST_COMPLETE ' + ','.join(map(str, sorted(sp_quest_complete[qid])[:3])))
            if qid in cpp_nums['quest']:
                srcs.append('quest id literal in C++ ' + ','.join(sorted(cpp_nums['quest'][qid])[:2]))
            elif qid in cpp_nums['qcomplete']:
                srcs.append('C++ completes the quest ' + ','.join(sorted(cpp_nums['qcomplete'][qid])[:2]))
            elif qid in cpp_nums['weak'] and any('areatrigger' in f or 'custom_exploration' in f for f in cpp_nums['weak'][qid]):
                srcs.append('quest id in a C++ areatrigger table ' + ','.join(sorted(cpp_nums['weak'][qid])[:2]))
            at_missing = [at for at in atr.get(qid, ()) if at not in at_tpl]
            if not srcs:
                issues.append(('SCRIPT_GAP', 'SpecialFlags&2 (explore/event objective) but nothing completes it',
                               'no areatrigger_involvedrelation, no script command 7/83 with datalong=quest, no QUEST_COMPLETE spell, no C++ literal',
                               'M', True))
            elif at_missing and len(at_missing) == len(srcs):
                issues.append(('SCRIPT_GAP', 'exploration areatrigger not in areatrigger_template',
                               f'areatrigger_involvedrelation ids {at_missing}', 'S', True))
        # ---- objectives: creatures / GOs
        for i in range(1, 5):
            cg = q[f'ReqCreatureOrGOId{i}']
            if not cg:
                continue
            spell = q[f'ReqSpellCast{i}']
            if cg > 0:
                st, det = cre_avail(cg)
                credit = sc_killcredit.get(cg)
                if st not in GOOD:
                    if credit:
                        # credit given by a script: that's the source
                        continue
                    if st == 'cpp':
                        issues.append(('OK_SUSPICIOUS', f'objective creature {cg} ({ct[cg]["name"]}) only referenced from C++', det, 'S', False))
                    else:
                        cat = 'SPAWN_GAP'
                        issues.append((cat, f'objective creature {cg} ({ct.get(cg, {}).get("name", "?")}) not obtainable', det, 'M', True))
            else:
                g = -cg
                st, det = go_avail(g)
                if st not in GOOD:
                    if st == 'cpp':
                        issues.append(('OK_SUSPICIOUS', f'objective GO {g} ({gt[g]["name"]}) only referenced from C++', det, 'S', False))
                    else:
                        issues.append(('SPAWN_GAP', f'objective GO {g} ({gt.get(g, {}).get("name", "?")}) not obtainable', det, 'M', True))
            if spell:
                if spell not in sp:
                    issues.append(('BROKEN', f'ReqSpellCast{i}={spell} not in spell_template', f'select * from spell_template where entry={spell}', 'M', True))
                elif spell not in castable:
                    issues.append(('ITEM_GAP', f'ReqSpellCast{i}={spell} ({sp[spell]["name"]}) is not castable by any known source',
                                   'not on an item, trainer, skill line, quest, creature, GO or script', 'M', True))
        # ---- objectives: items
        for i in range(1, 5):
            item = q[f'ReqItemId{i}']
            if not item:
                continue
            ok, det = item_source(item)
            name = it.get(item, {}).get('name', '?')
            if ok is False:
                issues.append(('ITEM_GAP', f'required item {item} ({name}) has no source', det, 'M', True))
            elif ok is None:
                issues.append(('OK_SUSPICIOUS', f'required item {item} ({name}) only referenced from C++', det, 'S', False))
        # ---- source item (given on accept)
        if q['SrcItemId'] and q['SrcItemId'] not in it:
            issues.append(('BROKEN', f'SrcItemId {q["SrcItemId"]} not in item_template', '', 'S', True))
        # ---- chains
        for col in ('PrevQuestId', 'NextQuestId', 'NextQuestInChain'):
            v = q[col]
            if v and abs(v) not in Q:
                issues.append(('CHAIN_GAP', f'{col}={v} points to a quest that does not exist',
                               f'select entry from quest_template where entry={abs(v)} -> empty', 'S', col == 'PrevQuestId'))
        # ---- reward sanity (non-blocking)
        for k in [f'RewItemId{i}' for i in range(1, 5)] + [f'RewChoiceItemId{i}' for i in range(1, 7)]:
            if q[k] and q[k] not in it:
                issues.append(('OK_SUSPICIOUS', f'{k}={q[k]} not in item_template (reward lost)', '', 'S', False))
        if q['RequiredCondition']:
            pass
        if autocomplete:
            # Player::CanCompleteQuest: Method 0 skips creature/GO objectives; items are still taken on reward
            issues = [(('OK_SUSPICIOUS', x[1] + ' (not needed: Method=0 auto-complete skips creature/GO objectives)', x[2], x[3], False)
                       if x[0] == 'SPAWN_GAP' and 'objective' in x[1] else x) for x in issues]
        qc = sorted(cpp_nums['qcomplete'].get(qid, ()))
        if qc:
            issues = [(('OK_SUSPICIOUS', x[1] + ' (but C++ completes/handles this quest id directly)', x[2] + f'; C++: {qc[:2]}', x[3], False)
                       if x[4] is True and x[0] in ('SPAWN_GAP', 'ITEM_GAP') and ('objective' in x[1] or 'required item' in x[1]) else x)
                      for x in issues]
        per_quest[qid] = dict(issues=issues, orphan=orphan, unoffered=unoffered, event_off=event_off, deprecated=deprecated,
                              givers=sorted(live_givers), events=sorted(ev_quests.get(qid, ())))

    # ---- chain propagation: a quest whose PrevQuestId (positive: must be rewarded) is broken is blocked too

    children = collections.defaultdict(set)
    for qid, q in Q.items():
        p = q['PrevQuestId']
        if p > 0 and p in Q:
            children[p].add(qid)
        n = q['NextQuestInChain']
        if n and n in Q and Q[n]['PrevQuestId'] == 0:
            children[qid].add(n)
        nq = q['NextQuestId']
        if nq > 0 and nq in Q:
            children[qid].add(nq)

    def descendants(qid):
        seen, st = set(), [qid]
        while st:
            x = st.pop()
            for c in children.get(x, ()):
                if c not in seen:
                    seen.add(c)
                    st.append(c)
        return seen

    # ------------------------------------------------------------ emit
    stats = collections.Counter()
    verdicts = {}
    for qid, info in sorted(per_quest.items()):
        q = Q[qid]
        if q['Method'] == 1:
            stats['method_disabled'] += 1
            verdicts[qid] = 'DISABLED'
            continue
        if info['orphan']:
            stats['orphan_no_giver'] += 1
            parents_live = [p for p, cs in children.items() if qid in cs and not per_quest[p]['orphan']
                            and not per_quest[p]['unoffered']]
            if parents_live and not info['deprecated']:
                verdicts[qid] = 'UNOFFERED'
                add(q, 'CHAIN_GAP', 'quest has no giver (no questrelation, no starting item) but a live quest chains into it: the chain dead-ends',
                    f'parents {sorted(parents_live)[:5]}; select * from creature_questrelation where quest={qid} -> empty',
                    'S', 3, verdict='UNOFFERED')
            continue
        blockers = [x for x in info['issues'] if x[4] is True]
        partials = [x for x in info['issues'] if x[4] == 'P']
        real_blockers = [x for x in blockers if 'disabled in game_event' not in x[2]]
        q_events = info['events']
        if info['event_off'] or (blockers and not real_blockers) or (q_events and all(e in ge_disabled for e in q_events)):
            v = 'EVENT_OFF'
        elif info['unoffered']:
            v = 'UNOFFERED'
        elif blockers:
            v = 'BROKEN'
        elif partials:
            v = 'PARTIAL'
        elif info['issues']:
            v = 'OK_SUSPICIOUS'
        else:
            v = 'OK'
        if info['deprecated'] and v != 'OK':
            v += '(unused-title)'
        verdicts[qid] = v
        stats['verdict_' + v] += 1
        desc = descendants(qid)
        evt = f' [game_event {info["events"]}]' if info['events'] else ''
        for cat, cause, ev, eff, blk in info['issues']:
            add(q, cat, cause, ev + evt, eff, 1 if blk is True else 2, verdict=v,
                follow=len(desc) if v.startswith(('BROKEN', 'UNOFFERED')) else 0)
            stats['finding_' + cat] += 1

    # ------------------------------------------------------------ content pass (not tied to one quest)
    def addc(zone, title, cat, cause, evidence, effort, verdict):
        findings.append(dict(quest_id='', title=title, level='', zone=zone, category=cat, cause=cause,
                             evidence=evidence, effort=effort, verdict=verdict, blocked_follow_ups=0, _rank=0))
        stats['content_' + cat] += 1

    quests_by_cre = collections.defaultdict(set)
    for qq in Q.values():
        if qq['Method'] == 1:
            continue
        for i in range(1, 5):
            if qq[f'ReqCreatureOrGOId{i}'] > 0:
                quests_by_cre[qq[f'ReqCreatureOrGOId{i}']].add(qq['entry'])
    loot_items_by_cre = {}
    ai_events = collections.Counter(int(r[0]) for r in rows("select creature_id from creature_ai_events"))
    spells_by_cre = {int(r[0]): any(int(x) for x in r[1:]) for r in rows("select entry,spell_id1,spell_id2,spell_id3,spell_id4 from creature_template")}
    item_quests = collections.defaultdict(set)
    for qq in Q.values():
        for i in range(1, 5):
            if qq[f'ReqItemId{i}']:
                item_quests[qq[f'ReqItemId{i}']].add(qq['entry'])
    cre_loot_items = collections.defaultdict(set)
    for r in rows("select entry,item from creature_loot_template where mincountOrRef>=0"):
        cre_loot_items[int(r[0])].add(int(r[1]))
    rank_rows = rows("select entry,name,`rank`,loot_id,script_name,ai_name,spell_list_id,level_min from creature_template where `rank`=3")
    for r in rank_rows:
        e, name, loot_id, sn, ai, sl, lvl = int(r[0]), r[1], int(r[3]), r[4] or '', r[5] or '', int(r[6]), int(r[7])
        st, det = cre_avail(e)
        qrefs = sorted(quests_by_cre.get(e, ()))
        loot_n = len(cre_loot_items.get(loot_id, ())) if loot_id else 0
        dep_q = sorted({qq for itm in cre_loot_items.get(loot_id, ()) if item_source(itm)[0] is False
                        for qq in item_quests.get(itm, ())})
        spawn_maps = sorted({x[1] for x in cre_spawn.get(e, ())})
        zone = ', '.join(maps.get(m, str(m)) for m in spawn_maps) or BOSS_HINT.get(e) or (zone_name(Q[qrefs[0]]['ZoneOrSort']) if qrefs else
               (zone_name(Q[dep_q[0]]['ZoneOrSort']) if dep_q else 'unknown'))
        has_script = bool(sn) and sn != '0' and sn in cpp_registered
        has_ai = has_script or (ai == 'EventAI' and ai_events.get(e, 0) > 0) or sl > 0 or spells_by_cre.get(e)
        if st not in GOOD + ('cpp',) and (loot_n or qrefs or dep_q):
            addc(zone, f'boss {e} {name}', 'SPAWN_GAP',
                 f'rank-3 creature (level {lvl}) with {loot_n} distinct loot item(s) is never spawned or summoned',
                 det + (f'; kill objective of quests {qrefs[:6]}' if qrefs else '') +
                 (f'; its loot is required by quests {dep_q[:6]}' if dep_q else '') +
                 ('' if has_ai else f'; also no AI: ai_name={ai or "-"} with {ai_events.get(e, 0)} creature_ai_events, script_name={sn or "-"}, spell_list_id={sl}'),
                 'L' if not has_ai else 'M', 'BROKEN' if (qrefs or dep_q) else 'MISSING_CONTENT')
        elif st in GOOD and not has_ai and loot_n:
            addc(zone, f'boss {e} {name}', 'SCRIPT_GAP',
                 'rank-3 creature is spawned/summoned but has no abilities (no registered script, no EventAI events, no spell list)',
                 f'{det}; ai_name={ai or "-"}, creature_ai_events={ai_events.get(e, 0)}, script_name={sn or "-"}'
                 + (' (NOT registered in C++)' if sn and sn not in cpp_registered else '') + f', spell_list_id={sl}',
                 'M', 'PARTIAL')

    # instance maps: entrance teleports and instance scripts
    at_tp = collections.defaultdict(list)
    for r in rows("select id,target_map,required_condition,required_level from areatrigger_teleport"):
        at_tp[int(r[1])].append((int(r[0]), int(r[2]), int(r[3])))
    at_map = {int(r[0]): int(r[1]) for r in rows("select id,map_id from areatrigger_template")}
    at_tp_ids = {int(r[0]) for r in rows("select id from areatrigger_teleport")}
    at_script_ids = {int(r[0]) for r in rows("select entry from scripted_areatrigger")}
    at_other = ints("select id from areatrigger_involvedrelation") | ints("select id from areatrigger_tavern") | ints("select id from areatrigger_bg_entrance")
    map_rows = rows("select entry,map_name,map_type,script_name from map_template where map_type in (1,2)")
    for r in map_rows:
        m, mname, mtype, msn = int(r[0]), r[1], int(r[2]), r[3] or ''
        ncre = sum(1 for lst in cre_spawn.values() for x in lst if x[1] == m)
        if ncre == 0:
            continue
        if not at_tp.get(m):
            portals = [str(g) for g, gg in gt.items() if gg['script'] == 'custom_dungeon_portal' and any(x[1] != m for x in go_spawn.get(g, ())) and mname.split()[0].lower() in gg['name'].lower()]
            addc(mname, f'map {m} {mname}', 'BROKEN',
                 f'{"raid" if mtype == 2 else "dungeon"} with {ncre} creature spawns has no areatrigger_teleport into it',
                 'select * from areatrigger_teleport where target_map=%d -> empty' % m +
                 (f'; entrance portal GO(s) {portals} use script_name custom_dungeon_portal, which no C++ script registers' if portals else ''),
                 'S', 'BROKEN')
        if not msn:
            addc(mname, f'map {m} {mname}', 'SCRIPT_GAP' if mtype == 2 else 'OK_SUSPICIOUS',
                 f'{"raid" if mtype == 2 else "dungeon"} has no instance script (map_template.script_name empty): no boss state, doors or encounter logic',
                 f'select script_name from map_template where entry={m} -> empty', 'L' if mtype == 2 else 'M',
                 'PARTIAL' if mtype == 2 else 'OK_SUSPICIOUS')
        elif msn not in cpp_registered:
            addc(mname, f'map {m} {mname}', 'SCRIPT_GAP', f'instance script {msn} not registered in C++', '', 'L', 'PARTIAL')
        dead = sorted(a for a, mm in at_map.items() if mm == m and a not in at_tp_ids and a not in at_script_ids and a not in at_other)
        if dead and m >= 800 or (dead and m in (35, 45, 269, 532, 814)):
            addc(mname, f'map {m} {mname}', 'OK_SUSPICIOUS',
                 f'areatrigger(s) inside the instance do nothing (no teleport, no script, no quest/tavern relation)',
                 f'areatrigger_template ids {dead}', 'S', 'OK_SUSPICIOUS')

    # areatrigger_template map vs. a GM teleport (game_tele) placed on the same spot of another map
    tele = [(int(r[0]), r[1], float(r[2]), float(r[3]), float(r[4])) for r in rows("select map,name,position_x,position_y,position_z from game_tele")]
    inst_maps = ints("select entry from map_template where map_type in (1,2)")
    for r in rows("select a.id,a.map_id,a.x,a.y,a.z,t.name,t.target_map from areatrigger_template a join areatrigger_teleport t on t.id=a.id"):
        aid, amap, x, y, z = int(r[0]), int(r[1]), float(r[2]), float(r[3]), float(r[4])
        for tm, tn, tx, ty, tz in tele:
            if amap in (0, 1) and tm != amap and tm != int(r[6]) and tm in inst_maps and (tx - x) ** 2 + (ty - y) ** 2 + (tz - z) ** 2 < 6 ** 2:
                addc(maps.get(int(r[6]), str(r[6])), f'areatrigger {aid} {r[5]}', 'OK_SUSPICIOUS',
                     f'areatrigger_template.map_id={amap}, but game_tele "{tn}" puts the same spot on map {tm} ({maps.get(tm, tm)}); '
                     'the core ignores a trigger when the player map differs from map_id (DBCStores.cpp IsPointInAreaTriggerZone)',
                     f'areatrigger_template {aid}: map {amap} ({x:.1f},{y:.1f},{z:.1f}); game_tele "{tn}": map {tm} ({tx:.1f},{ty:.1f},{tz:.1f})',
                     'S', 'VERIFY_LIVE')

    # script_name references to scripts that no C++ code registers
    for tbl, key in (('creature_template', 'entry'), ('gameobject_template', 'entry'), ('item_template', 'entry'),
                     ('spell_template', 'entry'), ('scripted_event_id', 'id')):
        byname = collections.defaultdict(list)
        for r in rows(f"select {key},script_name from {tbl} where script_name<>''"):
            if r[1] not in cpp_registered:
                byname[r[1]].append(int(r[0]))
        for n, ents in sorted(byname.items()):
            if n == '0':
                continue
            live = []
            if tbl == 'creature_template':
                live = [x for x in ents if cre_avail(x)[0] in GOOD]
            elif tbl == 'gameobject_template':
                live = [x for x in ents if go_avail(x)[0] in GOOD]
            addc('script registry', f'{tbl}.script_name={n}', 'SCRIPT_GAP',
                 f'script_name "{n}" is referenced by {len(ents)} {tbl} row(s) but no compiled C++ script registers it; the object runs without its script',
                 f'entries {ents[:8]}' + (f'; spawned: {live[:8]}' if live else '') +
                 ('; AddSC not called: ' + ','.join(sorted({x[1] for x in cpp_all_names[n]})) if n in cpp_all_names else ''),
                 'M', 'PARTIAL')
    # hand-verified owner cases (twow-repo#408); the queries in `evidence` reproduce them
    addc('Timbermaw Hold', 'braziers 300602-300605 / Barrier of Ursol 300606', 'SCRIPT_GAP',
         'extinguishing the four braziers does nothing: no gameobject_scripts, no quest relation, no event, no instance script; '
         'nothing opens the Barrier of Ursol, and Ursol (62947) behind it is never spawned',
         'gameobject_template 300602-300605: type 2 (questgiver), data0 lock 1666, flags 32, script_name "0"; item 42234 Essence of '
         'Purification casts 34764 "Dowses a brazier in Timbermaw Hold" = effect 59 OPEN_LOCK_ITEM on a GO; '
         'select * from gameobject_scripts where id in (398063,398064,398065,398066) -> empty; '
         'Barrier 300606: type 0 door, data0 startOpen=1, flags 48 (NO_INTERACT|NODESPAWN), spawn state 1; '
         'map_template 819 script_name empty; creature 62947 Ursol: 0 spawns, 0 summons, 0 creature_ai_events',
         'L', 'BROKEN')
    addc('Tower of Karazhan', 'map 814 "Karazhan Outland" section', 'BROKEN',
         'no player path into the second part of Tower of Karazhan: the areatriggers next to Echo of Medivh have no teleport, and nothing else '
         'teleports into the section where Sanv Tas\'dal, Kruul and Rupturan stand; the final boss Mephistroth (93333) is not spawned at all',
         'areatrigger_template 5349 (-11168,-1636,278) and 5350 (-11233,-1688,290) on map 814: no areatrigger_teleport, no scripted_areatrigger; '
         'game_tele 934 "karaoutland" = map 814 (-6078.9,-2395.5,49.3); bosses 59981/59991/59961 spawned at x -6248..-7190; '
         'no script command 6 / spell_target_position / C++ TeleportTo targets map 814',
         'M', 'BROKEN')
    self_stats = dict(stats=stats, quests=len(Q))
    json.dump(dict(stats=stats, quests=len(Q), verdicts=verdicts), open(ARGS.json, 'w'), indent=1) if ARGS.json else None
    with open(ARGS.out, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['quest_id', 'title', 'level', 'zone', 'category', 'cause', 'evidence', 'effort', 'verdict', 'blocked_follow_ups'],
                           extrasaction='ignore', lineterminator='\n')
        w.writeheader()
        for fd in sorted(findings, key=lambda x: (x['quest_id'] != '', x['zone'], str(x['quest_id']).zfill(8), x['_rank'])):
            w.writerow(fd)
    print(json.dumps(dict(stats=stats, quests=len(Q)), indent=1))


if __name__ == '__main__':
    main()
