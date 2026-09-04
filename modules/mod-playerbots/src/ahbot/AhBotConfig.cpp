
#include "AhBotConfig.h"
#include "SystemConfig.h"
#include "Log.h"
std::vector<std::string> split(const std::string &s, char delim);

INSTANTIATE_SINGLETON_1(AhBotConfig);

AhBotConfig::AhBotConfig()
{
}

template <class T>
void LoadSet(std::string value, T &res)
{
    std::vector<std::string> ids = split(value, ',');
    for (std::vector<std::string>::iterator i = ids.begin(); i != ids.end(); i++)
    {
        uint32 id = atoi((*i).c_str());
        if (!id)
            continue;

        res.insert(id);
    }
}

bool AhBotConfig::Initialize()
{
    // Same problem PlayerbotAIConfig::Initialize() already solved: SYSCONFDIR is
    // baked in at configure time, so a server installed anywhere other than the
    // CMAKE_INSTALL_PREFIX it was built with silently fails to find this file and
    // switches the feature off. That is invisible in a container, where the build
    // and run prefixes differ by construction. Look next to the mangosd.conf that
    // is actually in use first, then fall back to the compiled-in path.
    std::string ahbotConfigFile;

    std::string const mainConfig = sConfig.GetFilename();
    size_t const slash = mainConfig.find_last_of("/\\");
    if (slash != std::string::npos)
        ahbotConfigFile = mainConfig.substr(0, slash + 1) + "ahbot.conf";

    if (ahbotConfigFile.empty() || !config.SetSource(ahbotConfigFile, "AHBot_"))
    {
        if (!config.SetSource(SYSCONFDIR"ahbot.conf", "AHBot_"))
        {
            sLog.outString("AhBot is Disabled. No configuration file at %s%s%s.",
                ahbotConfigFile.empty() ? "" : ahbotConfigFile.c_str(),
                ahbotConfigFile.empty() ? "" : " or ",
                SYSCONFDIR"ahbot.conf");
            return false;
        }
    }

    sLog.outString("AhBot configuration read from %s.", config.GetFilename().c_str());

    enabled = config.GetBoolDefault("AhBot.Enabled", true);

    if (!enabled)
        sLog.outString("AhBot is Disabled in ahbot.conf");

    guid = (uint64)config.GetIntDefault("AhBot.GUID", 0);
    updateInterval = config.GetIntDefault("AhBot.UpdateIntervalInSeconds", 900);
    historyDays = config.GetIntDefault("AhBot.History.Days", 30);
    itemBuyMinInterval = config.GetIntDefault("AhBot.ItemBuyMinInterval", 600);
    itemBuyMaxInterval = config.GetIntDefault("AhBot.ItemBuyMaxInterval", 7200);
    itemSellMinInterval = config.GetIntDefault("AhBot.ItemSellMinInterval", 600);
    itemSellMaxInterval = config.GetIntDefault("AhBot.ItemSellMaxInterval", 7200);
    maxSellInterval = config.GetIntDefault("AhBot.MaxSellInterval", 3600 * 8);
    alwaysAvailableMoney = config.GetIntDefault("AhBot.AlwaysAvailableMoney", 200000);
    priceMultiplier = config.GetFloatDefault("AhBot.PriceMultiplier", 1.0f);
    defaultMinPrice = config.GetIntDefault("AhBot.DefaultMinPrice", 20);
    maxItemLevel = config.GetIntDefault("AhBot.MaxItemLevel", 199);
    maxRequiredLevel = config.GetIntDefault("AhBot.MaxRequiredLevel", 80);
    stackReducePrice = config.GetIntDefault("AhBot.StackReducePrice", 1000000);
    priceQualityMultiplier = config.GetFloatDefault("AhBot.PriceQualityMultiplier", 1.0f);
    underPriceProbability = config.GetFloatDefault("AhBot.UnderPriceProbability", 0.05f);
    LoadSet<std::set<uint32> >(config.GetStringDefault("AhBot.IgnoreItemIds", "49283,52200,8494,6345,6891,2460,37164,34835,17,2248"), ignoreItemIds);
    LoadSet<std::set<uint32> >(config.GetStringDefault("AhBot.IgnoreVendorItemIds", "755,858,4592,4593,1710,3827,2455,3385"), ignoreVendorItemIds);
    sendmail = config.GetBoolDefault("AhBot.SendMail", true);


    return enabled;
}
