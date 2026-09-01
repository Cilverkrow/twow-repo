#ifndef _PLAYERBOT_DATABASE_CONTRACT_H
#define _PLAYERBOT_DATABASE_CONTRACT_H

#include <cstdint>
#include <string>

namespace ai
{
namespace PlayerbotDatabaseContract
{
static constexpr char EventStoreTable[] = "`cv_bots`.`ai_playerbot_random_bots`";

inline std::string EventStoreSql(char const* prefix, char const* suffix)
{
    return std::string(prefix) + EventStoreTable + suffix;
}

inline std::string EventUpsertSql(bool includeData)
{
    std::string sql = EventStoreSql(
        "INSERT INTO ",
        " (`owner`,`bot`,`time`,`validIn`,`event`,`value`");
    if (includeData)
        sql += ",`data`";
    sql += ") VALUES (0,?,?,?,?,?";
    if (includeData)
        sql += ",?";
    sql += ") ON DUPLICATE KEY UPDATE `time`=VALUES(`time`),"
        "`validIn`=VALUES(`validIn`),`value`=VALUES(`value`),";
    sql += includeData ? "`data`=VALUES(`data`)" : "`data`=NULL";
    return sql;
}

inline std::string EventDeleteSql()
{
    return EventStoreSql(
        "DELETE FROM ",
        " WHERE `owner`=? AND `bot`=? AND `event`=?");
}

inline std::uint32_t EventWriteSerialId(
    std::uint64_t owner, std::uint64_t bot, std::string const& event)
{
    std::uint32_t hash = 2166136261u;
    auto appendByte = [&hash](std::uint8_t value)
    {
        hash ^= value;
        hash *= 16777619u;
    };

    for (unsigned int index = 0; index < sizeof(owner); ++index)
        appendByte(static_cast<std::uint8_t>(owner >> (index * 8)));
    for (unsigned int index = 0; index < sizeof(bot); ++index)
        appendByte(static_cast<std::uint8_t>(bot >> (index * 8)));
    for (unsigned char value : event)
        appendByte(value);

    return hash == 0 ? 1 : hash;
}
}
}

#endif
