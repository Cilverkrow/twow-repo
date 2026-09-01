/*
 * Test-support prelude for dungeon_clear_tests_fast. Not compiled into the
 * server.
 *
 * The module's own headers were written against AzerothCore, where the core
 * enum and map-format names below are reachable through <that core's>
 * DBCEnums.h / MapDefines.h. On this core they are not: `Difficulty` and
 * DUNGEON_DIFFICULTY_NORMAL live in SharedDefines.h, and MmapTileHeader /
 * MMAP_MAGIC / MMAP_VERSION / NAV_GROUND live in Maps/MoveMapSharedDefines.h.
 *
 * The shipping module never notices, because modules/mod-dungeon-clear.cmake
 * force-includes src/AcCompat.h into every module translation unit, and that
 * header opens by pulling in the whole core - Player.h, Map.h, ObjectMgr,
 * the playerbot tree. Force-including AcCompat.h here would make the fast test
 * target depend on libgame and libplayerbots, which is precisely the dependency
 * this target exists to avoid.
 *
 * So this is AcCompat.h's opening lines, cut down to the four headers the
 * hermetic module headers actually need. All four are leaves: none of them
 * reaches core code, only core declarations, so the target still links against
 * gtest and Detour alone.
 *
 * If a test starts failing to compile on a missing core name, the fix is to
 * decide whether that name is a leaf declaration (add its header here) or a
 * live-server dependency (the test belongs in dungeon_clear_tests_full).
 */

#ifndef DC_TEST_PRELUDE_H
#define DC_TEST_PRELUDE_H

#include "Platform/Define.h"
#include "Common.h"

// Difficulty, DUNGEON_DIFFICULTY_NORMAL and the rest of the shared enums that
// the module's headers expect AzerothCore's DBCEnums.h to have supplied.
#include "SharedDefines.h"

// MmapTileHeader, MMAP_MAGIC, MMAP_VERSION and the NAV_* area flags, read by
// the nav harness when it loads a sliced mmaps tile. Pulls in Detour and
// nothing else.
#include "Maps/MoveMapSharedDefines.h"

// WorldTimer, behind the two free functions below.
#include "Timer.h"

// --- the handful of AcCompat.h shims the hermetic headers reach -------------
//
// Copied from src/AcCompat.h (the lines noted), NOT re-derived. Only the shims
// that depend on nothing heavier than the headers above are here; everything
// else in AcCompat.h needs Player/Map/ObjectMgr and belongs to the full suite.
// These would collide with AcCompat.h's own definitions if both were included
// in one translation unit, which is why the fast target force-includes this
// header INSTEAD of AcCompat.h, never as well as.

// AcCompat.h:136-140 — AzerothCore spells these as free functions; here they
// are static members of WorldTimer. DcApproachState.h calls getMSTimeDiff.
inline uint32 getMSTime() { return WorldTimer::getMSTime(); }
inline uint32 getMSTimeDiff(uint32 oldMSTime, uint32 newMSTime)
{
    return WorldTimer::getMSTimeDiff(oldMSTime, newMSTime);
}

// AcCompat.h:165 — 1.12 locks open by item or by skill. AzerothCore adds a
// spell key type; no lock on this core carries one, so the value exists and
// never matches. DcDoorPolicy.h compares against it.
constexpr uint8 LOCK_KEY_SPELL = 3;

#endif // DC_TEST_PRELUDE_H
