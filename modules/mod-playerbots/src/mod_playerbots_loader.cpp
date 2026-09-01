// Module entry point for mod-playerbots.
//
// Deliberately empty. Every other module registers its behaviour here by
// constructing script objects; this one does not, and that is not an omission
// waiting to be filled in.
//
// The playerbots subsystem is vendored from ike3's cmangos tree and is wired
// into the core the way that tree expects: free functions the core calls
// directly -- World::InitPlayerbotsAtStartup(), the .bot/.rndbot/.ahbot/.perfmon
// chat commands registered in Chat.cpp, and the BotActionLog_* diagnostic probes
// in Unit.cpp and Spell.cpp. src/game/PlayerbotStubs.cpp supplies no-op versions
// of all of them when this module is disabled, so the core links either way.
//
// Converting those call sites to script hooks was considered and rejected: six
// of the eleven symbols are logging probes, and six new entries in
// ScriptObjects.h to relocate logging buys nothing. The promotion to a module
// was about the build system -- one way to add a module instead of two -- and
// it is complete without touching the runtime seam.
//
// The loader function itself still has to exist: modules/CMakeLists.txt
// generates a call to Add<name>Scripts() for every enabled module, and the link
// fails without a definition.

void Addmod_playerbotsScripts()
{
}
