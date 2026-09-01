# Why these headers stay in the baseline

The baseline is a ratchet, not an approval list. Every entry needs a reason, and
"we have not got to it yet" is not one — those get fixed instead.

## Deliberate fragments, included from exactly one place

- **`Anticheat/AnticheatChatCommands.h`** — its first line says
  `//This file included in Anticheat.h`. It is a set of `static ChatCommand`
  tables, not a header: making it standalone would mean giving every includer a
  private copy of the tables.
- **`Movement/MovementGeneratorImpl.h`**, **`Movement/spline/spline.impl.h`** —
  template definitions split out of their own headers, which include them at the
  bottom. Standard practice; the name says so.

## A real defect, tracked separately

- **`Anticheat/WardenAnticheat/{Warden,WardenMac,WardenMgr,WardenWin}.h`** —
  `WardenMgr.h:41` declares `enum WardenActions Action;` and **`WardenActions` is
  not defined anywhere in the tree.** It appears in exactly four places, all of
  them uses: this member, two casts in `Warden.cpp` and `WardenMgr.cpp`. The
  build tolerates it today; it should not, and the fix is to find out what the
  penalty values were meant to be — not to invent them, since they drive
  anticheat punishment. See REF-014.
