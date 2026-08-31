#include "PersistentActiveRoster.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <unordered_set>

#include <openssl/sha.h>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace ai
{
namespace roster
{
namespace
{
std::vector<std::string> SplitLines(std::string const& input)
{
    std::vector<std::string> result;
    size_t begin = 0;
    while (begin < input.size())
    {
        size_t end = input.find('\n', begin);
        if (end == std::string::npos)
            break;
        result.push_back(input.substr(begin, end - begin));
        begin = end + 1;
    }
    return result;
}

bool ParseUnsigned(std::string const& text, uint64_t maximum, uint64_t& value, bool fixedTen = false)
{
    if (text.empty() || (fixedTen && text.size() != 10) || (!fixedTen && text.size() > 1 && text.front() == '0'))
        return false;
    uint64_t parsed = 0;
    for (char c : text)
    {
        if (c < '0' || c > '9')
            return false;
        uint64_t digit = static_cast<uint64_t>(c - '0');
        if (parsed > (maximum - digit) / 10)
            return false;
        parsed = parsed * 10 + digit;
    }
    if (!parsed || parsed > maximum)
        return false;
    value = parsed;
    return true;
}

bool ParseNullablePositive(std::string const& text, uint64_t& value, bool& present)
{
    if (text == "null")
    {
        present = false;
        value = 0;
        return true;
    }
    present = ParseUnsigned(text, (std::numeric_limits<uint64_t>::max)(), value);
    return present;
}

bool ValidUuidV4(std::string const& value)
{
    if (value.size() != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' || value[14] != '4')
        return false;
    if (value[19] != '8' && value[19] != '9' && value[19] != 'a' && value[19] != 'b')
        return false;
    for (size_t i = 0; i < value.size(); ++i)
    {
        if (i == 8 || i == 13 || i == 18 || i == 23)
            continue;
        if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f')))
            return false;
    }
    return true;
}

bool DecodeBase64Url(std::string const& input, std::string& output)
{
    static char const* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    output.clear();
    uint32_t accumulator = 0;
    int bits = 0;
    for (char c : input)
    {
        char const* pos = std::find(alphabet, alphabet + 64, c);
        if (pos == alphabet + 64)
            return false;
        accumulator = (accumulator << 6) | static_cast<uint32_t>(pos - alphabet);
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            output.push_back(static_cast<char>((accumulator >> bits) & 0xff));
        }
    }
    if (bits && (accumulator & ((1u << bits) - 1u)))
        return false;
    return input.size() % 4 != 1;
}

std::string EncodeBase64Url(std::string const& input)
{
    static char const* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string output;
    uint32_t accumulator = 0;
    int bits = 0;
    for (unsigned char c : input)
    {
        accumulator = (accumulator << 8) | c;
        bits += 8;
        while (bits >= 6)
        {
            bits -= 6;
            output.push_back(alphabet[(accumulator >> bits) & 0x3f]);
        }
    }
    if (bits)
        output.push_back(alphabet[(accumulator << (6 - bits)) & 0x3f]);
    return output;
}

// Canonical-form check for the actor and reason fields.
//
// One implementation for every platform, deliberately. This used to branch: on
// Windows it validated UTF-8 and then full NFC via IsNormalizedString(), while
// everywhere else it validated only that the bytes were well-formed UTF-8. The
// same admin request was therefore rejected as BAD_ACTOR on Windows and
// accepted on Linux. The whole roster contract rests on canonical bytes and
// their SHA-256, so two platforms disagreeing about what "canonical" means
// undermines the guarantee it exists to provide - and the unit suite that pins
// this behaviour had only ever been run on Windows.
//
// The portable rule: well-formed UTF-8 that contains no combining mark. A
// decomposed sequence always carries one ("e" + U+0301), a precomposed
// character never does (U+00E9), which is exactly the distinction the contract
// needs and the one the tests pin.
//
// Known limit, stated rather than hidden: this is an approximation of NFC, not
// NFC. It does not catch a singleton or compatibility case such as U+212B
// ANGSTROM SIGN, which NFC folds to U+00C5 and which the old Windows path would
// have rejected. Closing that gap means a real normalisation table - ICU or
// equivalent - on both platforms, which is a dependency decision rather than
// something to leave as a silent platform difference.
bool IsCombiningMark(uint32_t cp)
{
    return (cp >= 0x0300 && cp <= 0x036F)   // combining diacritical marks
        || (cp >= 0x1AB0 && cp <= 0x1AFF)   // ... extended
        || (cp >= 0x1DC0 && cp <= 0x1DFF)   // ... supplement
        || (cp >= 0x20D0 && cp <= 0x20FF)   // ... for symbols
        || (cp >= 0xFE20 && cp <= 0xFE2F);  // half marks
}

bool IsUtf8Nfc(std::string const& value)
{
    for (size_t i = 0; i < value.size();)
    {
        unsigned char c = static_cast<unsigned char>(value[i]);
        size_t count = c < 0x80 ? 1 : (c >= 0xc2 && c <= 0xdf ? 2 : (c >= 0xe0 && c <= 0xef ? 3 : (c >= 0xf0 && c <= 0xf4 ? 4 : 0)));
        if (!count || i + count > value.size()) return false;

        uint32_t cp = count == 1 ? c : (c & (0x7Fu >> count));
        for (size_t j = 1; j < count; ++j)
        {
            unsigned char cont = static_cast<unsigned char>(value[i + j]);
            if ((cont & 0xc0) != 0x80) return false;
            cp = (cp << 6) | (cont & 0x3Fu);
        }

        // Overlong encodings and surrogates are not well-formed UTF-8, and both
        // would let two different byte strings mean the same text.
        if (count == 2 && cp < 0x80) return false;
        if (count == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return false;
        if (count == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return false;

        if (IsCombiningMark(cp)) return false;

        i += count;
    }
    return true;
}

bool Take(std::vector<std::string> const& lines, size_t& cursor, std::string const& key, std::string& value)
{
    if (cursor >= lines.size()) return false;
    std::string prefix = key + "=";
    if (lines[cursor].compare(0, prefix.size(), prefix) != 0) return false;
    value = lines[cursor++].substr(prefix.size());
    return true;
}

std::string Ten(uint32_t value)
{
    std::ostringstream out;
    out << std::setw(10) << std::setfill('0') << value;
    return out.str();
}

bool UniquePositive(std::vector<uint32_t> const& guids)
{
    std::unordered_set<uint32_t> unique;
    for (uint32_t guid : guids)
        if (!guid || !unique.insert(guid).second)
            return false;
    return true;
}

bool StrictlyIncreasing(std::vector<uint32_t> const& guids)
{
    return std::adjacent_find(guids.begin(), guids.end(), [](uint32_t left, uint32_t right) { return left >= right; }) == guids.end();
}
}

std::string RuntimeStateName(RuntimeState state)
{
    static char const* names[] = {"DISABLED", "LOADING", "STARTING", "HEALTHY", "DEGRADED", "INVALID_FAIL_CLOSED", "SHUTTING_DOWN", "STOPPED"};
    return names[static_cast<size_t>(state)];
}

std::string OperationTypeName(OperationType type)
{
    static char const* names[] = {"INITIALIZE", "EXPAND", "ADD", "REMOVE", "REPLACE", "ROLLBACK"};
    return names[static_cast<size_t>(type)];
}

Sha256 Hash(std::string const& bytes)
{
    Sha256 result{};
    SHA256(reinterpret_cast<unsigned char const*>(bytes.data()), bytes.size(), result.data());
    return result;
}

std::string Hex(Sha256 const& hash)
{
    std::ostringstream out;
    out << std::uppercase << std::hex << std::setfill('0');
    for (uint8_t byte : hash) out << std::setw(2) << static_cast<unsigned>(byte);
    return out.str();
}

bool ParseHex(std::string const& text, Sha256& hash)
{
    if (text.size() != 64) return false;
    for (size_t i = 0; i < hash.size(); ++i)
    {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int high = nibble(text[i * 2]), low = nibble(text[i * 2 + 1]);
        if (high < 0 || low < 0) return false;
        hash[i] = static_cast<uint8_t>((high << 4) | low);
    }
    return true;
}

bool ReadCanonicalAdminRequestFile(std::string const& fileName, std::string& bytes, std::string& error)
{
    namespace fs = std::filesystem;
    bytes.clear();
    if (fileName.empty()) { error = "REQUEST_FILE_REQUIRED"; return false; }
    fs::path path(fileName);
    if (!path.is_absolute()) { error = "ABSOLUTE_REQUEST_PATH_REQUIRED"; return false; }
    for (fs::path const& component : path)
        if (component == "..") { error = "PARENT_COMPONENT_FORBIDDEN"; return false; }

    fs::path cursor = path.root_path();
    std::error_code ec;
    for (fs::path const& component : path.relative_path())
    {
        cursor /= component;
#if defined(_WIN32)
        DWORD attributes = GetFileAttributesW(cursor.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) { error = "REQUEST_PATH_COMPONENT_UNREADABLE"; return false; }
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) { error = "REQUEST_PATH_REPARSE_FORBIDDEN"; return false; }
#else
        if (fs::is_symlink(fs::symlink_status(cursor, ec)) || ec) { error = "REQUEST_PATH_SYMLINK_FORBIDDEN"; return false; }
#endif
    }
    if (!fs::is_regular_file(path, ec) || ec) { error = "REQUEST_PATH_NOT_REGULAR_FILE"; return false; }
    uintmax_t size = fs::file_size(path, ec);
    if (ec || !size || size > 1024 * 1024) { error = "REQUEST_FILE_SIZE_INVALID"; return false; }
    std::ifstream input(path, std::ios::binary);
    if (!input) { error = "REQUEST_FILE_OPEN_FAILED"; return false; }
    bytes.assign(static_cast<size_t>(size), '\0');
    input.read(&bytes[0], static_cast<std::streamsize>(size));
    if (input.gcount() != static_cast<std::streamsize>(size) || input.bad())
    {
        bytes.clear(); error = "REQUEST_FILE_READ_FAILED"; return false;
    }
    if (input.peek() != std::char_traits<char>::eof())
    {
        bytes.clear(); error = "REQUEST_FILE_CHANGED_DURING_READ"; return false;
    }
    return true;
}

bool IsRosterAdminTransportAllowed(AdminTransport transport)
{
    return transport == AdminTransport::LOCAL_CONSOLE;
}

std::string EvaluateRosterApplyGate(bool enabled, bool servicePresent, bool maintenanceMode,
    uint32_t reportedOnline, bool discoveredOnline)
{
    if (!enabled || !servicePresent)
        return "ROSTER_DISABLED";
    if (!maintenanceMode)
        return "MAINTENANCE_MODE_REQUIRED";
    if (reportedOnline != 0 || discoveredOnline)
        return "ROSTER_BOTS_ONLINE";
    return {};
}

std::string EvaluateRosterAccountAdmission(bool characterExists, bool accountExists, bool rndbotStock,
    bool banned, bool loginRecordExists, bool accountActive, uint32_t accountLockFlags,
    bool registeredSession)
{
    if (!characterExists)
        return "CHARACTER_NOT_FOUND";
    if (!accountExists)
        return "ACCOUNT_NOT_FOUND";
    if (!rndbotStock)
        return "ACCOUNT_NOT_RNDBOT_STOCK";
    if (banned)
        return "ACCOUNT_BANNED";
    if (!loginRecordExists)
        return "ACCOUNT_LOGIN_RECORD_NOT_FOUND";
    if (!accountActive)
        return "ACCOUNT_INACTIVE";
    if (accountLockFlags != 0)
        return "ACCOUNT_LOCKED";
    if (registeredSession)
        return "ACCOUNT_HAS_REGISTERED_SESSION";
    return {};
}

RuntimeBehaviorPolicy EvaluateRuntimeBehaviorPolicy(bool persistentRosterMember, bool grouped)
{
    RuntimeBehaviorPolicy policy;
    if (persistentRosterMember)
    {
        policy.leaseLogout = false;
        policy.populationRotation = false;
        policy.randomizeProgression = false;
        policy.randomStrategyReassignment = false;
        policy.randomTeleport = false;
        policy.automaticGroupRemoval = false;
    }
    else if (grouped)
    {
        policy.randomizeProgression = false;
        policy.randomStrategyReassignment = false;
        policy.randomTeleport = false;
    }
    return policy;
}

bool SerializeSnapshot(std::vector<uint32_t> const& guids, std::string& bytes, std::string& error)
{
    if (!UniquePositive(guids))
    {
        error = "SNAPSHOT_DUPLICATE_OR_ZERO_GUID";
        return false;
    }
    std::ostringstream out;
    out << "ssc-rndbot-roster-v1\n" << "schema_version=1\n" << "ordinal_base=1\n" << "member_count=" << guids.size() << "\n";
    for (size_t i = 0; i < guids.size(); ++i)
        out << Ten(static_cast<uint32_t>(i + 1)) << '\t' << Ten(guids[i]) << '\n';
    bytes = out.str();
    return true;
}

bool SerializeAdminRequest(AdminRequest const& request, std::string& bytes, std::string& error)
{
    if (request.schemaVersion != 1 || !ValidUuidV4(request.operationId) || request.actor.empty() ||
        !IsUtf8Nfc(request.actor) || !IsUtf8Nfc(request.reason) ||
        (request.hasExpectedCurrentVersionId && !request.expectedCurrentVersionId) ||
        (request.hasRollbackVersionId && !request.rollbackVersionId))
    {
        error = "INVALID_REQUEST_ID_OR_TEXT";
        return false;
    }
    if (!UniquePositive(request.add) || !UniquePositive(request.remove))
    {
        error = "INVALID_GUID_LIST";
        return false;
    }
    if (!StrictlyIncreasing(request.remove))
    {
        error = "NON_CANONICAL_REMOVE_ORDER";
        return false;
    }
    std::unordered_set<uint32_t> replacementNewGuids;
    uint32_t previousOldGuid = 0;
    for (size_t index = 0; index < request.replace.size(); ++index)
    {
        ReplaceEntry const& item = request.replace[index];
        if (item.ordinal != index + 1 || !item.oldGuid || !item.newGuid || item.oldGuid <= previousOldGuid ||
            !replacementNewGuids.insert(item.newGuid).second)
        {
            error = "NON_CANONICAL_REPLACE_LIST";
            return false;
        }
        previousOldGuid = item.oldGuid;
    }
    std::ostringstream out;
    out << "ssc-rndbot-admin-request-v1\n";
    out << "schema_version=1\n";
    out << "operation_id=" << request.operationId << "\n";
    out << "operation_type=" << OperationTypeName(request.operationType) << "\n";
    out << "expected_current_version_id=" << (request.hasExpectedCurrentVersionId ? std::to_string(request.expectedCurrentVersionId) : "null") << "\n";
    out << "actor_utf8_b64url=" << EncodeBase64Url(request.actor) << "\n";
    out << "reason_utf8_b64url=" << EncodeBase64Url(request.reason) << "\n";
    out << "requested_target_count=" << request.requestedTargetCount << "\n";
    out << "add_count=" << request.add.size() << "\n";
    for (size_t i = 0; i < request.add.size(); ++i) out << "add\t" << Ten(static_cast<uint32_t>(i + 1)) << '\t' << Ten(request.add[i]) << '\n';
    out << "remove_count=" << request.remove.size() << "\n";
    for (size_t i = 0; i < request.remove.size(); ++i) out << "remove\t" << Ten(static_cast<uint32_t>(i + 1)) << '\t' << Ten(request.remove[i]) << '\n';
    out << "replace_count=" << request.replace.size() << "\n";
    for (ReplaceEntry const& item : request.replace) out << "replace\t" << Ten(item.ordinal) << '\t' << Ten(item.oldGuid) << '\t' << Ten(item.newGuid) << '\n';
    out << "rollback_version_id=" << (request.hasRollbackVersionId ? std::to_string(request.rollbackVersionId) : "null") << "\n";
    bytes = out.str();
    return true;
}

bool ParseAdminRequest(std::string const& bytes, AdminRequest& request, std::string& error)
{
    if (bytes.empty() || bytes.back() != '\n' || bytes.find('\r') != std::string::npos || bytes.find('\0') != std::string::npos)
    {
        error = "NON_CANONICAL_LINE_ENCODING";
        return false;
    }
    std::vector<std::string> lines = SplitLines(bytes);
    size_t cursor = 0;
    if (lines.empty() || lines[cursor++] != "ssc-rndbot-admin-request-v1") { error = "BAD_MAGIC"; return false; }
    std::string value;
    uint64_t parsed = 0;
    if (!Take(lines, cursor, "schema_version", value) || value != "1") { error = "BAD_SCHEMA_VERSION"; return false; }
    if (!Take(lines, cursor, "operation_id", request.operationId) || !ValidUuidV4(request.operationId)) { error = "BAD_OPERATION_ID"; return false; }
    if (!Take(lines, cursor, "operation_type", value)) { error = "MISSING_OPERATION_TYPE"; return false; }
    bool typeFound = false;
    for (size_t i = 0; i < 6; ++i) if (value == OperationTypeName(static_cast<OperationType>(i))) { request.operationType = static_cast<OperationType>(i); typeFound = true; }
    if (!typeFound) { error = "BAD_OPERATION_TYPE"; return false; }
    if (!Take(lines, cursor, "expected_current_version_id", value) || !ParseNullablePositive(value, request.expectedCurrentVersionId, request.hasExpectedCurrentVersionId)) { error = "BAD_EXPECTED_VERSION"; return false; }
    std::string encoded;
    if (!Take(lines, cursor, "actor_utf8_b64url", encoded) || !DecodeBase64Url(encoded, request.actor) || request.actor.empty() || !IsUtf8Nfc(request.actor) || EncodeBase64Url(request.actor) != encoded) { error = "BAD_ACTOR"; return false; }
    if (!Take(lines, cursor, "reason_utf8_b64url", encoded) || !DecodeBase64Url(encoded, request.reason) || !IsUtf8Nfc(request.reason) || EncodeBase64Url(request.reason) != encoded) { error = "BAD_REASON"; return false; }
    if (!Take(lines, cursor, "requested_target_count", value)) { error = "BAD_TARGET_COUNT"; return false; }
    if (value == "0") request.requestedTargetCount = 0; else if (!ParseUnsigned(value, UINT32_MAX, parsed)) { error = "BAD_TARGET_COUNT"; return false; } else request.requestedTargetCount = static_cast<uint32_t>(parsed);
    auto parseList = [&](char const* key, std::vector<uint32_t>& target) -> bool {
        std::string countText;
        if (!Take(lines, cursor, std::string(key) + "_count", countText)) return false;
        uint64_t count = 0;
        if (countText != "0" && !ParseUnsigned(countText, UINT32_MAX, count)) return false;
        target.clear();
        for (uint64_t i = 1; i <= count; ++i)
        {
            if (cursor >= lines.size()) return false;
            std::vector<std::string> fields;
            std::string const& line = lines[cursor++];
            size_t p1 = line.find('\t'), p2 = p1 == std::string::npos ? p1 : line.find('\t', p1 + 1);
            if (p1 == std::string::npos || p2 == std::string::npos || line.find('\t', p2 + 1) != std::string::npos || line.substr(0, p1) != key) return false;
            uint64_t ordinal = 0, guid = 0;
            if (!ParseUnsigned(line.substr(p1 + 1, p2 - p1 - 1), UINT32_MAX, ordinal, true) || ordinal != i || !ParseUnsigned(line.substr(p2 + 1), UINT32_MAX, guid, true)) return false;
            target.push_back(static_cast<uint32_t>(guid));
        }
        return UniquePositive(target);
    };
    if (!parseList("add", request.add)) { error = "BAD_ADD_LIST"; return false; }
    if (!parseList("remove", request.remove)) { error = "BAD_REMOVE_LIST"; return false; }
    if (!Take(lines, cursor, "replace_count", value)) { error = "BAD_REPLACE_COUNT"; return false; }
    uint64_t replaceCount = 0;
    if (value != "0" && !ParseUnsigned(value, UINT32_MAX, replaceCount)) { error = "BAD_REPLACE_COUNT"; return false; }
    request.replace.clear();
    for (uint64_t i = 1; i <= replaceCount; ++i)
    {
        if (cursor >= lines.size()) { error = "BAD_REPLACE_LIST"; return false; }
        std::istringstream row(lines[cursor++]);
        std::string tag, ordinalText, oldText, newText, extra;
        if (!std::getline(row, tag, '\t') || !std::getline(row, ordinalText, '\t') || !std::getline(row, oldText, '\t') || !std::getline(row, newText, '\t') || std::getline(row, extra, '\t') || tag != "replace") { error = "BAD_REPLACE_LIST"; return false; }
        uint64_t ordinal = 0, oldGuid = 0, newGuid = 0;
        if (!ParseUnsigned(ordinalText, UINT32_MAX, ordinal, true) || ordinal != i || !ParseUnsigned(oldText, UINT32_MAX, oldGuid, true) || !ParseUnsigned(newText, UINT32_MAX, newGuid, true)) { error = "BAD_REPLACE_LIST"; return false; }
        request.replace.push_back({static_cast<uint32_t>(ordinal), static_cast<uint32_t>(oldGuid), static_cast<uint32_t>(newGuid)});
    }
    if (!Take(lines, cursor, "rollback_version_id", value) || !ParseNullablePositive(value, request.rollbackVersionId, request.hasRollbackVersionId) || cursor != lines.size()) { error = "BAD_ROLLBACK_OR_EXTRA_FIELDS"; return false; }
    std::string roundTrip;
    if (!SerializeAdminRequest(request, roundTrip, error) || roundTrip != bytes) { error = "NON_CANONICAL_REQUEST"; return false; }
    return true;
}

Service::Service(std::unique_ptr<Store> store) : store_(std::move(store)) {}

bool Service::ValidateSnapshot(Snapshot& snapshot, std::string& error) const
{
    std::string canonical;
    if (!snapshot.versionId || !SerializeSnapshot(snapshot.guids, canonical, error)) return false;
    if (Hash(canonical) != snapshot.sha256) { error = "SNAPSHOT_HASH_MISMATCH"; return false; }
    return true;
}

bool Service::Start(bool enabled, bool asyncLogin, std::string& error)
{
    members_.clear(); available_.clear(); unavailable_.clear(); online_.clear(); diagnostics_.clear(); current_ = Snapshot{}; hasCurrent_ = false; storeReady_ = false; lastDiagnostic_.clear();
    if (!enabled) { state_ = RuntimeState::DISABLED; return true; }
    state_ = RuntimeState::LOADING;
    if (asyncLogin) { state_ = RuntimeState::INVALID_FAIL_CLOSED; error = "ASYNC_LOGIN_UNSUPPORTED"; return false; }
    if (!store_ || !store_->VerifySchema(error)) { state_ = RuntimeState::INVALID_FAIL_CLOSED; return false; }
    storeReady_ = true;
    bool found = false;
    if (!store_->LoadCurrent(current_, found, error)) { state_ = RuntimeState::INVALID_FAIL_CLOSED; return false; }
    if (!found) { state_ = RuntimeState::INVALID_FAIL_CLOSED; error = "NO_CURRENT_ROSTER_VERSION"; return false; }
    if (!ValidateSnapshot(current_, error)) { state_ = RuntimeState::INVALID_FAIL_CLOSED; return false; }
    hasCurrent_ = true;
    members_.insert(current_.guids.begin(), current_.guids.end());
    state_ = RuntimeState::STARTING;
    return true;
}

void Service::Stop()
{
    state_ = RuntimeState::SHUTTING_DOWN;
    state_ = RuntimeState::STOPPED;
}

ApplyResult Service::Reject(std::string const& code, Sha256 const& requestSha256)
{
    ApplyResult result; result.code = code; result.requestSha256 = requestSha256; return result;
}

bool Service::BuildAfter(AdminRequest const& request, Snapshot& after, std::string& error)
{
    if (request.operationType == OperationType::INITIALIZE)
    {
        if (hasCurrent_ || request.hasExpectedCurrentVersionId || request.hasRollbackVersionId || request.add.empty() || !request.remove.empty() || !request.replace.empty()) { error = "INVALID_INITIALIZE_CONTEXT"; return false; }
        after.guids = request.add;
    }
    else
    {
        if (!hasCurrent_ || !request.hasExpectedCurrentVersionId || request.expectedCurrentVersionId != current_.versionId) { error = "CURRENT_VERSION_MISMATCH"; return false; }
        after.guids = current_.guids;
        if (request.operationType == OperationType::EXPAND || request.operationType == OperationType::ADD)
        {
            if (request.add.empty() || !request.remove.empty() || !request.replace.empty() || request.hasRollbackVersionId) { error = "INVALID_APPEND_CONTEXT"; return false; }
            after.guids.insert(after.guids.end(), request.add.begin(), request.add.end());
        }
        else if (request.operationType == OperationType::REMOVE)
        {
            if (request.remove.empty() || !request.add.empty() || !request.replace.empty() || request.hasRollbackVersionId) { error = "INVALID_REMOVE_CONTEXT"; return false; }
            for (uint32_t guid : request.remove)
            {
                auto it = std::find(after.guids.begin(), after.guids.end(), guid);
                if (it == after.guids.end()) { error = "REMOVE_GUID_NOT_PRESENT"; return false; }
                after.guids.erase(it);
            }
        }
        else if (request.operationType == OperationType::REPLACE)
        {
            if (request.replace.empty() || !request.add.empty() || !request.remove.empty() || request.hasRollbackVersionId) { error = "INVALID_REPLACE_CONTEXT"; return false; }
            for (ReplaceEntry const& entry : request.replace)
            {
                auto original = std::find(current_.guids.begin(), current_.guids.end(), entry.oldGuid);
                if (original == current_.guids.end()) { error = "REPLACE_OLD_GUID_NOT_PRESENT"; return false; }
                after.guids[static_cast<size_t>(std::distance(current_.guids.begin(), original))] = entry.newGuid;
            }
        }
        else if (request.operationType == OperationType::ROLLBACK)
        {
            if (!request.hasRollbackVersionId || !request.add.empty() || !request.remove.empty() || !request.replace.empty()) { error = "INVALID_ROLLBACK_CONTEXT"; return false; }
            bool found = false;
            Snapshot historical;
            if (!store_->LoadVersion(request.rollbackVersionId, historical, found, error) || !found || !ValidateSnapshot(historical, error)) { if (error.empty()) error = "ROLLBACK_VERSION_NOT_FOUND"; return false; }
            after.guids = historical.guids;
        }
    }
    if (after.guids.empty()) { error = "EMPTY_ROSTER_FORBIDDEN"; return false; }
    if (!UniquePositive(after.guids) || after.guids.size() != request.requestedTargetCount) { error = "TARGET_COUNT_OR_DUPLICATE_MISMATCH"; return false; }
    if (hasCurrent_ && current_.versionId == (std::numeric_limits<uint64_t>::max)())
    {
        error = "VERSION_ID_EXHAUSTED";
        return false;
    }
    after.versionId = hasCurrent_ ? current_.versionId + 1 : 1;
    std::string bytes;
    if (!SerializeSnapshot(after.guids, bytes, error)) return false;
    after.sha256 = Hash(bytes);
    return true;
}

ApplyResult Service::Apply(std::string const& canonicalRequest)
{
    if (!storeReady_)
        return Reject("STORE_NOT_VALIDATED");
    AdminRequest request;
    std::string error;
    if (!ParseAdminRequest(canonicalRequest, request, error)) return Reject(error.empty() ? "INVALID_REQUEST" : error);
    Sha256 requestHash = Hash(canonicalRequest);
    OperationRecord existing;
    bool found = false;
    if (!store_->FindOperation(request.operationId, existing, found, error)) return Reject("STORE_READ_FAILED", requestHash);
    if (found)
    {
        if (existing.requestSha256 != requestHash) return Reject("OPERATION_ID_REQUEST_MISMATCH", requestHash);
        ApplyResult replay; replay.accepted = true; replay.replayed = true; replay.restartRequired = true; replay.code = existing.resultCode; replay.versionId = existing.resultingVersionId; replay.requestSha256 = requestHash; replay.beforeSha256 = existing.beforeSha256; replay.afterSha256 = existing.afterSha256; return replay;
    }
    Snapshot after;
    if (!BuildAfter(request, after, error)) return Reject(error, requestHash);
    Snapshot before = current_;
    if (!hasCurrent_)
    {
        std::string emptySnapshot;
        if (!SerializeSnapshot({}, emptySnapshot, error))
            return Reject("EMPTY_SNAPSHOT_SERIALIZATION_FAILED", requestHash);
        before.sha256 = Hash(emptySnapshot);
    }
    bool transactionReplay = false;
    OperationRecord replayRecord;
    if (!store_->Commit(request, canonicalRequest, requestHash, before, hasCurrent_, after,
        "APPLIED_RESTART_REQUIRED", transactionReplay, replayRecord, error))
    {
        if (error == "OPERATION_ID_REQUEST_MISMATCH") return Reject(error, requestHash);
        if (error == "CURRENT_VERSION_MISMATCH") return Reject(error, requestHash);
        return Reject("TRANSACTION_FAILED", requestHash);
    }
    if (transactionReplay)
    {
        ApplyResult replay; replay.accepted = true; replay.replayed = true; replay.restartRequired = true;
        replay.code = replayRecord.resultCode; replay.versionId = replayRecord.resultingVersionId;
        replay.requestSha256 = requestHash; replay.beforeSha256 = replayRecord.beforeSha256; replay.afterSha256 = replayRecord.afterSha256;
        return replay;
    }

    // V1 never performs partial live reconciliation. A successful maintenance
    // operation persists the new version atomically and closes runtime admission
    // until an explicitly authorized restart reloads and revalidates it.
    state_ = RuntimeState::INVALID_FAIL_CLOSED;
    ApplyResult result; result.accepted = true; result.restartRequired = true; result.code = "APPLIED_RESTART_REQUIRED";
    result.versionId = after.versionId; result.requestSha256 = requestHash; result.beforeSha256 = before.sha256;
    result.afterSha256 = after.sha256; return result;
}

void Service::RecordAvailable(uint32_t guid)
{
    if (!IsMember(guid)) return;
    available_.insert(guid); unavailable_.erase(guid);
    if (online_.find(guid) == online_.end())
    {
        diagnostics_[guid] = "LOGIN_PENDING";
        if (state_ == RuntimeState::HEALTHY || state_ == RuntimeState::DEGRADED)
            state_ = RuntimeState::DEGRADED;
    }
}

void Service::RecordPending(uint32_t guid)
{
    if (!IsMember(guid)) return;
    online_.erase(guid);
    diagnostics_[guid] = "LOGIN_PENDING";
    if (state_ == RuntimeState::HEALTHY || state_ == RuntimeState::DEGRADED)
        state_ = RuntimeState::DEGRADED;
    else
        state_ = RuntimeState::STARTING;
}

void Service::RecordUnavailable(uint32_t guid, std::string const& diagnostic)
{
    if (!IsMember(guid)) return;
    online_.erase(guid); available_.erase(guid); unavailable_.insert(guid); diagnostics_[guid] = diagnostic;
    lastDiagnostic_ = diagnostic; state_ = RuntimeState::DEGRADED;
}

void Service::RecordOnline(uint32_t guid)
{
    if (!IsMember(guid)) return;
    online_.insert(guid); available_.insert(guid); unavailable_.erase(guid); diagnostics_.erase(guid);
    if (!unavailable_.empty() || !diagnostics_.empty()) state_ = RuntimeState::DEGRADED;
    else if (online_.size() == members_.size()) state_ = RuntimeState::HEALTHY;
    else state_ = RuntimeState::STARTING;
}

bool Service::IsMember(uint32_t guid) const { return members_.find(guid) != members_.end(); }
bool Service::CanAutomaticLogout(uint32_t guid) const { return !IsMember(guid); }
bool Service::CanAutomaticDelete(uint32_t guid) const { return !IsMember(guid); }
bool Service::CanAutomaticReplace(uint32_t guid) const { return !IsMember(guid); }
bool Service::CanRotationMutate(uint32_t guid) const { return !IsMember(guid); }

RuntimeStatus Service::Status() const
{
    RuntimeStatus status;
    status.state = state_;
    status.rosterVersionId = hasCurrent_ ? current_.versionId : 0;
    status.rosterSha256 = current_.sha256;
    status.rosterTarget = static_cast<uint32_t>(members_.size());
    status.rosterAvailable = static_cast<uint32_t>(available_.size());
    status.rosterOnline = static_cast<uint32_t>(online_.size());
    status.diagnostics.assign(diagnostics_.begin(), diagnostics_.end());
    return status;
}
}
}
