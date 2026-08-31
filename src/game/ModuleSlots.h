#ifndef MODULE_SLOTS_H
#define MODULE_SLOTS_H

#include "Common.h"

// Per-player storage slots for modules.
//
// A module that has to hang state off a Player claims a slot and reaches it
// through Player::GetModuleSlot / SetModuleSlot. The core allocates the space
// and never reads it: what a slot points at, who owns it and when it is freed
// are entirely the module's business.
//
// Slots are claimed at RUNTIME, by name:
//
//     inline uint8 MyModuleSlot()
//     {
//         static uint8 const slot = ClaimModuleSlot("mymodule.state");
//         return slot;
//     }
//
// The function-local static means the claim happens once and every later read
// is a plain load, so the access cost is the same fixed-offset array index it
// always was. That matters: the population module reads its slot on every tick
// of every driven character, where a hash lookup would show.
//
// This used to be a compile-time enum, which had two problems. Claiming a slot
// meant editing this header - and this header is included by Player.h, so a
// one-line addition rebuilt 1060 of the 1171 translation units. It also meant
// every module author edited the same three lines, which is a merge conflict by
// construction. Neither is true now: a module claims its slot in its own file
// and the core never learns the name.
//
// Claiming the same name twice returns the same index, so a claim in a header
// used by several translation units is safe.

// Maximum number of slots. Raising it is a core change and rebuilds the world;
// it is sized with room to spare so that should not be needed often.
uint8 constexpr MODULE_SLOT_MAX = 8;

// Returns a stable slot index for `owner`, allocating one on first use.
// `owner` should be namespaced, e.g. "playerbots.ai". Exhausting the slots is a
// programming error and is reported rather than silently returning a slot that
// another module already owns.
uint8 ClaimModuleSlot(char const* owner);

// Introspection for diagnostics: who owns which slot, and how many are taken.
char const* GetModuleSlotOwner(uint8 slot);
uint8 GetClaimedModuleSlotCount();

#endif
