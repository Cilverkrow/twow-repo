#include <cstdint>
#include <future>
#include <mutex>
#include <string>
#include <vector>

class PlayerbotLLMInterface
{
public:
    struct DebugResult
    {
        bool success = false;
        std::string message;
    };

    enum class DebugRequestStartStatus
    {
        Started,
        Busy,
        ResultReady,
        Disabled,
        Failed
    };

    enum class DebugResultStatus
    {
        None,
        Pending,
        Ready,
        NotOwner
    };

    PlayerbotLLMInterface() {}
    static std::string SanitizeForJson(const std::string& input);

    static std::string Generate(const std::string& prompt, int timeOutSeconds, int maxGenerations, std::vector<std::string>& debugLines);

    static bool BuildDebugRequest(const std::string& requestTemplate, const std::string& prompt, uint32_t maxPromptBytes, std::string& request, std::string& error);
    static DebugRequestStartStatus StartDebugRequest(const std::string& request, uint32_t accountId, std::string& error);
    static DebugResultStatus TakeDebugResult(uint32_t accountId, DebugResult& result);

    static std::vector<std::string> ParseResponse(const std::string& response, const std::string& startPattern, const std::string& endPattern, const std::string& deletePattern, const std::string& splitPattern, std::vector<std::string>& debugLines);

    static void LimitContext(std::string& context, int currentLength);
private:
    static DebugResult GenerateDebugResponse(const std::string& request, const std::string& schemeHost, const std::string& path, const std::string& apiKey, uint32_t timeoutSeconds);

    std::mutex debugRequestMutex;
    // Retaining the async shared state here prevents a temporary future destructor
    // from waiting in the World update thread. The future is destroyed before the
    // mutex because members are destroyed in reverse declaration order.
    std::future<DebugResult> debugRequestFuture;
    uint32_t debugRequestAccountId = 0;
};

#define sPlayerbotLLMInterface MaNGOS::Singleton<PlayerbotLLMInterface>::Instance()

