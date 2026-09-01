#include "PersistentActiveRosterDatabase.h"

#include "Database/DatabaseEnv.h"

#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>

namespace ai
{
namespace roster
{
namespace
{
// Replaced only after the isolated MariaDB run proves the exact serialization
// emitted by SchemaFingerprintQuery for the shipped migration.
char const* ExpectedSchemaFingerprint = "32A9C149DBEB9C06EFF6DBBA31A4A6F938E4E6AFB665B91F566595DE46EE9220";

char const* SchemaFingerprintQuery =
    "SELECT `line` FROM ("
    "SELECT CONCAT('TABLE\\t',t.TABLE_NAME,'\\t',COALESCE(t.ENGINE,''),'\\t',COALESCE(t.TABLE_COLLATION,'')) line "
    "FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA=DATABASE() AND t.TABLE_NAME IN "
    "('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change') "
    "UNION ALL "
    "SELECT CONCAT('COLUMN\\t',c.TABLE_NAME,'\\t',LPAD(c.ORDINAL_POSITION,3,'0'),'\\t',c.COLUMN_NAME,'\\t',c.COLUMN_TYPE,'\\t',"
    "c.IS_NULLABLE,'\\t',IF(c.COLUMN_DEFAULT IS NULL,'NULL',CONCAT('HEX:',HEX(c.COLUMN_DEFAULT))),'\\t',"
    "COALESCE(c.CHARACTER_SET_NAME,''),'\\t',COALESCE(c.COLLATION_NAME,''),'\\t',COALESCE(c.EXTRA,'')) "
    "FROM information_schema.COLUMNS c WHERE c.TABLE_SCHEMA=DATABASE() AND c.TABLE_NAME IN "
    "('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change') "
    "UNION ALL "
    "SELECT CONCAT('INDEX\\t',s.TABLE_NAME,'\\t',s.INDEX_NAME,'\\t',s.NON_UNIQUE,'\\t',LPAD(s.SEQ_IN_INDEX,3,'0'),'\\t',"
    "s.COLUMN_NAME,'\\t',COALESCE(s.COLLATION,''),'\\t',COALESCE(s.SUB_PART,''),'\\t',s.INDEX_TYPE) "
    "FROM information_schema.STATISTICS s WHERE s.TABLE_SCHEMA=DATABASE() AND s.TABLE_NAME IN "
    "('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change') "
    "UNION ALL "
    "SELECT CONCAT('FK\\t',k.TABLE_NAME,'\\t',k.CONSTRAINT_NAME,'\\t',LPAD(k.ORDINAL_POSITION,3,'0'),'\\t',k.COLUMN_NAME,'\\t',"
    "k.REFERENCED_TABLE_NAME,'\\t',k.REFERENCED_COLUMN_NAME,'\\t',r.UPDATE_RULE,'\\t',r.DELETE_RULE) "
    "FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r "
    "ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.TABLE_NAME=k.TABLE_NAME AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME "
    "WHERE k.CONSTRAINT_SCHEMA=DATABASE() AND k.TABLE_NAME IN "
    "('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change') "
    "AND k.REFERENCED_TABLE_NAME IS NOT NULL "
    "UNION ALL "
    "SELECT CONCAT('CHECK\\t',cc.TABLE_NAME,'\\t',cc.CONSTRAINT_NAME,'\\t',HEX(cc.CHECK_CLAUSE)) "
    "FROM information_schema.CHECK_CONSTRAINTS cc WHERE cc.CONSTRAINT_SCHEMA=DATABASE() AND cc.TABLE_NAME IN "
    "('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')"
    ") schema_lines ORDER BY `line`";

std::string BytesHex(std::string const& bytes)
{
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned char byte : bytes)
        out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

std::string SqlTextHex(std::string const& text)
{
    return "CONVERT(UNHEX('" + BytesHex(text) + "') USING utf8mb4)";
}

std::string SqlUInt64(uint64_t value)
{
    std::ostringstream out;
    out << value;
    return out.str();
}

bool ParseOperationRow(QueryResult* result, OperationRecord& record, std::string& error)
{
    if (!result || result->GetRowCount() != 1)
    {
        error = "OPERATION_ROW_COUNT_INVALID";
        return false;
    }
    Field* fields = result->Fetch();
    record.operationId = fields[0].GetCppString();
    record.resultCode = fields[2].GetCppString();
    record.resultingVersionId = fields[3].GetUInt64();
    if (!ParseHex(fields[1].GetCppString(), record.requestSha256) ||
        !ParseHex(fields[4].GetCppString(), record.beforeSha256) ||
        !ParseHex(fields[5].GetCppString(), record.afterSha256) || !record.resultingVersionId)
    {
        error = "OPERATION_DIGEST_INVALID";
        return false;
    }
    return true;
}

bool ExecuteExactlyOne(SqlConnection& connection, std::string const& sql, char const* failure, std::string& error)
{
    if (!connection.Execute(sql.c_str()))
    {
        error = failure;
        return false;
    }
    if (connection.AffectedRows() != 1)
    {
        error = std::string(failure) + "_AFFECTED_ROWS";
        return false;
    }
    return true;
}
}

#ifndef ROSTER_DATABASE_INJECTED_ONLY
CharacterDatabaseStore::CharacterDatabaseStore() : database_(CharacterDatabase) {}
#endif
CharacterDatabaseStore::CharacterDatabaseStore(Database& database) : database_(database) {}

bool CharacterDatabaseStore::VerifySchema(std::string& error)
{
    std::unique_ptr<QueryResult> result(database_.Query(SchemaFingerprintQuery));
    if (!result)
    {
        error = "SCHEMA_FINGERPRINT_QUERY_FAILED";
        return false;
    }
    std::ostringstream canonical;
    do
    {
        Field* fields = result->Fetch();
        if (fields[0].IsNULL())
        {
            error = "SCHEMA_FINGERPRINT_NULL_ROW";
            return false;
        }
        canonical << fields[0].GetCppString() << '\n';
    } while (result->NextRow());

    std::string actual = Hex(Hash(canonical.str()));
    if (actual != ExpectedSchemaFingerprint)
    {
        error = "SCHEMA_FINGERPRINT_MISMATCH:" + actual;
        return false;
    }
    return true;
}

bool CharacterDatabaseStore::LoadMembers(Snapshot& snapshot, uint32_t memberCount, std::string& error)
{
    if (!memberCount)
    {
        error = "EMPTY_ROSTER_FORBIDDEN";
        return false;
    }
    std::unique_ptr<QueryResult> members(database_.PQuery(
        "SELECT `ordinal`, `character_guid` FROM `ai_playerbot_roster_member` WHERE `version_id`=" UI64FMTD " ORDER BY `ordinal` ASC",
        snapshot.versionId));
    snapshot.guids.clear();
    if (!members || members->GetRowCount() != memberCount)
    {
        error = "ROSTER_MEMBER_COUNT_MISMATCH";
        return false;
    }
    uint32_t expected = 1;
    do
    {
        Field* fields = members->Fetch();
        if (fields[0].GetUInt32() != expected || !fields[1].GetUInt32())
        {
            error = "ROSTER_MEMBER_ORDINAL_INVALID";
            return false;
        }
        snapshot.guids.push_back(fields[1].GetUInt32());
        ++expected;
    } while (members->NextRow());
    return snapshot.guids.size() == memberCount;
}

bool CharacterDatabaseStore::LoadCurrent(Snapshot& snapshot, bool& found, std::string& error)
{
    found = false;
    std::unique_ptr<QueryResult> current(database_.Query(
        "SELECT `version_id` FROM `ai_playerbot_roster_current` WHERE `singleton_id`=1"));
    if (!current || current->GetRowCount() != 1)
    {
        error = "CURRENT_SINGLETON_MISSING_OR_DUPLICATE";
        return false;
    }
    Field* fields = current->Fetch();
    if (fields[0].IsNULL())
        return true;
    uint64_t versionId = fields[0].GetUInt64();
    if (!versionId)
    {
        error = "CURRENT_VERSION_INVALID";
        return false;
    }
    return LoadVersion(versionId, snapshot, found, error);
}

bool CharacterDatabaseStore::LoadVersion(uint64_t versionId, Snapshot& snapshot, bool& found, std::string& error)
{
    found = false;
    std::unique_ptr<QueryResult> result(database_.PQuery(
        "SELECT `version_id`, `member_count`, HEX(`snapshot_sha256`) FROM `ai_playerbot_roster_version` WHERE `version_id`=" UI64FMTD,
        versionId));
    if (!result)
        return true;
    if (result->GetRowCount() != 1)
    {
        error = "VERSION_ROW_COUNT_INVALID";
        return false;
    }
    Field* fields = result->Fetch();
    snapshot.versionId = fields[0].GetUInt64();
    uint32_t memberCount = fields[1].GetUInt32();
    if (!snapshot.versionId || !ParseHex(fields[2].GetCppString(), snapshot.sha256))
    {
        error = "VERSION_SNAPSHOT_HASH_INVALID";
        return false;
    }
    if (!LoadMembers(snapshot, memberCount, error))
        return false;
    found = true;
    return true;
}

bool CharacterDatabaseStore::FindOperation(std::string const& operationId, OperationRecord& record, bool& found, std::string& error)
{
    found = false;
    std::unique_ptr<QueryResult> result(database_.PQuery(
        "SELECT `operation_id`, HEX(`request_sha256`), `result_code`, `resulting_version_id`, "
        "HEX(`before_sha256`), HEX(`after_sha256`) FROM `ai_playerbot_roster_change` WHERE `operation_id`='%s'",
        operationId.c_str()));
    if (!result)
        return true;
    if (!ParseOperationRow(result.get(), record, error))
        return false;
    found = true;
    return true;
}

bool CharacterDatabaseStore::Commit(AdminRequest const& request, std::string const& canonicalRequest,
    Sha256 const& requestSha256, Snapshot const& before, bool hasBefore, Snapshot& after,
    std::string const& resultCode, bool& replayed, OperationRecord& replayRecord, std::string& error)
{
    replayed = false;
    bool bodyCompleted = false;
    bool rollbackSucceeded = true;
    bool committed = database_.DirectTransaction([&](SqlConnection& connection) -> bool
    {
        std::unique_ptr<QueryResult> current(connection.Query(
            "SELECT `version_id` FROM `ai_playerbot_roster_current` WHERE `singleton_id`=1 FOR UPDATE"));
        if (!current || current->GetRowCount() != 1)
        {
            error = "CURRENT_LOCK_FAILED";
            return false;
        }
        Field* currentFields = current->Fetch();
        bool lockedHasCurrent = !currentFields[0].IsNULL();
        uint64_t lockedVersion = lockedHasCurrent ? currentFields[0].GetUInt64() : 0;

        std::string operationQuery =
            "SELECT `operation_id`, HEX(`request_sha256`), `result_code`, `resulting_version_id`, "
            "HEX(`before_sha256`), HEX(`after_sha256`) FROM `ai_playerbot_roster_change` WHERE `operation_id`='" +
            request.operationId + "' FOR UPDATE";
        std::unique_ptr<QueryResult> operation(connection.Query(operationQuery.c_str()));
        if (operation)
        {
            if (!ParseOperationRow(operation.get(), replayRecord, error))
                return false;
            if (replayRecord.requestSha256 != requestSha256)
            {
                error = "OPERATION_ID_REQUEST_MISMATCH";
                return false;
            }
            replayed = true;
            bodyCompleted = true;
            return true;
        }

        if ((lockedHasCurrent != hasBefore) || (hasBefore && lockedVersion != before.versionId))
        {
            error = "CURRENT_VERSION_MISMATCH";
            return false;
        }

        if (lockedVersion == (std::numeric_limits<uint64_t>::max)())
        {
            error = "VERSION_ID_EXHAUSTED";
            return false;
        }
        after.versionId = lockedHasCurrent ? lockedVersion + 1 : 1;

        std::string actorExpr = SqlTextHex(request.actor);
        std::string reasonExpr = SqlTextHex(request.reason);
        std::string requestBytes = BytesHex(canonicalRequest);
        std::ostringstream versionSql;
        versionSql << "INSERT INTO `ai_playerbot_roster_version` "
            "(`version_id`,`previous_version_id`,`snapshot_sha256`,`member_count`,`created_by`,`reason`,`operation_id`,`request_sha256`,`canonical_request`) VALUES ("
            << after.versionId << ',' << (lockedHasCurrent ? SqlUInt64(lockedVersion) : "NULL") << ",UNHEX('"
            << Hex(after.sha256) << "')," << after.guids.size() << ',' << actorExpr << ',' << reasonExpr << ",'"
            << request.operationId << "',UNHEX('" << Hex(requestSha256) << "'),UNHEX('" << requestBytes << "'))";
        if (!ExecuteExactlyOne(connection, versionSql.str(), "VERSION_INSERT_FAILED", error))
            return false;

        for (size_t index = 0; index < after.guids.size(); ++index)
        {
            std::ostringstream memberSql;
            memberSql << "INSERT INTO `ai_playerbot_roster_member` (`version_id`,`ordinal`,`character_guid`) VALUES ("
                << after.versionId << ',' << (index + 1) << ',' << after.guids[index] << ')';
            if (!ExecuteExactlyOne(connection, memberSql.str(), "MEMBER_INSERT_FAILED", error))
                return false;
        }

        std::ostringstream currentSql;
        currentSql << "UPDATE `ai_playerbot_roster_current` SET `version_id`=" << after.versionId
            << " WHERE `singleton_id`=1 AND `version_id`";
        if (lockedHasCurrent)
            currentSql << '=' << lockedVersion;
        else
            currentSql << " IS NULL";
        if (!ExecuteExactlyOne(connection, currentSql.str(), "CURRENT_CAS_FAILED", error))
            return false;

        std::ostringstream auditSql;
        auditSql << "INSERT INTO `ai_playerbot_roster_change` "
            "(`operation_id`,`request_sha256`,`operation_type`,`expected_current_version_id`,`result_code`,`resulting_version_id`,`before_sha256`,`after_sha256`,`actor`,`reason`,`canonical_request`) VALUES ('"
            << request.operationId << "',UNHEX('" << Hex(requestSha256) << "'),'" << OperationTypeName(request.operationType)
            << "'," << (hasBefore ? SqlUInt64(before.versionId) : "NULL") << ",'" << resultCode << "'," << after.versionId
            << ",UNHEX('" << Hex(before.sha256) << "'),UNHEX('" << Hex(after.sha256) << "')," << actorExpr << ',' << reasonExpr
            << ",UNHEX('" << requestBytes << "'))";
        if (!ExecuteExactlyOne(connection, auditSql.str(), "AUDIT_INSERT_FAILED", error))
            return false;

        bodyCompleted = true;
        return true;
    }, &rollbackSucceeded);

    if (!committed)
    {
        if (!rollbackSucceeded)
            error = error.empty() ? "ROLLBACK_TRANSACTION_FAILED" : error + ":ROLLBACK_TRANSACTION_FAILED";
        else if (error.empty())
            error = bodyCompleted ? "COMMIT_TRANSACTION_FAILED" : "TRANSACTION_BEGIN_OR_ROLLBACK_FAILED";
        return false;
    }
    return true;
}
}
}
