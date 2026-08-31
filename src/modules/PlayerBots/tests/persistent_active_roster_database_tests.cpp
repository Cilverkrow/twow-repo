#include "PersistentActiveRoster.h"
#include "PersistentActiveRosterDatabase.h"

#include "Database/DatabaseEnv.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace ai::roster;

namespace
{
int failures = 0;
#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL " << __FILE__ << ':' << __LINE__ << " " #x "\n"; ++failures; } } while (0)

std::string Wire(AdminRequest const& request)
{
    std::string bytes;
    std::string error;
    CHECK(SerializeAdminRequest(request, bytes, error));
    return bytes;
}

AdminRequest InitializeRequest(std::vector<uint32_t> guids, std::string operationId)
{
    AdminRequest request;
    request.operationId = std::move(operationId);
    request.operationType = OperationType::INITIALIZE;
    request.actor = "phase-b-r2-real-adapter";
    request.reason = "explicit ordered disposable roster";
    request.requestedTargetCount = static_cast<uint32_t>(guids.size());
    request.add = std::move(guids);
    return request;
}

AdminRequest ChangeRequest(OperationType type, uint64_t expected, uint32_t target,
    std::string operationId)
{
    AdminRequest request;
    request.operationId = std::move(operationId);
    request.operationType = type;
    request.hasExpectedCurrentVersionId = true;
    request.expectedCurrentVersionId = expected;
    request.actor = "phase-b-r2-real-adapter";
    request.reason = "isolated maintenance operation";
    request.requestedTargetCount = target;
    return request;
}

uint64_t Scalar(Database& database, char const* sql)
{
    std::unique_ptr<QueryResult> result(database.Query(sql));
    CHECK(result && result->GetRowCount() == 1);
    return result ? result->Fetch()[0].GetUInt64() : 0;
}

std::string ScalarText(Database& database, char const* sql)
{
    std::unique_ptr<QueryResult> result(database.Query(sql));
    CHECK(result && result->GetRowCount() == 1 && !result->Fetch()[0].IsNULL());
    return result ? result->Fetch()[0].GetCppString() : std::string();
}

struct Counts
{
    uint64_t current = 0;
    uint64_t versions = 0;
    uint64_t members = 0;
    uint64_t changes = 0;
    bool operator==(Counts const& other) const
    {
        return current == other.current && versions == other.versions &&
            members == other.members && changes == other.changes;
    }
};

Counts ReadCounts(Database& database)
{
    Counts counts;
    std::unique_ptr<QueryResult> result(database.Query(
        "SELECT COALESCE(`version_id`,0),"
        "(SELECT COUNT(*) FROM `ai_playerbot_roster_version`),"
        "(SELECT COUNT(*) FROM `ai_playerbot_roster_member`),"
        "(SELECT COUNT(*) FROM `ai_playerbot_roster_change`) "
        "FROM `ai_playerbot_roster_current` WHERE `singleton_id`=1"));
    CHECK(result && result->GetRowCount() == 1);
    if (result)
    {
        Field* fields = result->Fetch();
        counts.current = fields[0].GetUInt64();
        counts.versions = fields[1].GetUInt64();
        counts.members = fields[2].GetUInt64();
        counts.changes = fields[3].GetUInt64();
    }
    return counts;
}

std::unique_ptr<Service> NewService(Database& database, std::string& error)
{
    std::unique_ptr<Service> service(new Service(
        std::unique_ptr<Store>(new CharacterDatabaseStore(database))));
    CHECK(service->Start(true, false, error));
    return service;
}

void CheckLoadValidation(Database& database, uint64_t versionId)
{
    CharacterDatabaseStore store(database);
    Snapshot snapshot;
    bool found = false;
    std::string error;

    CHECK(database.DirectPExecute(
        "UPDATE `ai_playerbot_roster_version` SET `member_count`=`member_count`+1 WHERE `version_id`=" UI64FMTD,
        versionId));
    CHECK(!store.LoadVersion(versionId, snapshot, found, error));
    CHECK(error == "ROSTER_MEMBER_COUNT_MISMATCH");
    CHECK(database.DirectPExecute(
        "UPDATE `ai_playerbot_roster_version` SET `member_count`=`member_count`-1 WHERE `version_id`=" UI64FMTD,
        versionId));

    uint64_t memberCount = Scalar(database,
        ("SELECT `member_count` FROM `ai_playerbot_roster_version` WHERE `version_id`=" + std::to_string(versionId)).c_str());
    CHECK(database.DirectPExecute(
        "UPDATE `ai_playerbot_roster_member` SET `ordinal`=%u WHERE `version_id`=" UI64FMTD " AND `ordinal`=%u",
        static_cast<uint32_t>(memberCount + 100), versionId, static_cast<uint32_t>(memberCount)));
    error.clear(); found = false;
    CHECK(!store.LoadVersion(versionId, snapshot, found, error));
    CHECK(error == "ROSTER_MEMBER_ORDINAL_INVALID");
    CHECK(database.DirectPExecute(
        "UPDATE `ai_playerbot_roster_member` SET `ordinal`=%u WHERE `version_id`=" UI64FMTD " AND `ordinal`=%u",
        static_cast<uint32_t>(memberCount), versionId, static_cast<uint32_t>(memberCount + 100)));

    std::ostringstream duplicate;
    duplicate << "INSERT INTO `ai_playerbot_roster_member` (`version_id`,`ordinal`,`character_guid`) "
        "SELECT `version_id`," << (memberCount + 1) << ",`character_guid` FROM `ai_playerbot_roster_member` "
        "WHERE `version_id`=" << versionId << " ORDER BY `ordinal` LIMIT 1";
    CHECK(!database.DirectExecute(duplicate.str().c_str()));
}

void CheckInjectedRollback(Database& database, uint64_t versionId, uint32_t targetCount)
{
    Counts before = ReadCounts(database);
    CHECK(database.DirectExecute(
        "CREATE TRIGGER `r2_fail_member` BEFORE INSERT ON `ai_playerbot_roster_member` "
        "FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='r2 member failure'"));
    {
        std::string error;
        std::unique_ptr<Service> service = NewService(database, error);
        AdminRequest request = ChangeRequest(OperationType::ADD, versionId, targetCount,
            "32000000-0000-4000-8000-000000000006");
        request.add = {900001};
        ApplyResult result = service->Apply(Wire(request));
        CHECK(!result.accepted && result.code == "TRANSACTION_FAILED");
    }
    CHECK(database.DirectExecute("DROP TRIGGER `r2_fail_member`"));
    CHECK(ReadCounts(database) == before);

    CHECK(database.DirectExecute(
        "CREATE TRIGGER `r2_fail_audit` BEFORE INSERT ON `ai_playerbot_roster_change` "
        "FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='r2 audit failure'"));
    {
        std::string error;
        std::unique_ptr<Service> service = NewService(database, error);
        AdminRequest request = ChangeRequest(OperationType::ADD, versionId, targetCount,
            "32000000-0000-4000-8000-000000000007");
        request.add = {900002};
        ApplyResult result = service->Apply(Wire(request));
        CHECK(!result.accepted && result.code == "TRANSACTION_FAILED");
    }
    CHECK(database.DirectExecute("DROP TRIGGER `r2_fail_audit`"));
    CHECK(ReadCounts(database) == before);
}

void RunConcurrent(std::string const& connectionString, uint64_t expectedVersion, uint32_t targetCount,
    Database& observer)
{
    Counts before = ReadCounts(observer);
    std::atomic<unsigned> ready{0};
    std::atomic<bool> go{false};
    ApplyResult results[2];
    std::string ids[2] = {
        "32000000-0000-4000-8000-000000000008",
        "32000000-0000-4000-8000-000000000009"
    };

    auto runner = [&](unsigned index)
    {
        DatabaseType database;
        CHECK(database.Initialize(index == 0 ? "r2-concurrent-a" : "r2-concurrent-b",
            connectionString.c_str(), 1, 0));
        database.ThreadStart();
        std::string error;
        std::unique_ptr<Service> service = NewService(database, error);
        AdminRequest request = ChangeRequest(OperationType::ADD, expectedVersion, targetCount, ids[index]);
        request.add = {static_cast<uint32_t>(910001 + index)};
        ready.fetch_add(1);
        while (!go.load())
            std::this_thread::yield();
        results[index] = service->Apply(Wire(request));
        database.ThreadEnd();
        database.StopServer();
    };

    std::thread first(runner, 0);
    std::thread second(runner, 1);
    while (ready.load() != 2)
        std::this_thread::yield();
    go.store(true);
    first.join();
    second.join();

    unsigned winners = 0;
    unsigned losers = 0;
    unsigned loserIndex = 0;
    for (unsigned i = 0; i < 2; ++i)
    {
        if (results[i].accepted)
            ++winners;
        else if (results[i].code == "CURRENT_VERSION_MISMATCH")
        {
            ++losers;
            loserIndex = i;
        }
    }
    CHECK(winners == 1 && losers == 1);
    Counts after = ReadCounts(observer);
    CHECK(after.current == expectedVersion + 1);
    CHECK(after.versions == before.versions + 1);
    CHECK(after.members == before.members + targetCount);
    CHECK(after.changes == before.changes + 1);
    std::string loserQuery = "SELECT COUNT(*) FROM `ai_playerbot_roster_change` WHERE `operation_id`='" + ids[loserIndex] + "'";
    CHECK(Scalar(observer, loserQuery.c_str()) == 0);
}

void Run(std::string const& connectionString)
{
    std::cerr << "STAGE=PRIMARY_INITIALIZE" << std::endl;
    DatabaseType primary;
    CHECK(primary.Initialize("r2-real-adapter-primary", connectionString.c_str(), 1, 0));
    primary.ThreadStart();

    std::cerr << "STAGE=VERIFY_SCHEMA" << std::endl;
    CharacterDatabaseStore directStore(primary);
    std::string error;
    CHECK(directStore.VerifySchema(error));
    Snapshot current;
    bool found = true;
    CHECK(directStore.LoadCurrent(current, found, error));
    CHECK(!found);

    std::vector<uint32_t> fifty;
    for (uint32_t guid = 1; guid <= 50; ++guid)
        fifty.push_back(guid);
    Service initializer(std::unique_ptr<Store>(new CharacterDatabaseStore(primary)));
    CHECK(!initializer.Start(true, false, error));
    CHECK(error == "NO_CURRENT_ROSTER_VERSION");
    AdminRequest initialize = InitializeRequest(fifty, "32000000-0000-4000-8000-000000000001");
    std::string initializeWire = Wire(initialize);
    ApplyResult initialized = initializer.Apply(initializeWire);
    CHECK(initialized.accepted && initialized.versionId == 1 && initialized.code == "APPLIED_RESTART_REQUIRED");
    ApplyResult replay = initializer.Apply(initializeWire);
    CHECK(replay.accepted && replay.replayed && replay.versionId == 1);
    initialize.reason = "different canonical request";
    ApplyResult collision = initializer.Apply(Wire(initialize));
    CHECK(!collision.accepted && collision.code == "OPERATION_ID_REQUEST_MISMATCH");

    DatabaseType restartDatabase;
    std::cerr << "STAGE=RESTART_OBJECT" << std::endl;
    CHECK(restartDatabase.Initialize("r2-real-adapter-restart", connectionString.c_str(), 1, 0));
    restartDatabase.ThreadStart();
    std::unique_ptr<Service> restart = NewService(restartDatabase, error);
    CHECK(restart->Desired() == fifty);
    CHECK(ScalarText(restartDatabase,
        "SELECT HEX(`snapshot_sha256`) FROM `ai_playerbot_roster_version` WHERE `version_id`=1") ==
        Hex(restart->Status().rosterSha256));

    std::vector<uint32_t> appended;
    for (uint32_t guid = 51; guid <= 100; ++guid)
        appended.push_back(guid);
    AdminRequest expand = ChangeRequest(OperationType::EXPAND, 1, 100,
        "32000000-0000-4000-8000-000000000002");
    expand.add = appended;
    CHECK(restart->Apply(Wire(expand)).accepted);

    std::unique_ptr<Service> afterExpand = NewService(primary, error);
    CHECK(afterExpand->Desired().size() == 100);
    CHECK(std::equal(fifty.begin(), fifty.end(), afterExpand->Desired().begin()));
    AdminRequest remove = ChangeRequest(OperationType::REMOVE, 2, 99,
        "32000000-0000-4000-8000-000000000003");
    remove.remove = {100};
    CHECK(afterExpand->Apply(Wire(remove)).accepted);

    std::unique_ptr<Service> afterRemove = NewService(primary, error);
    AdminRequest replace = ChangeRequest(OperationType::REPLACE, 3, 99,
        "32000000-0000-4000-8000-000000000004");
    replace.replace = {{1, 99, 199}};
    CHECK(afterRemove->Apply(Wire(replace)).accepted);

    std::unique_ptr<Service> wrongExpected = NewService(primary, error);
    AdminRequest wrong = ChangeRequest(OperationType::ADD, 999, 100,
        "32000000-0000-4000-8000-000000000005");
    wrong.add = {200};
    ApplyResult wrongResult = wrongExpected->Apply(Wire(wrong));
    CHECK(!wrongResult.accepted && wrongResult.code == "CURRENT_VERSION_MISMATCH");

    CheckLoadValidation(primary, 4);
    std::cerr << "STAGE=ROLLBACK_INJECTION" << std::endl;
    CheckInjectedRollback(primary, 4, 100);
    std::cerr << "STAGE=CONCURRENCY" << std::endl;
    RunConcurrent(connectionString, 4, 100, primary);

    restartDatabase.ThreadEnd();
    restartDatabase.StopServer();
    primary.ThreadEnd();
    primary.StopServer();
    std::cerr << "STAGE=COMPLETE" << std::endl;
}
}

#ifdef main
#undef main
#endif
int main(int argc, char** argv)
{
    std::cerr << "STAGE=MAIN" << std::endl;
    if (argc != 2)
    {
        std::cerr << "usage: persistent_active_roster_database_tests host;port;user;password;database\n";
        return EXIT_FAILURE;
    }
    Run(argv[1]);
    if (failures)
    {
        std::cerr << "persistent_active_roster_database_tests failures=" << failures << "\n";
        return EXIT_FAILURE;
    }
    std::cout << "persistent_active_roster_database_tests PASS\n";
    return EXIT_SUCCESS;
}
