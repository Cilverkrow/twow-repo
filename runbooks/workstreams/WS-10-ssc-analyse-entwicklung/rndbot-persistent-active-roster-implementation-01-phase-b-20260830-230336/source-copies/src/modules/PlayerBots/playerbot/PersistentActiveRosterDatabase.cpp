#include "PersistentActiveRosterDatabase.h"

#include "Database/DatabaseEnv.h"

#include <iomanip>
#include <sstream>

namespace ai
{
namespace roster
{
namespace
{
std::string BytesHex(std::string const& bytes)
{
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned char byte : bytes) out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

std::string SqlTextHex(std::string const& text)
{
    return "CONVERT(UNHEX('" + BytesHex(text) + "') USING utf8mb4)";
}
}

bool CharacterDatabaseStore::LoadMembers(Snapshot& snapshot, std::string& error)
{
    QueryResult* members = CharacterDatabase.PQuery(
        "SELECT `ordinal`, `character_guid` FROM `ai_playerbot_roster_member` WHERE `version_id`=" UI64FMTD " ORDER BY `ordinal` ASC",
        snapshot.versionId);
    snapshot.guids.clear();
    if (!members)
    {
        error = "ROSTER_MEMBER_QUERY_FAILED_OR_EMPTY";
        return false;
    }
    uint32_t expected = 1;
    do
    {
        Field* fields = members->Fetch();
        if (fields[0].GetUInt32() != expected || !fields[1].GetUInt32())
        {
            delete members;
            error = "ROSTER_MEMBER_ORDINAL_INVALID";
            return false;
        }
        snapshot.guids.push_back(fields[1].GetUInt32());
        ++expected;
    } while (members->NextRow());
    delete members;
    return true;
}

bool CharacterDatabaseStore::LoadCurrent(Snapshot& snapshot, bool& found, std::string& error)
{
    found = false;
    QueryResult* result = CharacterDatabase.Query(
        "SELECT v.`version_id`, HEX(v.`snapshot_sha256`) FROM `ai_playerbot_roster_current` c "
        "JOIN `ai_playerbot_roster_version` v ON v.`version_id`=c.`version_id` WHERE c.`singleton_id`=1");
    if (!result)
        return true;
    Field* fields = result->Fetch();
    snapshot.versionId = fields[0].GetUInt64();
    std::string digest = fields[1].GetString();
    delete result;
    if (!ParseHex(digest, snapshot.sha256))
    {
        error = "CURRENT_SNAPSHOT_HASH_INVALID";
        return false;
    }
    if (!LoadMembers(snapshot, error)) return false;
    found = true;
    return true;
}

bool CharacterDatabaseStore::LoadVersion(uint64_t versionId, Snapshot& snapshot, bool& found, std::string& error)
{
    found = false;
    QueryResult* result = CharacterDatabase.PQuery(
        "SELECT `version_id`, HEX(`snapshot_sha256`) FROM `ai_playerbot_roster_version` WHERE `version_id`=" UI64FMTD,
        versionId);
    if (!result) return true;
    Field* fields = result->Fetch();
    snapshot.versionId = fields[0].GetUInt64();
    std::string digest = fields[1].GetString();
    delete result;
    if (!ParseHex(digest, snapshot.sha256)) { error = "VERSION_SNAPSHOT_HASH_INVALID"; return false; }
    if (!LoadMembers(snapshot, error)) return false;
    found = true;
    return true;
}

bool CharacterDatabaseStore::FindOperation(std::string const& operationId, OperationRecord& record, bool& found, std::string& error)
{
    found = false;
    QueryResult* result = CharacterDatabase.PQuery(
        "SELECT `operation_id`, HEX(`request_sha256`), `result_code`, `resulting_version_id`, "
        "HEX(`before_sha256`), HEX(`after_sha256`) FROM `ai_playerbot_roster_change` WHERE `operation_id`='%s'",
        operationId.c_str());
    if (!result) return true;
    Field* fields = result->Fetch();
    record.operationId = fields[0].GetString();
    record.resultCode = fields[2].GetString();
    record.resultingVersionId = fields[3].GetUInt64();
    bool valid = ParseHex(fields[1].GetString(), record.requestSha256) &&
        ParseHex(fields[4].GetString(), record.beforeSha256) && ParseHex(fields[5].GetString(), record.afterSha256);
    delete result;
    if (!valid) { error = "OPERATION_DIGEST_INVALID"; return false; }
    found = true;
    return true;
}

bool CharacterDatabaseStore::Commit(AdminRequest const& request, std::string const& canonicalRequest,
    Sha256 const& requestSha256, Snapshot const& before, bool hasBefore, Snapshot const& after,
    std::string const& resultCode, std::string& error)
{
    if (!CharacterDatabase.BeginTransaction())
    {
        error = "BEGIN_TRANSACTION_FAILED";
        return false;
    }

    std::string actorExpr = SqlTextHex(request.actor);
    std::string reasonExpr = SqlTextHex(request.reason);
    std::string requestBytes = BytesHex(canonicalRequest);
    if (hasBefore)
    {
        CharacterDatabase.PExecute(
            "INSERT INTO `ai_playerbot_roster_version` "
            "(`version_id`,`previous_version_id`,`snapshot_sha256`,`member_count`,`created_by`,`reason`,`operation_id`,`request_sha256`,`canonical_request`) "
            "SELECT " UI64FMTD ",c.`version_id`,UNHEX('%s'),%u,%s,%s,'%s',UNHEX('%s'),UNHEX('%s') "
            "FROM `ai_playerbot_roster_current` c WHERE c.`singleton_id`=1 AND c.`version_id`=" UI64FMTD,
            after.versionId, Hex(after.sha256).c_str(), static_cast<uint32>(after.guids.size()), actorExpr.c_str(), reasonExpr.c_str(),
            request.operationId.c_str(), Hex(requestSha256).c_str(), requestBytes.c_str(), before.versionId);
    }
    else
    {
        CharacterDatabase.PExecute(
            "INSERT INTO `ai_playerbot_roster_version` "
            "(`version_id`,`previous_version_id`,`snapshot_sha256`,`member_count`,`created_by`,`reason`,`operation_id`,`request_sha256`,`canonical_request`) "
            "VALUES (" UI64FMTD ",NULL,UNHEX('%s'),%u,%s,%s,'%s',UNHEX('%s'),UNHEX('%s'))",
            after.versionId, Hex(after.sha256).c_str(), static_cast<uint32>(after.guids.size()), actorExpr.c_str(), reasonExpr.c_str(),
            request.operationId.c_str(), Hex(requestSha256).c_str(), requestBytes.c_str());
    }

    for (size_t index = 0; index < after.guids.size(); ++index)
        CharacterDatabase.PExecute(
            "INSERT INTO `ai_playerbot_roster_member` (`version_id`,`ordinal`,`character_guid`) VALUES (" UI64FMTD ",%u,%u)",
            after.versionId, static_cast<uint32>(index + 1), after.guids[index]);

    if (hasBefore)
        CharacterDatabase.PExecute(
            "UPDATE `ai_playerbot_roster_current` SET `version_id`=" UI64FMTD " WHERE `singleton_id`=1 AND `version_id`=" UI64FMTD,
            after.versionId, before.versionId);
    else
        CharacterDatabase.PExecute(
            "INSERT INTO `ai_playerbot_roster_current` (`singleton_id`,`version_id`) VALUES (1," UI64FMTD ")",
            after.versionId);

    CharacterDatabase.PExecute(
        "INSERT INTO `ai_playerbot_roster_change` "
        "(`operation_id`,`request_sha256`,`operation_type`,`expected_current_version_id`,`result_code`,`resulting_version_id`,`before_sha256`,`after_sha256`,`actor`,`reason`,`canonical_request`) "
        "VALUES ('%s',UNHEX('%s'),'%s',%s,'%.64s'," UI64FMTD ",UNHEX('%s'),UNHEX('%s'),%s,%s,UNHEX('%s'))",
        request.operationId.c_str(), Hex(requestSha256).c_str(), OperationTypeName(request.operationType).c_str(),
        hasBefore ? std::to_string(before.versionId).c_str() : "NULL", resultCode.c_str(), after.versionId,
        Hex(before.sha256).c_str(), Hex(after.sha256).c_str(), actorExpr.c_str(), reasonExpr.c_str(), requestBytes.c_str());

    if (!CharacterDatabase.CommitTransactionDirect())
    {
        error = "COMMIT_TRANSACTION_FAILED";
        return false;
    }
    return true;
}
}
}
