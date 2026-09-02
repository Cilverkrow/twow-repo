#include "BotBrainConfig.h"

#include "Config/Config.h"
#include "Log.h"

#include <algorithm>

namespace botbrain
{
    namespace
    {
        Settings g_config;

        uint32_t ReadUint(char const* key, uint32_t fallback, uint32_t min, uint32_t max)
        {
            int32 const raw = sConfig.GetIntDefault(key, static_cast<int32>(fallback));
            if (raw < static_cast<int32>(min))
                return min;
            if (raw > static_cast<int32>(max))
                return max;
            return static_cast<uint32_t>(raw);
        }
    }

    Settings const& GetSettings()
    {
        return g_config;
    }

    void LoadConfig()
    {
        Settings cfg;
        cfg.enabled = sConfig.GetBoolDefault("BotBrain.Enable", false);
        cfg.endpoint = sConfig.GetStringDefault("BotBrain.Endpoint", "http://127.0.0.1:8085");
        cfg.timeoutMs = ReadUint("BotBrain.TimeoutMs", 750, 50, 10000);
        cfg.intervalMs = ReadUint("BotBrain.IntervalMs", 15000, 1000, 3600000);
        cfg.backoffMs = ReadUint("BotBrain.BackoffMs", 60000, 1000, 3600000);
        cfg.maxInFlight = ReadUint("BotBrain.MaxInFlight", 8, 1, 256);
        cfg.maxPois = ReadUint("BotBrain.MaxPois", 24, 1, 512);
        cfg.poiTableTtlMs = ReadUint("BotBrain.PoiTableTtlMs", 120000, 1000, 3600000);
        cfg.logApplied = sConfig.GetBoolDefault("BotBrain.LogAppliedIntents", true);

        g_config = cfg;

        if (g_config.enabled)
            sLog.outString("mod-bot-brain: enabled, endpoint %s, interval %ums, timeout %ums",
                g_config.endpoint.c_str(), g_config.intervalMs, g_config.timeoutMs);
    }
}
