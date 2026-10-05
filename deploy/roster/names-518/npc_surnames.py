#!/usr/bin/env python3
"""#518: surname candidates from NPC names of each playable race (owner: "bedien dich an den namen der npcs
der rassen"). Read-only inputs: client DBCs CreatureDisplayInfo/-Extra (display -> race, sex) and a
creature_template export from the disposable world DB (entry, name, subname, display_id1..4).

    npc_surnames.py CreatureDisplayInfo.dbc CreatureDisplayInfoExtra.dbc creatures.tsv > npc-surnames.tsv

Output: race, surname, count, example NPC. Only two-word names "First Last" with a playable display race;
the last word is the candidate. Job and creature words (Guard, Merchant, ...) are dropped."""
import struct
import sys
from collections import defaultdict


def dbc(path):
    data = open(path, "rb").read()
    magic, nrec, nfield, rsize, ssize = struct.unpack_from("<4s4I", data)
    if magic != b"WDBC":
        sys.exit(f"{path}: not WDBC")
    return [struct.unpack_from(f"<{nfield}I", data, 20 + i * rsize) for i in range(nrec)]


STOP = {w.lower() for w in """Guard Guardian Merchant Trainer Vendor Peon Grunt Footman Soldier Citizen Worker Mage
Priest Warrior Warlock Hunter Rogue Druid Shaman Paladin Patrol Protector Sentinel Defender Watcher Scout Peasant
Miner Farmer Militia Recruit Cadet Initiate Apprentice Acolyte Captain Sergeant Lieutenant Commander General Marshal
Champion Knight Squire Archer Rifleman Mountaineer Cleric Battlemage Sorcerer Necrolyte Deathguard Executioner
Courier Messenger Innkeeper Banker Auctioneer Butcher Baker Cook Fisherman Tailor Smith Blacksmith Armorer Weaponsmith
Bowyer Gunsmith Engineer Alchemist Herbalist Enchanter Leatherworker Skinner Stablemaster Gryphon Wind Bat Flight
Master Handler Keeper Elder Spirit Ghost Zombie Skeleton Ghoul Wolf Bear Boar Raptor Spider Scorpid Crocolisk Murloc
Kobold Gnoll Trogg Harpy Centaur Quilboar Furbolg Satyr Naga Ogre Troll Orc Dwarf Gnome Human Tauren Undead Elf
Goblin Bruiser Thug Bandit Brigand Pirate Smuggler Thief Assassin Cultist Zealot Fanatic Servant Slave Prisoner
Child Kid Orphan Matron Lady Lord King Queen Prince Princess Baron Duke Emissary Ambassador Envoy Agent Spy Officer
Warden Jailor Sentry Lookout Raider Marauder Reaver Berserker Brute Shadowcaster Witch Seer Mystic Oracle Prophet
Augur Diviner Conjurer Illusionist Summoner Sage Scholar Researcher Explorer Survivor Refugee Pilgrim Traveler
Wanderer Hermit Exile Outcast Renegade Deserter Defector Veteran Instructor Supervisor Foreman Overseer Taskmaster
Quartermaster Steward Attendant Retainer Bodyguard Escort Clerk Scribe Librarian Curator Archivist Historian""".split()}
PLAYABLE = set(range(1, 11))


def main():
    cdi, extra, creatures = sys.argv[1:4]
    ext = {r[0]: (r[1], r[2]) for r in dbc(extra)}
    display = {r[0]: ext.get(r[3]) for r in dbc(cdi) if r[3]}
    rows = []
    for line in open(creatures, encoding="utf-8"):
        entry, name, subname, *ids = line.rstrip("\n").split("\t")
        parts = name.split()
        if len(parts) != 2 or not all(p.isalpha() and p[0].isupper() and p[1:].islower() for p in parts):
            continue
        race = next((display[int(i)][0] for i in ids if i.isdigit() and int(i) in display and display[int(i)]), None)
        if race not in PLAYABLE or parts[1].lower() in STOP or parts[0].lower() in STOP:
            continue
        rows.append((race, parts[0], parts[1], name, entry))
    # a first word that starts 3+ names is a clan/faction prefix ("Shadowforge Ambusher"), a last word with
    # 4+ different first words is a generic noun: both are no personal surnames
    first_freq = defaultdict(set)
    last_firsts = defaultdict(set)
    for race, first, last, name, entry in rows:
        first_freq[first].add(last)
        last_firsts[last].add(first)
    found = defaultdict(lambda: [0, ""])
    for race, first, last, name, entry in rows:
        if len(first_freq[first]) >= 3 or len(last_firsts[last]) >= 4:
            continue
        rec = found[(race, last)]
        rec[0] += 1
        rec[1] = rec[1] or f"{name} ({entry})"
    print("race\tsurname\tcount\texample")
    for (race, surname), (count, ex) in sorted(found.items()):
        print(f"{race}\t{surname}\t{count}\t{ex}")


if __name__ == "__main__":
    main()
