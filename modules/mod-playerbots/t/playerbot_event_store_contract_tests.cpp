#include "PlayerbotDatabaseContract.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace
{
int failures = 0;

#define CHECK(expression) do { if (!(expression)) { \
    std::cerr << "CHECK failed at line " << __LINE__ << ": " #expression "\n"; \
    ++failures; \
} } while (false)

std::size_t Count(std::string const& value, std::string const& needle)
{
    std::size_t count = 0;
    for (std::size_t position = 0;
         (position = value.find(needle, position)) != std::string::npos;
         position += needle.size())
        ++count;
    return count;
}

void TestCanonicalTarget()
{
    CHECK(std::string(ai::PlayerbotDatabaseContract::EventStoreTable) ==
        "`cv_bots`.`ai_playerbot_random_bots`");
}

void TestAtomicUpsert()
{
    for (bool includeData : {false, true})
    {
        std::string const sql = ai::PlayerbotDatabaseContract::EventUpsertSql(includeData);
        CHECK(Count(sql, "INSERT INTO") == 1);
        CHECK(Count(sql, "ON DUPLICATE KEY UPDATE") == 1);
        CHECK(sql.find("DELETE") == std::string::npos);
        CHECK(sql.find("REPLACE") == std::string::npos);
        CHECK(sql.find(ai::PlayerbotDatabaseContract::EventStoreTable) != std::string::npos);
        CHECK(Count(sql, "?") == (includeData ? 6u : 5u));
        CHECK(sql.find(includeData ? "`data`=VALUES(`data`)" : "`data`=NULL") != std::string::npos);
    }
}

void TestPreciseDelete()
{
    std::string const sql = ai::PlayerbotDatabaseContract::EventDeleteSql();
    CHECK(sql == "DELETE FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=? AND `bot`=? AND `event`=?");
    CHECK(Count(sql, "?") == 3);
}

void TestStableSerializationLane()
{
    std::uint32_t const first = ai::PlayerbotDatabaseContract::EventWriteSerialId(0, 42, "add");
    CHECK(first != 0);
    CHECK(first == ai::PlayerbotDatabaseContract::EventWriteSerialId(0, 42, "add"));
    CHECK(first != ai::PlayerbotDatabaseContract::EventWriteSerialId(0, 43, "add"));
    CHECK(first != ai::PlayerbotDatabaseContract::EventWriteSerialId(0, 42, "logout"));
}
}

int main()
{
    TestCanonicalTarget();
    TestAtomicUpsert();
    TestPreciseDelete();
    TestStableSerializationLane();
    if (failures)
        return EXIT_FAILURE;
    std::cout << "PLAYERBOT_EVENT_STORE_CONTRACT_TESTS=PASS\n";
    return EXIT_SUCCESS;
}
