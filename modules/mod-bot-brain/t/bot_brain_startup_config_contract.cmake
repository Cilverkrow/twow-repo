if(NOT DEFINED BB_LOADER OR NOT EXISTS "${BB_LOADER}")
  message(FATAL_ERROR "BB_LOADER does not name the module loader source")
endif()

file(READ "${BB_LOADER}" loader_source)

string(FIND "${loader_source}" "void OnAfterConfigLoad(bool /*reload*/) override" reload_start)
string(FIND "${loader_source}" "void OnStartup() override" startup_start)
if(reload_start LESS 0 OR startup_start LESS 0 OR startup_start LESS_EQUAL reload_start)
  message(FATAL_ERROR "BotBrain config/startup hooks are missing or out of order")
endif()

math(EXPR reload_length "${startup_start} - ${reload_start}")
string(SUBSTRING "${loader_source}" ${reload_start} ${reload_length} reload_body)
string(FIND "${reload_body}" "botbrain::LoadConfig();" reload_load)
string(FIND "${reload_body}" "botbrain::RefreshDialogueSettings();" reload_refresh)
if(reload_load LESS 0 OR reload_refresh LESS 0 OR reload_refresh LESS_EQUAL reload_load)
  message(FATAL_ERROR "OnAfterConfigLoad must refresh dialogue after loading config")
endif()

string(SUBSTRING "${loader_source}" ${startup_start} -1 startup_body)
string(FIND "${startup_body}" "botbrain::LoadConfig();" startup_load)
string(FIND "${startup_body}" "botbrain::RefreshDialogueSettings();" startup_refresh)
string(FIND "${startup_body}" "botbrain::RegisterBotBrainContexts();" startup_register)
string(FIND "${startup_body}" "if (!botbrain::GetSettings().enabled)" startup_enabled_check)

if(startup_load LESS 0 OR startup_refresh LESS 0 OR startup_register LESS 0 OR startup_enabled_check LESS 0)
  message(FATAL_ERROR "OnStartup is missing a required BotBrain lifecycle operation")
endif()

if(NOT startup_load LESS startup_refresh OR
   NOT startup_refresh LESS startup_register OR
   NOT startup_register LESS startup_enabled_check)
  message(FATAL_ERROR
    "OnStartup must load config, refresh dialogue, register contexts, then check BotBrain.Enable")
endif()
