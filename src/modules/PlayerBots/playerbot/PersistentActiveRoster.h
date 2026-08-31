#pragma once

#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace ai
{
namespace roster
{
using Sha256 = std::array<uint8_t, 32>;

enum class RuntimeState
{
    DISABLED,
    LOADING,
    STARTING,
    HEALTHY,
    DEGRADED,
    INVALID_FAIL_CLOSED,
    SHUTTING_DOWN,
    STOPPED
};

enum class OperationType
{
    INITIALIZE,
    EXPAND,
    ADD,
    REMOVE,
    REPLACE,
    ROLLBACK
};

enum class AdminTransport
{
    LOCAL_CONSOLE,
    REMOTE_ADMIN,
    GAME_CHAT
};

struct ReplaceEntry
{
    uint32_t ordinal = 0;
    uint32_t oldGuid = 0;
    uint32_t newGuid = 0;
};

struct AdminRequest
{
    uint32_t schemaVersion = 1;
    std::string operationId;
    OperationType operationType = OperationType::INITIALIZE;
    uint64_t expectedCurrentVersionId = 0;
    bool hasExpectedCurrentVersionId = false;
    std::string actor;
    std::string reason;
    uint32_t requestedTargetCount = 0;
    std::vector<uint32_t> add;
    std::vector<uint32_t> remove;
    std::vector<ReplaceEntry> replace;
    uint64_t rollbackVersionId = 0;
    bool hasRollbackVersionId = false;
};

struct Snapshot
{
    uint64_t versionId = 0;
    std::vector<uint32_t> guids;
    Sha256 sha256{};
};

struct OperationRecord
{
    std::string operationId;
    Sha256 requestSha256{};
    std::string resultCode;
    uint64_t resultingVersionId = 0;
    Sha256 beforeSha256{};
    Sha256 afterSha256{};
};

struct ApplyResult
{
    bool accepted = false;
    bool replayed = false;
    bool restartRequired = false;
    std::string code;
    uint64_t versionId = 0;
    Sha256 requestSha256{};
    Sha256 beforeSha256{};
    Sha256 afterSha256{};
};

struct RuntimeStatus
{
    RuntimeState state = RuntimeState::DISABLED;
    uint64_t rosterVersionId = 0;
    Sha256 rosterSha256{};
    uint32_t rosterTarget = 0;
    uint32_t rosterAvailable = 0;
    uint32_t rosterOnline = 0;
    std::vector<std::pair<uint32_t, std::string>> diagnostics;
};

struct RuntimeBehaviorPolicy
{
    bool clearExpiredValues = true;
    bool normalAiTicks = true;
    bool normalStrategyMaintenance = true;
    bool travelAndIdleBehavior = true;
    bool revive = true;
    bool sessionMaintenance = true;
    bool scheduleNextUpdate = true;
    bool leaseLogout = true;
    bool populationRotation = true;
    bool randomizeProgression = true;
    bool randomStrategyReassignment = true;
    bool randomTeleport = true;
    bool automaticGroupRemoval = true;
};

class Store
{
public:
    virtual ~Store() = default;
    virtual bool VerifySchema(std::string& error) = 0;
    virtual bool LoadCurrent(Snapshot& snapshot, bool& found, std::string& error) = 0;
    virtual bool LoadVersion(uint64_t versionId, Snapshot& snapshot, bool& found, std::string& error) = 0;
    virtual bool FindOperation(std::string const& operationId, OperationRecord& record, bool& found, std::string& error) = 0;
    virtual bool Commit(AdminRequest const& request, std::string const& canonicalRequest, Sha256 const& requestSha256,
        Snapshot const& before, bool hasBefore, Snapshot& after, std::string const& resultCode,
        bool& replayed, OperationRecord& replayRecord, std::string& error) = 0;
};

std::string RuntimeStateName(RuntimeState state);
std::string OperationTypeName(OperationType type);
bool ParseAdminRequest(std::string const& bytes, AdminRequest& request, std::string& error);
bool SerializeAdminRequest(AdminRequest const& request, std::string& bytes, std::string& error);
bool SerializeSnapshot(std::vector<uint32_t> const& guids, std::string& bytes, std::string& error);
Sha256 Hash(std::string const& bytes);
std::string Hex(Sha256 const& hash);
bool ParseHex(std::string const& text, Sha256& hash);
bool ReadCanonicalAdminRequestFile(std::string const& fileName, std::string& bytes, std::string& error);
bool IsRosterAdminTransportAllowed(AdminTransport transport);
std::string EvaluateRosterApplyGate(bool enabled, bool servicePresent, bool maintenanceMode,
    uint32_t reportedOnline, bool discoveredOnline);
std::string EvaluateRosterAccountAdmission(bool characterExists, bool accountExists, bool rndbotStock,
    bool banned, bool loginRecordExists, bool accountActive, uint32_t accountLockFlags,
    bool registeredSession);
RuntimeBehaviorPolicy EvaluateRuntimeBehaviorPolicy(bool persistentRosterMember, bool grouped);

class Service
{
public:
    explicit Service(std::unique_ptr<Store> store);

    bool Start(bool enabled, bool asyncLogin, std::string& error);
    void Stop();
    ApplyResult Apply(std::string const& canonicalRequest);
    void RecordAvailable(uint32_t guid);
    void RecordPending(uint32_t guid);
    void RecordUnavailable(uint32_t guid, std::string const& diagnostic);
    void RecordOnline(uint32_t guid);

    bool IsMember(uint32_t guid) const;
    bool CanAutomaticLogout(uint32_t guid) const;
    bool CanAutomaticDelete(uint32_t guid) const;
    bool CanAutomaticReplace(uint32_t guid) const;
    bool CanRotationMutate(uint32_t guid) const;
    RuntimeStatus Status() const;
    RuntimeState State() const { return state_; }
    std::vector<uint32_t> const& Desired() const { return current_.guids; }
    std::set<uint32_t> const& Unavailable() const { return unavailable_; }
    std::string const& LastDiagnostic() const { return lastDiagnostic_; }
    uint64_t CurrentVersionId() const { return current_.versionId; }

private:
    bool ValidateSnapshot(Snapshot& snapshot, std::string& error) const;
    bool BuildAfter(AdminRequest const& request, Snapshot& after, std::string& error);
    ApplyResult Reject(std::string const& code, Sha256 const& requestSha256 = Sha256{});

    std::unique_ptr<Store> store_;
    RuntimeState state_ = RuntimeState::DISABLED;
    Snapshot current_;
    bool hasCurrent_ = false;
    bool storeReady_ = false;
    std::set<uint32_t> members_;
    std::set<uint32_t> available_;
    std::set<uint32_t> unavailable_;
    std::set<uint32_t> online_;
    std::map<uint32_t, std::string> diagnostics_;
    std::string lastDiagnostic_;
};
}
}
