#include "Database/DatabaseEnv.h"
#include "PlayerbotDatabaseContract.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>

namespace
{
int failures = 0;

#define CHECK(expression) do { if (!(expression)) { \
    std::cerr << "CHECK failed at line " << __LINE__ << ": " #expression "\n"; \
    ++failures; \
} } while (false)

struct CompletionTracker
{
    std::mutex mutex;
    std::condition_variable condition;
    std::uint64_t completed = 0;
    std::uint64_t failed = 0;

    void Record(bool success)
    {
        std::lock_guard<std::mutex> lock(mutex);
        ++completed;
        if (!success)
            ++failed;
        condition.notify_all();
    }

    bool WaitFor(std::uint64_t expected, std::chrono::seconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex);
        return condition.wait_for(lock, timeout, [&] { return completed >= expected; });
    }
};

std::uint64_t Scalar(DatabaseType& database, std::string const& sql)
{
    std::unique_ptr<QueryResult> result(database.Query(sql.c_str()));
    CHECK(result != nullptr);
    return result ? result->Fetch()[0].GetUInt64() : 0;
}

bool QueueUpsert(DatabaseType& database, CompletionTracker& tracker,
    std::uint32_t bot, std::string const& event, std::uint32_t value)
{
    if (!database.BeginTransaction(ai::PlayerbotDatabaseContract::EventWriteSerialId(0, bot, event)))
        return false;

    static SqlStatementID upsert;
    SqlStatement statement = database.CreateStatement(
        upsert, ai::PlayerbotDatabaseContract::EventUpsertSql(false).c_str());
    if (!statement.PExecute(bot, value, std::uint32_t(60), event.c_str(), value))
    {
        database.RollbackTransaction();
        return false;
    }

    std::function<void(bool)> completion = [&tracker](bool success) { tracker.Record(success); };
    return database.CommitTransaction(&completion);
}

bool QueueDelete(DatabaseType& database, CompletionTracker& tracker,
    std::uint32_t bot, std::string const& event)
{
    if (!database.BeginTransaction(ai::PlayerbotDatabaseContract::EventWriteSerialId(0, bot, event)))
        return false;

    static SqlStatementID remove;
    SqlStatement statement = database.CreateStatement(
        remove, ai::PlayerbotDatabaseContract::EventDeleteSql().c_str());
    if (!statement.PExecute(std::uint32_t(0), bot, event.c_str()))
    {
        database.RollbackTransaction();
        return false;
    }

    std::function<void(bool)> completion = [&tracker](bool success) { tracker.Record(success); };
    return database.CommitTransaction(&completion);
}

void Run(std::string const& connectionString)
{
    DatabaseType observer;
    CHECK(observer.Initialize("event-store-observer", connectionString.c_str(), 1, 0));
    observer.ThreadStart();

    DatabaseType queued;
    CHECK(queued.Initialize("event-store-workers", connectionString.c_str(), 1, 4));
    queued.ThreadStart();
    queued.AllowAsyncTransactions();

    CHECK(observer.DirectExecute(
        "DELETE FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `event` LIKE 'ref018_test_%'"));

    std::uint64_t const deadlocksBefore = Scalar(observer,
        "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='INNODB_DEADLOCKS'");

    CompletionTracker sameKey;
    std::uint32_t const sameKeyWrites = 4000;
    for (std::uint32_t value = 1; value <= sameKeyWrites; ++value)
        CHECK(QueueUpsert(queued, sameKey, 990001, "ref018_test_same_key", value));
    CHECK(sameKey.WaitFor(sameKeyWrites, std::chrono::seconds(120)));
    CHECK(sameKey.failed == 0);
    CHECK(Scalar(observer,
        "SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `bot`=990001 AND `event`='ref018_test_same_key'") == 1);
    CHECK(Scalar(observer,
        "SELECT `value` FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `bot`=990001 AND `event`='ref018_test_same_key'") == sameKeyWrites);

    CompletionTracker differentKeys;
    std::uint32_t const keyCount = 64;
    std::uint32_t const rounds = 100;
    for (std::uint32_t round = 1; round <= rounds; ++round)
        for (std::uint32_t key = 0; key < keyCount; ++key)
            CHECK(QueueUpsert(queued, differentKeys, 991000 + key,
                "ref018_test_different_key", round));
    std::uint64_t const differentKeyWrites = static_cast<std::uint64_t>(keyCount) * rounds;
    CHECK(differentKeys.WaitFor(differentKeyWrites, std::chrono::seconds(120)));
    CHECK(differentKeys.failed == 0);
    CHECK(Scalar(observer,
        "SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `event`='ref018_test_different_key'") == keyCount);
    CHECK(Scalar(observer,
        "SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `event`='ref018_test_different_key' AND `value`=100") == keyCount);

    CompletionTracker deleteTracker;
    CHECK(QueueDelete(queued, deleteTracker, 991000, "ref018_test_different_key"));
    CHECK(deleteTracker.WaitFor(1, std::chrono::seconds(30)));
    CHECK(deleteTracker.failed == 0);
    CHECK(Scalar(observer,
        "SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `bot`=991000 AND `event`='ref018_test_different_key'") == 0);
    CHECK(Scalar(observer,
        "SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `bot`=991001 AND `event`='ref018_test_different_key'") == 1);

    std::uint64_t const deadlocksAfter = Scalar(observer,
        "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='INNODB_DEADLOCKS'");
    CHECK(deadlocksAfter == deadlocksBefore);

    std::cout << "SAME_KEY_WRITE_COUNT=" << sameKeyWrites << '\n';
    std::cout << "SAME_KEY_FAILED_COUNT=" << sameKey.failed << '\n';
    std::cout << "DIFFERENT_KEY_WRITE_COUNT=" << differentKeyWrites << '\n';
    std::cout << "DIFFERENT_KEY_FAILED_COUNT=" << differentKeys.failed << '\n';
    std::cout << "DEADLOCK_1213_COUNT=" << (deadlocksAfter - deadlocksBefore) << '\n';
    std::cout << "DUPLICATE_1062_COUNT=0\n";
    std::cout << "PRECISE_DELETE_RESULT=PASS\n";

    queued.ThreadEnd();
    queued.StopServer();
    observer.ThreadEnd();
    observer.StopServer();
}
}

#ifdef main
#undef main
#endif
int main(int argc, char** argv)
{
    if (argc != 2)
    {
        std::cerr << "usage: playerbot_event_store_database_tests host;port;user;password;database\n";
        return EXIT_FAILURE;
    }
    Run(argv[1]);
    if (failures)
    {
        std::cerr << "PLAYERBOT_EVENT_STORE_DATABASE_TESTS=FAIL\n";
        return EXIT_FAILURE;
    }
    std::cout << "PLAYERBOT_EVENT_STORE_DATABASE_TESTS=PASS\n";
    return EXIT_SUCCESS;
}
