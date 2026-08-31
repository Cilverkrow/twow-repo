#include "ModuleSlots.h"
#include "Log.h"

#include <cstring>
#include <mutex>

// The registry behind ClaimModuleSlot. Deliberately tiny: an array of names and
// a count, guarded by a mutex that is contended exactly once per module per
// process, because callers cache the result in a function-local static.
namespace
{
    std::mutex g_slotMutex;
    char const* g_slotOwners[MODULE_SLOT_MAX] = {};
    uint8 g_slotCount = 0;
}

uint8 ClaimModuleSlot(char const* owner)
{
    if (!owner || !*owner)
    {
        sLog.outError("ClaimModuleSlot called without an owner name; refusing.");
        return MODULE_SLOT_MAX;
    }

    std::lock_guard<std::mutex> guard(g_slotMutex);

    // Idempotent: a claim made from a header that several translation units
    // include must not consume a slot each time.
    for (uint8 i = 0; i < g_slotCount; ++i)
        if (std::strcmp(g_slotOwners[i], owner) == 0)
            return i;

    if (g_slotCount >= MODULE_SLOT_MAX)
    {
        // Returning an in-range index here would hand the caller a slot another
        // module already owns, and the resulting corruption would surface far
        // from the cause. Out of range makes Get/SetModuleSlot no-op instead.
        sLog.outError("Module slots exhausted (%u in use) claiming '%s'. Raise MODULE_SLOT_MAX.",
            uint32(MODULE_SLOT_MAX), owner);
        return MODULE_SLOT_MAX;
    }

    uint8 const slot = g_slotCount++;
    g_slotOwners[slot] = owner;
    sLog.outString("Module slot %u claimed by '%s'.", uint32(slot), owner);
    return slot;
}

char const* GetModuleSlotOwner(uint8 slot)
{
    std::lock_guard<std::mutex> guard(g_slotMutex);
    return slot < g_slotCount ? g_slotOwners[slot] : nullptr;
}

uint8 GetClaimedModuleSlotCount()
{
    std::lock_guard<std::mutex> guard(g_slotMutex);
    return g_slotCount;
}
