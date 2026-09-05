#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// ExternalLLMBridgeService is deliberately a value-only boundary.  Player,
// WorldSession and PlayerbotAI objects are resolved again on the world thread;
// none of their addresses can enter the I/O worker.
class ExternalLLMBridgeService
{
public:
    static constexpr std::uint32_t BotGuid = 18281;
    static constexpr std::uint32_t ReadyTimeoutMs = 35000;
    static constexpr std::uint32_t StatusPollIntervalMs = 100;
    static constexpr std::uint32_t ShutdownOverallTimeoutMs = 40000;
    static constexpr std::size_t StderrDiagnosticCapBytes = 65536;
    static constexpr std::size_t StdoutNdjsonLineCapBytes = 16384;
    static constexpr std::size_t OutstandingRouteCapacity = 3;
    static constexpr std::size_t CompletionCapacity = 3;

    enum class State
    {
        Disabled,
        Starting,
        Ready,
        LedgerExhausted,
        ProtocolFailed,
        ChildFailed,
        ShuttingDown,
        Stopped
    };

    enum class SubmitResult
    {
        Admitted,
        LocallyRejected,
        LocallyRejectedLedgerExhausted
    };

    struct SessionFingerprint
    {
        std::uint64_t guid = 0;
        std::uint32_t accountId = 0;
        std::int64_t loginTime = 0;
        std::uint64_t generation = 0;
        std::string name;
        bool active = false;
    };

    static ExternalLLMBridgeService& Instance();

    // World-thread API. Start never searches PATH and never starts through a
    // shell. It is a no-op while the separately configured feature is off.
    bool Start();
    SubmitResult TrySubmit(std::uint64_t botGuid, std::uint64_t targetGuid,
        std::string const& targetName, std::string const& message);
    void UpdateWorld();
    void ObserveSession(std::uint64_t guid, std::uint32_t accountId,
        std::int64_t loginTime, std::string const& name);
    void InvalidateSession(std::uint64_t guid);
    void Shutdown();

    State GetState() const;
    bool IsReadyForAdmission() const;

    ExternalLLMBridgeService(ExternalLLMBridgeService const&) = delete;
    ExternalLLMBridgeService& operator=(ExternalLLMBridgeService const&) = delete;

private:
#ifdef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
    friend class ExternalLLMBridgeTestHarness;
#endif
    ExternalLLMBridgeService();
    ~ExternalLLMBridgeService();

    class Impl;
    std::unique_ptr<Impl> m_impl;
};
