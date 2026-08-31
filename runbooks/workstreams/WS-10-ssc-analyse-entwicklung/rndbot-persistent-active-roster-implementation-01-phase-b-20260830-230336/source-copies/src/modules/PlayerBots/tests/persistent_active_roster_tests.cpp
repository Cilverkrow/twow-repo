#include "PersistentActiveRoster.h"

#include <cstdlib>
#include <iostream>
#include <map>
#include <memory>
#include <string>

using namespace ai::roster;

namespace
{
struct FakeData
{
    bool hasCurrent = false;
    Snapshot current;
    std::map<uint64_t, Snapshot> versions;
    std::map<std::string, OperationRecord> operations;
    bool failCommit = false;
};

class FakeStore final : public Store
{
public:
    explicit FakeStore(std::shared_ptr<FakeData> data) : data_(std::move(data)) {}

    bool LoadCurrent(Snapshot& snapshot, bool& found, std::string&) override
    {
        found = data_->hasCurrent;
        if (found) snapshot = data_->current;
        return true;
    }
    bool LoadVersion(uint64_t versionId, Snapshot& snapshot, bool& found, std::string&) override
    {
        auto it = data_->versions.find(versionId);
        found = it != data_->versions.end();
        if (found) snapshot = it->second;
        return true;
    }
    bool FindOperation(std::string const& operationId, OperationRecord& record, bool& found, std::string&) override
    {
        auto it = data_->operations.find(operationId);
        found = it != data_->operations.end();
        if (found) record = it->second;
        return true;
    }
    bool Commit(AdminRequest const& request, std::string const&, Sha256 const& requestSha256,
        Snapshot const& before, bool, Snapshot const& after, std::string const& resultCode,
        std::string& error) override
    {
        if (data_->failCommit) { error = "INJECTED_TRANSACTION_FAILURE"; return false; }
        OperationRecord record;
        record.operationId = request.operationId;
        record.requestSha256 = requestSha256;
        record.resultCode = resultCode;
        record.resultingVersionId = after.versionId;
        record.beforeSha256 = before.sha256;
        record.afterSha256 = after.sha256;
        data_->versions[after.versionId] = after;
        data_->operations[request.operationId] = record;
        data_->current = after;
        data_->hasCurrent = true;
        return true;
    }
private:
    std::shared_ptr<FakeData> data_;
};

int failures = 0;
#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL " << __FILE__ << ':' << __LINE__ << " " #x "\n"; ++failures; } } while (0)

Snapshot MakeSnapshot(uint64_t id, std::vector<uint32_t> guids)
{
    Snapshot snapshot; snapshot.versionId = id; snapshot.guids = std::move(guids);
    std::string bytes, error; CHECK(SerializeSnapshot(snapshot.guids, bytes, error)); snapshot.sha256 = Hash(bytes); return snapshot;
}

AdminRequest MakeInitialize(std::vector<uint32_t> guids, std::string operationId = "11111111-1111-4111-8111-111111111111")
{
    AdminRequest request;
    request.operationId = std::move(operationId);
    request.operationType = OperationType::INITIALIZE;
    request.actor = "phase-b-test";
    request.reason = "explicit ordered test roster";
    request.requestedTargetCount = static_cast<uint32_t>(guids.size());
    request.add = std::move(guids);
    return request;
}

std::string Wire(AdminRequest const& request)
{
    std::string bytes, error; CHECK(SerializeAdminRequest(request, bytes, error)); return bytes;
}

void TestCanonicalVectors()
{
    std::string empty, error;
    CHECK(SerializeSnapshot({}, empty, error));
    CHECK(empty.size() == 68);
    CHECK(Hex(Hash(empty)) == "ba46c4a526ee8bbe3a640492a1167de0a449d382fe129891bf38ba89e3df293e");

    AdminRequest source = MakeInitialize({1, 42, 4294967295u});
    std::string canonical = Wire(source);
    CHECK(canonical.size() == 418);
    CHECK(Hex(Hash(canonical)) == "f98db9bb37bda3b0d405b3749c08c77cab687b33738aeef7fd8a34fa6ab5dbef");
    AdminRequest parsed;
    CHECK(ParseAdminRequest(canonical, parsed, error));
    CHECK(Wire(parsed) == canonical);
    CHECK(canonical.find("add\t0000000001\t0000000001\n") != std::string::npos);
    CHECK(canonical.find("add\t0000000003\t4294967295\n") != std::string::npos);

    AdminRequest nfc = source;
    nfc.operationId = "66666666-6666-4666-8666-666666666666";
    nfc.actor = "\xC3\xA9";
    CHECK(SerializeAdminRequest(nfc, canonical, error));
    nfc.actor = "e\xCC\x81";
    CHECK(!SerializeAdminRequest(nfc, canonical, error));

    AdminRequest emptyActor = source;
    emptyActor.actor.clear();
    CHECK(!SerializeAdminRequest(emptyActor, canonical, error));

    AdminRequest unsortedRemove = source;
    unsortedRemove.operationType = OperationType::REMOVE;
    unsortedRemove.add.clear();
    unsortedRemove.remove = {42, 1};
    CHECK(!SerializeAdminRequest(unsortedRemove, canonical, error));

    AdminRequest unsortedReplace = source;
    unsortedReplace.operationType = OperationType::REPLACE;
    unsortedReplace.add.clear();
    unsortedReplace.replace = {{1, 42, 420}, {2, 1, 10}};
    CHECK(!SerializeAdminRequest(unsortedReplace, canonical, error));

    std::string badOrdinal = canonical;
    size_t ordinal = badOrdinal.find("add\t0000000002");
    CHECK(ordinal != std::string::npos);
    badOrdinal.replace(ordinal, 14, "add\t0000000003");
    CHECK(!ParseAdminRequest(badOrdinal, parsed, error));

    std::string extra = canonical;
    extra += "unknown=value\n";
    CHECK(!ParseAdminRequest(extra, parsed, error));
}

void TestStartupStates()
{
    auto data = std::make_shared<FakeData>();
    std::string error;
    Service disabled(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(disabled.Start(false, false, error));
    CHECK(disabled.State() == RuntimeState::DISABLED);

    Service async(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(!async.Start(true, true, error));
    CHECK(async.State() == RuntimeState::INVALID_FAIL_CLOSED);
    CHECK(error == "ASYNC_LOGIN_UNSUPPORTED");

    Service missing(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(!missing.Start(true, false, error));
    CHECK(missing.State() == RuntimeState::INVALID_FAIL_CLOSED);
    CHECK(error == "NO_CURRENT_ROSTER_VERSION");

    data->current = MakeSnapshot(1, {10, 20}); data->hasCurrent = true; data->versions[1] = data->current;
    Service healthy(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(healthy.Start(true, false, error));
    CHECK(healthy.State() == RuntimeState::STARTING);
    CHECK(healthy.IsMember(10));
    CHECK(healthy.Status().rosterTarget == 2 && healthy.Status().rosterAvailable == 2 && healthy.Status().rosterOnline == 0);
    healthy.RecordOnline(10);
    CHECK(healthy.State() == RuntimeState::STARTING);
    healthy.RecordUnavailable(10, "LOGIN_FAILED");
    CHECK(healthy.State() == RuntimeState::DEGRADED);
    CHECK(healthy.Desired() == std::vector<uint32_t>({10, 20}));
    CHECK(!healthy.IsMember(30));
    healthy.RecordOnline(10);
    CHECK(healthy.State() == RuntimeState::STARTING);
    healthy.RecordOnline(20);
    CHECK(healthy.State() == RuntimeState::HEALTHY);
    RuntimeStatus status = healthy.Status();
    CHECK(status.rosterTarget == 2 && status.rosterAvailable == 2 && status.rosterOnline == 2 && status.diagnostics.empty());
    healthy.Stop();
    CHECK(healthy.State() == RuntimeState::STOPPED);

    Snapshot corrupt = data->current; corrupt.sha256[0] ^= 1; data->current = corrupt;
    Service badHash(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(!badHash.Start(true, false, error));
    CHECK(error == "SNAPSHOT_HASH_MISMATCH");
}

void TestOperationsAndRestart()
{
    auto data = std::make_shared<FakeData>();
    std::string error;
    Service initializer(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(!initializer.Start(true, false, error));
    AdminRequest init = MakeInitialize({101, 202, 303});
    std::string initWire = Wire(init);
    ApplyResult first = initializer.Apply(initWire);
    CHECK(first.accepted && !first.replayed && first.versionId == 1);
    CHECK(Hex(first.beforeSha256) == "ba46c4a526ee8bbe3a640492a1167de0a449d382fe129891bf38ba89e3df293e");
    CHECK(initializer.State() == RuntimeState::INVALID_FAIL_CLOSED);
    ApplyResult replay = initializer.Apply(initWire);
    CHECK(replay.accepted && replay.replayed && replay.versionId == 1);

    AdminRequest collision = init; collision.reason = "different";
    ApplyResult mismatch = initializer.Apply(Wire(collision));
    CHECK(!mismatch.accepted && mismatch.code == "OPERATION_ID_REQUEST_MISMATCH");

    Service restart(std::unique_ptr<Store>(new FakeStore(data)));
    CHECK(restart.Start(true, false, error));
    CHECK(restart.Desired() == std::vector<uint32_t>({101, 202, 303}));

    AdminRequest expand;
    expand.operationId = "22222222-2222-4222-8222-222222222222";
    expand.operationType = OperationType::EXPAND;
    expand.hasExpectedCurrentVersionId = true;
    expand.expectedCurrentVersionId = 1;
    expand.actor = "phase-b-test"; expand.reason = "append only";
    expand.add = {404, 505}; expand.requestedTargetCount = 5;
    ApplyResult expanded = restart.Apply(Wire(expand));
    CHECK(expanded.accepted && expanded.versionId == 2);
    CHECK(restart.Desired() == std::vector<uint32_t>({101, 202, 303, 404, 505}));
    CHECK(std::equal(data->versions[1].guids.begin(), data->versions[1].guids.end(), data->versions[2].guids.begin()));

    AdminRequest remove;
    remove.operationId="77777777-7777-4777-8777-777777777777"; remove.operationType=OperationType::REMOVE;
    remove.hasExpectedCurrentVersionId=true; remove.expectedCurrentVersionId=2; remove.actor="test"; remove.reason="explicit remove";
    remove.remove={202}; remove.requestedTargetCount=4;
    CHECK(restart.Apply(Wire(remove)).accepted);
    CHECK(restart.Desired() == std::vector<uint32_t>({101, 303, 404, 505}));

    AdminRequest replace;
    replace.operationId="88888888-8888-4888-8888-888888888888"; replace.operationType=OperationType::REPLACE;
    replace.hasExpectedCurrentVersionId=true; replace.expectedCurrentVersionId=3; replace.actor="test"; replace.reason="explicit replace";
    replace.replace.push_back({1,101,111}); replace.requestedTargetCount=4;
    CHECK(restart.Apply(Wire(replace)).accepted);
    CHECK(restart.Desired() == std::vector<uint32_t>({111, 303, 404, 505}));

    AdminRequest rollback;
    rollback.operationId="99999999-9999-4999-8999-999999999999"; rollback.operationType=OperationType::ROLLBACK;
    rollback.hasExpectedCurrentVersionId=true; rollback.expectedCurrentVersionId=4; rollback.actor="test"; rollback.reason="explicit rollback";
    rollback.hasRollbackVersionId=true; rollback.rollbackVersionId=1; rollback.requestedTargetCount=3;
    CHECK(restart.Apply(Wire(rollback)).accepted);
    CHECK(restart.Desired() == std::vector<uint32_t>({101, 202, 303}));

    auto replaceData = std::make_shared<FakeData>();
    replaceData->current = MakeSnapshot(10, {500, 100, 300}); replaceData->hasCurrent = true; replaceData->versions[10] = replaceData->current;
    Service byGuid(std::unique_ptr<Store>(new FakeStore(replaceData))); CHECK(byGuid.Start(true, false, error));
    AdminRequest byGuidRequest;
    byGuidRequest.operationId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; byGuidRequest.operationType=OperationType::REPLACE;
    byGuidRequest.hasExpectedCurrentVersionId=true; byGuidRequest.expectedCurrentVersionId=10; byGuidRequest.actor="test";
    byGuidRequest.reason="replace list ordinal is not roster position"; byGuidRequest.requestedTargetCount=3;
    byGuidRequest.replace={{1,100,200},{2,500,600}};
    CHECK(byGuid.Apply(Wire(byGuidRequest)).accepted);
    CHECK(byGuid.Desired() == std::vector<uint32_t>({600, 200, 300}));

    std::vector<uint32_t> fifty, added;
    for (uint32_t i = 1; i <= 50; ++i) fifty.push_back(i);
    for (uint32_t i = 51; i <= 100; ++i) added.push_back(i);
    auto scaleData = std::make_shared<FakeData>(); scaleData->current = MakeSnapshot(7, fifty); scaleData->hasCurrent = true; scaleData->versions[7] = scaleData->current;
    Service scale(std::unique_ptr<Store>(new FakeStore(scaleData))); CHECK(scale.Start(true, false, error));
    AdminRequest to100; to100.operationId="33333333-3333-4333-8333-333333333333"; to100.operationType=OperationType::EXPAND; to100.hasExpectedCurrentVersionId=true; to100.expectedCurrentVersionId=7; to100.actor="test"; to100.reason="50 to 100"; to100.add=added; to100.requestedTargetCount=100;
    CHECK(scale.Apply(Wire(to100)).accepted);
    CHECK(scale.Desired().size() == 100);
    CHECK(std::equal(fifty.begin(), fifty.end(), scale.Desired().begin()));
}

void TestFailureAndPolicy()
{
    auto data = std::make_shared<FakeData>();
    data->current = MakeSnapshot(1, {700, 800}); data->hasCurrent = true; data->versions[1] = data->current;
    std::string error;
    Service service(std::unique_ptr<Store>(new FakeStore(data))); CHECK(service.Start(true, false, error));
    Snapshot before = data->current;
    data->failCommit = true;
    AdminRequest add; add.operationId="44444444-4444-4444-8444-444444444444"; add.operationType=OperationType::ADD; add.hasExpectedCurrentVersionId=true; add.expectedCurrentVersionId=1; add.actor="test"; add.reason="failure injection"; add.add={900}; add.requestedTargetCount=3;
    ApplyResult failed = service.Apply(Wire(add));
    CHECK(!failed.accepted && failed.code == "TRANSACTION_FAILED");
    CHECK(data->current.versionId == before.versionId && data->current.guids == before.guids && data->current.sha256 == before.sha256);
    CHECK(service.Desired() == before.guids);

    CHECK(!service.CanAutomaticLogout(700));
    CHECK(!service.CanAutomaticDelete(700));
    CHECK(!service.CanAutomaticReplace(700));
    CHECK(!service.CanRotationMutate(700));
    CHECK(service.CanAutomaticLogout(999));
    service.RecordUnavailable(700, "ACCOUNT_DISABLED");
    CHECK(service.State() == RuntimeState::DEGRADED);
    CHECK(service.Desired() == std::vector<uint32_t>({700, 800}));

    AdminRequest duplicate = MakeInitialize({1, 1}, "55555555-5555-4555-8555-555555555555");
    std::string ignored;
    CHECK(!SerializeAdminRequest(duplicate, ignored, error));
}

void TestEveryStateName()
{
    CHECK(RuntimeStateName(RuntimeState::DISABLED) == "DISABLED");
    CHECK(RuntimeStateName(RuntimeState::LOADING) == "LOADING");
    CHECK(RuntimeStateName(RuntimeState::STARTING) == "STARTING");
    CHECK(RuntimeStateName(RuntimeState::HEALTHY) == "HEALTHY");
    CHECK(RuntimeStateName(RuntimeState::DEGRADED) == "DEGRADED");
    CHECK(RuntimeStateName(RuntimeState::INVALID_FAIL_CLOSED) == "INVALID_FAIL_CLOSED");
    CHECK(RuntimeStateName(RuntimeState::SHUTTING_DOWN) == "SHUTTING_DOWN");
    CHECK(RuntimeStateName(RuntimeState::STOPPED) == "STOPPED");
}
}

int main()
{
    TestCanonicalVectors();
    TestStartupStates();
    TestOperationsAndRestart();
    TestFailureAndPolicy();
    TestEveryStateName();
    if (failures) { std::cerr << "persistent_active_roster_tests failures=" << failures << "\n"; return EXIT_FAILURE; }
    std::cout << "persistent_active_roster_tests PASS\n";
    return EXIT_SUCCESS;
}
