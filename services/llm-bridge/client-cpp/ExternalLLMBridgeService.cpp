#include "playerbot/ExternalLLMBridgeService.h"

#include "json.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cctype>
#include <cstdio>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <limits>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#endif

#ifndef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
#include "playerbot/playerbot.h"
#include "playerbot/PlayerbotAIConfig.h"
#include "ObjectAccessor.h"
#include "Objects/Player.h"
#include "WorldSession.h"
#endif

namespace
{
using Json = nlohmann::json;
using Clock = std::chrono::steady_clock;

constexpr char kModel[] = "qwen2.5:7b";
constexpr char kPayloadManifestHash[] = "814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B";
constexpr char kConfigHash[] = "D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902";
constexpr char kPersonalityHash[] = "386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E";
constexpr char kCliHash[] = "C5D2C01DB3AEBBBF65A2ECFACC1515326334220A5F79395DF3E24550345CA611";
constexpr std::chrono::milliseconds kRequestTtl(45000);

bool IsCanonicalUuidV4(std::string const& value)
{
    if (value.size() != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' || value[14] != '4')
        return false;
    if (value[19] != '8' && value[19] != '9' && value[19] != 'a' && value[19] != 'b')
        return false;
    for (std::size_t i = 0; i < value.size(); ++i)
    {
        if (i == 8 || i == 13 || i == 18 || i == 23)
            continue;
        if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f')))
            return false;
    }
    return true;
}

bool DecodeScalar(std::string const& value, std::size_t offset, std::uint32_t& scalar, std::size_t& count)
{
    if (offset >= value.size()) return false;
    unsigned char const first = static_cast<unsigned char>(value[offset]);
    scalar = 0;
    count = 0;
    if (first <= 0x7f)
    {
        scalar = first;
        count = 1;
    }
    else if (first >= 0xc2 && first <= 0xdf)
    {
        scalar = first & 0x1f;
        count = 2;
    }
    else if (first >= 0xe0 && first <= 0xef)
    {
        scalar = first & 0x0f;
        count = 3;
    }
    else if (first >= 0xf0 && first <= 0xf4)
    {
        scalar = first & 0x07;
        count = 4;
    }
    else
        return false;
    if (offset + count > value.size()) return false;
    for (std::size_t n = 1; n < count; ++n)
    {
        unsigned char const next = static_cast<unsigned char>(value[offset + n]);
        if ((next & 0xc0) != 0x80) return false;
        scalar = (scalar << 6) | (next & 0x3f);
    }
    return !((count == 2 && scalar < 0x80) || (count == 3 && scalar < 0x800) ||
        (count == 4 && scalar < 0x10000) || scalar > 0x10ffff ||
        (scalar >= 0xd800 && scalar <= 0xdfff));
}

bool DecodeUtf8(std::string const& value, std::size_t& codepoints, bool rejectControls)
{
    codepoints = 0;
    for (std::size_t i = 0; i < value.size();)
    {
        std::uint32_t scalar = 0;
        std::size_t count = 0;
        if (!DecodeScalar(value, i, scalar, count))
            return false;
        if (rejectControls && (scalar <= 0x1f || scalar == 0x7f))
            return false;
        ++codepoints;
        i += count;
    }
    return true;
}

bool IsEcmaTrimWhitespace(std::uint32_t scalar)
{
    return scalar == 0x0009 || scalar == 0x000a || scalar == 0x000b || scalar == 0x000c ||
        scalar == 0x000d || scalar == 0x0020 || scalar == 0x00a0 || scalar == 0x1680 ||
        (scalar >= 0x2000 && scalar <= 0x200a) || scalar == 0x2028 || scalar == 0x2029 ||
        scalar == 0x202f || scalar == 0x205f || scalar == 0x3000 || scalar == 0xfeff;
}

bool IsTrimEmpty(std::string const& value)
{
    if (value.empty()) return true;
    for (std::size_t i = 0; i < value.size();)
    {
        std::uint32_t scalar = 0;
        std::size_t width = 0;
        if (!DecodeScalar(value, i, scalar, width) || !IsEcmaTrimWhitespace(scalar)) return false;
        i += width;
    }
    return true;
}

bool IsCanonicalSanitizedText(std::string const& text)
{
    if (text.empty() || text.size() > 240 || text.front() == ' ' || text.back() == ' ')
        return false;
    std::size_t codepoints = 0;
    if (!DecodeUtf8(text, codepoints, true) || codepoints > 240)
        return false;

    std::size_t terminatorRuns = 0;
    bool inRun = false;
    for (std::size_t i = 0; i < text.size();)
    {
        std::uint32_t scalar = 0;
        std::size_t width = 0;
        if (!DecodeScalar(text, i, scalar, width)) return false;
        bool const nonAsciiEcmaWhitespace = scalar == 0x00a0 || scalar == 0x1680 ||
            (scalar >= 0x2000 && scalar <= 0x200a) || scalar == 0x2028 || scalar == 0x2029 ||
            scalar == 0x202f || scalar == 0x205f || scalar == 0x3000 || scalar == 0xfeff;
        if (nonAsciiEcmaWhitespace) return false;
        bool const terminator = scalar == '.' || scalar == '!' || scalar == '?' || scalar == 0x2026;
        if (terminator && !inRun)
            ++terminatorRuns;
        inRun = terminator;
        if (scalar == ' ' && i + 1 < text.size() && text[i + 1] == ' ')
            return false;
        i += width;
    }
    return terminatorRuns <= 2;
}

bool IsCanonicalTimestamp(std::string const& value)
{
    if (value.size() != 24 || value[4] != '-' || value[7] != '-' || value[10] != 'T' ||
        value[13] != ':' || value[16] != ':' || value[19] != '.' || value[23] != 'Z')
        return false;
    for (std::size_t i = 0; i < value.size(); ++i)
    {
        if (i == 4 || i == 7 || i == 10 || i == 13 || i == 16 || i == 19 || i == 23)
            continue;
        if (!std::isdigit(static_cast<unsigned char>(value[i])))
            return false;
    }
    auto number = [&](std::size_t offset, std::size_t count) {
        unsigned result = 0;
        for (std::size_t i = 0; i < count; ++i)
            result = result * 10 + static_cast<unsigned>(value[offset + i] - '0');
        return result;
    };
    unsigned const year = number(0, 4);
    unsigned const month = number(5, 2);
    unsigned const day = number(8, 2);
    unsigned const hour = number(11, 2);
    unsigned const minute = number(14, 2);
    unsigned const second = number(17, 2);
    if (year < 1 || month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59)
        return false;
    static unsigned const daysByMonth[] = { 31,28,31,30,31,30,31,31,30,31,30,31 };
    unsigned days = daysByMonth[month - 1];
    bool const leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    if (month == 2 && leap) ++days;
    return day >= 1 && day <= days;
}

std::string FormatUtc(std::chrono::system_clock::time_point const& now)
{
    auto const seconds = std::chrono::time_point_cast<std::chrono::seconds>(now);
    auto const milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(now - seconds).count();
    std::time_t value = std::chrono::system_clock::to_time_t(seconds);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &value);
#else
    gmtime_r(&value, &tm);
#endif
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << '.' << std::setw(3) << std::setfill('0') << milliseconds << 'Z';
    return out.str();
}

std::string NewUuidV4()
{
    std::array<unsigned char, 16> bytes{};
#ifdef _WIN32
    if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
        return {};
#else
    std::random_device source;
    for (auto& byte : bytes)
        byte = static_cast<unsigned char>(source());
#endif
    bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
    bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
    char out[37]{};
    std::snprintf(out, sizeof(out),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
    return out;
}

bool ExactFields(Json const& value, std::initializer_list<char const*> fields)
{
    if (!value.is_object() || value.size() != fields.size())
        return false;
    for (char const* field : fields)
        if (value.find(field) == value.end())
            return false;
    return true;
}

bool StrictJson(std::string const& line, Json& value)
{
    if (line.empty() || line.size() > ExternalLLMBridgeService::StdoutNdjsonLineCapBytes ||
        line.find('\0') != std::string::npos ||
        (line.size() >= 3 && static_cast<unsigned char>(line[0]) == 0xef &&
            static_cast<unsigned char>(line[1]) == 0xbb && static_cast<unsigned char>(line[2]) == 0xbf))
        return false;
    std::size_t codepoints = 0;
    if (!DecodeUtf8(line, codepoints, false))
        return false;

    bool duplicate = false;
    bool tooDeep = false;
    std::vector<std::set<std::string>> objectKeys;
    Json::parser_callback_t callback = [&](int depth, Json::parse_event_t event, Json& parsed) {
        if (depth > 32)
            tooDeep = true;
        if (event == Json::parse_event_t::object_start)
            objectKeys.emplace_back();
        else if (event == Json::parse_event_t::key)
        {
            if (objectKeys.empty() || !objectKeys.back().insert(parsed.get<std::string>()).second)
                duplicate = true;
        }
        else if (event == Json::parse_event_t::object_end && !objectKeys.empty())
            objectKeys.pop_back();
        return !duplicate && !tooDeep;
    };
    try
    {
        value = Json::parse(line, callback);
    }
    catch (...)
    {
        return false;
    }
    return !duplicate && !tooDeep && value.is_object();
}

bool IntegerInRange(Json const& value, std::uint64_t minimum, std::uint64_t maximum)
{
    if (!value.is_number_integer() && !value.is_number_unsigned())
        return false;
    try
    {
        if (value.is_number_unsigned())
        {
            std::uint64_t v = value.get<std::uint64_t>();
            return v >= minimum && v <= maximum;
        }
        std::int64_t v = value.get<std::int64_t>();
        return v >= 0 && static_cast<std::uint64_t>(v) >= minimum && static_cast<std::uint64_t>(v) <= maximum;
    }
    catch (...)
    {
        return false;
    }
}

std::set<std::string> const& TerminalErrors()
{
    static std::set<std::string> const values = {
        "shutdown_cancelled", "shutdown_timeout", "queue_full", "expired_before_run", "stale_result",
        "expired_before_consume", "completion_mismatch", "response_model_mismatch", "invalid_monotonic_deadline",
        "request_expired", "http_request_too_large", "inference_http_error", "invalid_content_length",
        "raw_response_too_large", "response_aborted", "http_response_error", "http_transport_error", "connect_failed",
        "connect_deadline", "response_deadline", "request_cancelled", "input_too_large", "utf8_bom_forbidden",
        "invalid_utf8", "invalid_json", "json_trailing_content", "json_depth_exceeded", "duplicate_json_key",
        "invalid_json_string", "invalid_json_number", "invalid_unicode_scalar", "schema_type_mismatch",
        "schema_missing_field", "schema_unknown_field", "invalid_inference_schema", "incomplete_inference_response",
        "invalid_assistant_role", "invalid_assistant_text", "empty_assistant_text", "assistant_text_too_long",
        "assistant_text_too_many_bytes", "too_many_sentences", "invalid_raw_response_bytes", "inference_failed"
    };
    return values;
}

bool KnownTerminalError(Json const& value)
{
    return value.is_string() && TerminalErrors().count(value.get<std::string>()) != 0;
}

bool ErrorAllowsAttempt(std::string const& error, std::uint64_t attempt);

bool ValidateStatus(Json const& value, std::string const& requestId, std::string* stateOut = nullptr)
{
    if (!IsCanonicalUuidV4(requestId) ||
        !ExactFields(value, { "schema_version", "request_id", "bot_guid", "state", "queued_utc", "updated_utc", "attempt_count", "error_code" }) ||
        !IntegerInRange(value["schema_version"], 1, 1) || !value["request_id"].is_string() ||
        value["request_id"].get<std::string>() != requestId || !IntegerInRange(value["bot_guid"], ExternalLLMBridgeService::BotGuid, ExternalLLMBridgeService::BotGuid) ||
        !value["state"].is_string() || !value["queued_utc"].is_string() || !value["updated_utc"].is_string() ||
        !IsCanonicalTimestamp(value["queued_utc"].get<std::string>()) || !IsCanonicalTimestamp(value["updated_utc"].get<std::string>()) ||
        !IntegerInRange(value["attempt_count"], 0, 1))
        return false;
    if (value["queued_utc"].get<std::string>() > value["updated_utc"].get<std::string>()) return false;

    std::string const state = value["state"].get<std::string>();
    std::uint64_t const attempt = value["attempt_count"].get<std::uint64_t>();
    if (state == "queued")
    {
        if (attempt != 0 || !value["error_code"].is_null()) return false;
    }
    else if (state == "running" || state == "ready")
    {
        if (attempt != 1 || !value["error_code"].is_null()) return false;
    }
    else if (state == "failed")
    {
        if (!KnownTerminalError(value["error_code"])) return false;
        std::string const error = value["error_code"].get<std::string>();
        if (error == "expired_before_run" || error == "stale_result" || error == "expired_before_consume" ||
            !ErrorAllowsAttempt(error, attempt)) return false;
    }
    else if (state == "expired")
    {
        if (!value["error_code"].is_string()) return false;
        std::string const error = value["error_code"].get<std::string>();
        if ((error != "expired_before_run" && error != "stale_result" && error != "expired_before_consume") ||
            !ErrorAllowsAttempt(error, attempt)) return false;
    }
    else if (state == "consumed")
    {
        if (value["error_code"].is_null())
        {
            if (attempt != 1) return false;
        }
        else if (!KnownTerminalError(value["error_code"]) ||
            !ErrorAllowsAttempt(value["error_code"].get<std::string>(), attempt)) return false;
    }
    else
        return false;
    if (stateOut) *stateOut = state;
    return true;
}

struct Completion
{
    std::string requestId;
    std::uint64_t botGuid = 0;
    std::string outcome;
    std::string model;
    std::uint64_t attemptCount = 0;
    std::string startedUtc;
    std::string completedUtc;
    std::string text;
    std::string errorCode;
    bool errorIsNull = false;
    std::uint64_t rawResponseBytes = 0;
    bool rawResponseBytesIsNull = false;
};

bool ErrorAllowsAttempt(std::string const& error, std::uint64_t attempt)
{
    if (error == "queue_full" || error == "expired_before_run") return attempt == 0;
    if (error == "shutdown_cancelled" || error == "shutdown_timeout") return attempt <= 1;
    return attempt == 1;
}

bool ValidateCompletion(Json const& value, std::string const& requestId, Completion& result)
{
    if (!IsCanonicalUuidV4(requestId) ||
        !ExactFields(value, { "schema_version", "request_id", "bot_guid", "outcome", "model", "attempt_count", "started_utc", "completed_utc", "text", "error_code", "raw_response_bytes" }) ||
        !IntegerInRange(value["schema_version"], 1, 1) || !value["request_id"].is_string() || value["request_id"].get<std::string>() != requestId ||
        !IntegerInRange(value["bot_guid"], ExternalLLMBridgeService::BotGuid, ExternalLLMBridgeService::BotGuid) ||
        !value["outcome"].is_string() || !IntegerInRange(value["attempt_count"], 0, 1) ||
        !value["completed_utc"].is_string() || !IsCanonicalTimestamp(value["completed_utc"].get<std::string>()))
        return false;

    result.requestId = value["request_id"].get<std::string>();
    result.botGuid = value["bot_guid"].get<std::uint64_t>();
    result.outcome = value["outcome"].get<std::string>();
    result.attemptCount = value["attempt_count"].get<std::uint64_t>();
    result.completedUtc = value["completed_utc"].get<std::string>();
    std::uint64_t const attempt = value["attempt_count"].get<std::uint64_t>();
    if (result.outcome == "ready")
    {
        if (attempt != 1 || !value["model"].is_string() || value["model"].get<std::string>() != kModel ||
            !value["started_utc"].is_string() || !IsCanonicalTimestamp(value["started_utc"].get<std::string>()) ||
            !value["text"].is_string() || !value["error_code"].is_null() || !IntegerInRange(value["raw_response_bytes"], 0, 65536))
            return false;
        result.model = value["model"].get<std::string>();
        result.startedUtc = value["started_utc"].get<std::string>();
        if (result.startedUtc > result.completedUtc) return false;
        result.text = value["text"].get<std::string>();
        result.errorCode.clear();
        result.errorIsNull = true;
        result.rawResponseBytes = value["raw_response_bytes"].get<std::uint64_t>();
        result.rawResponseBytesIsNull = false;
        return IsCanonicalSanitizedText(result.text);
    }
    if (result.outcome != "failed" && result.outcome != "expired")
        return false;
    if (!value["text"].is_null() || !KnownTerminalError(value["error_code"]))
        return false;
    std::string const error = value["error_code"].get<std::string>();
    if (!ErrorAllowsAttempt(error, attempt)) return false;
    bool const expiryError = error == "expired_before_run" || error == "stale_result" || error == "expired_before_consume";
    if ((result.outcome == "expired") != expiryError)
        return false;
    if (attempt == 0)
    {
        if (!value["started_utc"].is_null() || !value["model"].is_null() || !value["raw_response_bytes"].is_null())
            return false;
        if (error != "queue_full" && error != "expired_before_run" && error != "shutdown_cancelled" && error != "shutdown_timeout") return false;
    }
    else
    {
        if (!value["started_utc"].is_string() || !IsCanonicalTimestamp(value["started_utc"].get<std::string>()) ||
            (!value["model"].is_null() && (!value["model"].is_string() || value["model"].get<std::string>() != kModel)) ||
            (!value["raw_response_bytes"].is_null() && !IntegerInRange(value["raw_response_bytes"], 0, 65536)))
            return false;
        if (value["started_utc"].get<std::string>() > result.completedUtc) return false;
    }
    result.model = value["model"].is_null() ? std::string() : value["model"].get<std::string>();
    result.startedUtc = value["started_utc"].is_null() ? std::string() : value["started_utc"].get<std::string>();
    result.text.clear();
    result.errorCode = error;
    result.errorIsNull = false;
    result.rawResponseBytesIsNull = value["raw_response_bytes"].is_null();
    result.rawResponseBytes = result.rawResponseBytesIsNull ? 0 : value["raw_response_bytes"].get<std::uint64_t>();
    return true;
}

bool ValidateMetrics(Json const& value, bool stopped)
{
    if (!ExactFields(value, { "lifecycle", "accepting", "waiting", "ledger_entries", "active", "max_active_observed", "inference_attempts", "stale_results_discarded", "worker_owned", "worker_settled" }) ||
        !value["lifecycle"].is_string() || !value["accepting"].is_boolean() ||
        !IntegerInRange(value["waiting"], 0, 2) || !IntegerInRange(value["ledger_entries"], 0, 64) ||
        !IntegerInRange(value["active"], 0, 1) || !IntegerInRange(value["max_active_observed"], 0, 1) ||
        !IntegerInRange(value["inference_attempts"], 0, 64) || !IntegerInRange(value["stale_results_discarded"], 0, std::numeric_limits<std::uint64_t>::max()) ||
        !value["worker_owned"].is_boolean() || !value["worker_settled"].is_boolean())
        return false;
    static std::set<std::string> const lifecycle = { "new", "starting", "running", "stopping", "stopped", "failed" };
    if (!lifecycle.count(value["lifecycle"].get<std::string>()))
        return false;
    if (stopped && (value["lifecycle"].get<std::string>() != "stopped" || value["accepting"].get<bool>() ||
        value["waiting"].get<std::uint64_t>() != 0 || value["active"].get<std::uint64_t>() != 0 ||
        !value["worker_owned"].get<bool>() || !value["worker_settled"].get<bool>()))
        return false;
    return true;
}

enum class CommandKind { None, Submit, Status, Consume, Metrics, Shutdown };

struct ResponseDisposition
{
    bool valid = false;
    bool ledgerFull = false;
    bool terminal = false;
    bool consumed = false;
    bool alreadyConsumed = false;
    std::string statusState;
    Completion completion;
};

bool IsCommandError(Json const& value)
{
    return ExactFields(value, { "code", "message" }) && value["code"].is_string() &&
        !value["code"].get<std::string>().empty() && value["message"].is_string();
}

bool IsFatalTopLevelError(Json const& value)
{
    return ExactFields(value, { "result", "code", "message" }) && value["result"].is_string() &&
        value["result"].get<std::string>() == "PHASE1A_BRIDGE_ERROR" && value["code"].is_string() &&
        !value["code"].get<std::string>().empty() && value["message"].is_string();
}

ResponseDisposition ValidateResponse(CommandKind kind, Json const& value, std::string const& requestId)
{
    ResponseDisposition out;
    if (IsCommandError(value))
        return out;
    if (kind == CommandKind::Submit)
    {
        if (!ExactFields(value, { "accepted", "code", "status" }) || !value["accepted"].is_boolean() || !value["code"].is_string())
            return out;
        std::string const code = value["code"].get<std::string>();
        bool const accepted = value["accepted"].get<bool>();
        if (code == "ledger_full")
        {
            out.valid = !accepted && value["status"].is_null();
            out.ledgerFull = out.valid;
            return out;
        }
        if (code == "identity_mismatch")
        {
            out.valid = !accepted && value["status"].is_null();
            return out;
        }
        if (code != "queued" && code != "duplicate" && code != "queue_full" && code != "expired")
            return out;
        if (accepted != (code == "queued") || value["status"].is_null() || !ValidateStatus(value["status"], requestId, &out.statusState))
            return out;
        if ((code == "queued" && out.statusState != "queued") || (code == "queue_full" && out.statusState != "failed") ||
            (code == "expired" && out.statusState != "expired"))
            return out;
        if (code == "queue_full" && (value["status"]["attempt_count"].get<std::uint64_t>() != 0 ||
            value["status"]["error_code"].get<std::string>() != "queue_full")) return out;
        if (code == "expired" && (value["status"]["attempt_count"].get<std::uint64_t>() != 0 ||
            value["status"]["error_code"].get<std::string>() != "expired_before_run")) return out;
        out.valid = true;
        out.terminal = out.statusState == "ready" || out.statusState == "failed" || out.statusState == "expired" || out.statusState == "consumed";
        return out;
    }
    if (kind == CommandKind::Status)
    {
        if (!ExactFields(value, { "code", "status" }) || !value["code"].is_string())
            return out;
        std::string const code = value["code"].get<std::string>();
        if (code == "ok")
        {
            if (value["status"].is_null() || !ValidateStatus(value["status"], requestId, &out.statusState)) return out;
            out.valid = true;
            out.terminal = out.statusState == "ready" || out.statusState == "failed" || out.statusState == "expired" || out.statusState == "consumed";
            return out;
        }
        if (code == "invalid_uuid" || code == "invalid_bot_guid" || code == "not_found" || code == "identity_mismatch")
            out.valid = value["status"].is_null();
        return out;
    }
    if (kind == CommandKind::Consume)
    {
        if (!ExactFields(value, { "code", "status", "completion" }) || !value["code"].is_string())
            return out;
        std::string const code = value["code"].get<std::string>();
        if (code == "consumed")
        {
            if (value["status"].is_null() || value["completion"].is_null() ||
                !ValidateStatus(value["status"], requestId, &out.statusState) || out.statusState != "consumed" ||
                !ValidateCompletion(value["completion"], requestId, out.completion)) return out;
            if (value["status"]["attempt_count"] != value["completion"]["attempt_count"] ||
                value["status"]["error_code"] != value["completion"]["error_code"]) return out;
            out.valid = out.consumed = true;
            return out;
        }
        if (code == "not_ready")
        {
            if (value["status"].is_null() || !value["completion"].is_null() ||
                !ValidateStatus(value["status"], requestId, &out.statusState) ||
                (out.statusState != "queued" && out.statusState != "running")) return out;
            out.valid = true;
            return out;
        }
        if (code == "already_consumed")
        {
            if (value["status"].is_null() || !value["completion"].is_null() ||
                !ValidateStatus(value["status"], requestId, &out.statusState) || out.statusState != "consumed") return out;
            out.valid = out.alreadyConsumed = true;
            return out;
        }
        if (code == "invalid_uuid" || code == "invalid_bot_guid" || code == "not_found" || code == "identity_mismatch")
            out.valid = value["status"].is_null() && value["completion"].is_null();
        return out;
    }
    if (kind == CommandKind::Metrics)
    {
        out.valid = ExactFields(value, { "code", "metrics" }) && value["code"].is_string() &&
            value["code"].get<std::string>() == "metrics" && ValidateMetrics(value["metrics"], false);
        return out;
    }
    if (kind == CommandKind::Shutdown)
    {
        out.valid = ExactFields(value, { "code", "metrics" }) && value["code"].is_string() &&
            value["code"].get<std::string>() == "shutdown" && ValidateMetrics(value["metrics"], true);
        return out;
    }
    return out;
}

bool ValidateReady(Json const& value)
{
    return ExactFields(value, { "code", "mode", "active_limit", "waiting_capacity", "ledger_capacity", "bot_guid", "model" }) &&
        value["code"].is_string() && value["code"].get<std::string>() == "ready" &&
        value["mode"].is_string() && value["mode"].get<std::string>() == "server_free_ndjson" &&
        IntegerInRange(value["active_limit"], 1, 1) && IntegerInRange(value["waiting_capacity"], 2, 2) &&
        IntegerInRange(value["ledger_capacity"], 64, 64) && IntegerInRange(value["bot_guid"], ExternalLLMBridgeService::BotGuid, ExternalLLMBridgeService::BotGuid) &&
        value["model"].is_string() && value["model"].get<std::string>() == kModel;
}

struct Route
{
    enum class Phase { PendingSubmit, Accepted, Terminal, Consuming, DeliveryPending };
    std::string requestId;
    std::uint64_t botGuid = 0;
    std::uint64_t targetGuid = 0;
    std::string targetName;
    std::string message;
    ExternalLLMBridgeService::SessionFingerprint botSession;
    ExternalLLMBridgeService::SessionFingerprint targetSession;
    std::string createdUtc;
    std::string expiresUtc;
    Clock::time_point deadline;
    Phase phase = Phase::PendingSubmit;
};

struct Delivery
{
    Route route;
    Completion completion;
};

bool ValidateDeliveryEvidence(Route const& route, Completion const& completion, Clock::time_point now)
{
    return now < route.deadline && IsCanonicalUuidV4(route.requestId) &&
        route.botGuid == ExternalLLMBridgeService::BotGuid &&
        completion.requestId == route.requestId && completion.botGuid == route.botGuid &&
        completion.outcome == "ready" && completion.model == kModel && completion.attemptCount == 1 &&
        !completion.startedUtc.empty() && IsCanonicalTimestamp(completion.startedUtc) &&
        IsCanonicalTimestamp(completion.completedUtc) && completion.startedUtc <= completion.completedUtc &&
        completion.errorIsNull && completion.errorCode.empty() && !completion.rawResponseBytesIsNull &&
        completion.rawResponseBytes <= 65536 && IsCanonicalSanitizedText(completion.text);
}

#ifdef _WIN32
class UniqueHandle
{
public:
    UniqueHandle() = default;
    explicit UniqueHandle(HANDLE value) : m_value(value) {}
    ~UniqueHandle() { Reset(); }
    UniqueHandle(UniqueHandle const&) = delete;
    UniqueHandle& operator=(UniqueHandle const&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : m_value(other.Release()) {}
    UniqueHandle& operator=(UniqueHandle&& other) noexcept { if (this != &other) Reset(other.Release()); return *this; }
    HANDLE Get() const { return m_value; }
    bool Valid() const { return m_value != nullptr && m_value != INVALID_HANDLE_VALUE; }
    HANDLE Release() { HANDLE value = m_value; m_value = nullptr; return value; }
    void Reset(HANDLE value = nullptr) { if (Valid()) CloseHandle(m_value); m_value = value; }
private:
    HANDLE m_value = nullptr;
};

std::wstring Utf8ToWide(std::string const& value)
{
    if (value.empty()) return {};
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (count <= 0) return {};
    std::wstring result(static_cast<std::size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), &result[0], count) != count) return {};
    return result;
}

std::wstring QuoteWindowsArg(std::wstring const& value)
{
    if (value.find_first_of(L" \t\"") == std::wstring::npos) return value;
    std::wstring result = L"\"";
    std::size_t slashes = 0;
    for (wchar_t c : value)
    {
        if (c == L'\\') { ++slashes; continue; }
        if (c == L'\"') { result.append(slashes * 2 + 1, L'\\'); result.push_back(c); slashes = 0; continue; }
        result.append(slashes, L'\\'); slashes = 0; result.push_back(c);
    }
    result.append(slashes * 2, L'\\');
    result.push_back(L'\"');
    return result;
}

std::wstring NewPipeName()
{
    std::string const uuid = NewUuidV4();
    std::wstring suffix(uuid.begin(), uuid.end());
    return L"\\\\.\\pipe\\ssc-llm-bridge-" + std::to_wstring(GetCurrentProcessId()) + L"-" + suffix;
}

bool CreateOverlappedPipePair(bool parentReads, UniqueHandle& parent, UniqueHandle& child)
{
    std::wstring const name = NewPipeName();
    if (name.empty()) return false;
    DWORD const openMode = (parentReads ? PIPE_ACCESS_INBOUND : PIPE_ACCESS_OUTBOUND) |
        FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE;
    UniqueHandle server(CreateNamedPipeW(name.c_str(), openMode, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        1, 65536, 65536, 0, nullptr));
    if (!server.Valid()) return false;

    UniqueHandle connected(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!connected.Valid()) return false;
    OVERLAPPED overlap{};
    overlap.hEvent = connected.Get();
    BOOL connectResult = ConnectNamedPipe(server.Get(), &overlap);
    DWORD connectError = connectResult ? ERROR_SUCCESS : GetLastError();
    if (!connectResult && connectError != ERROR_IO_PENDING && connectError != ERROR_PIPE_CONNECTED) return false;

    SECURITY_ATTRIBUTES inheritable{ sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE };
    DWORD const childAccess = parentReads ? GENERIC_WRITE : GENERIC_READ;
    UniqueHandle client(CreateFileW(name.c_str(), childAccess, 0, &inheritable, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!client.Valid())
    {
        if (connectError == ERROR_IO_PENDING) CancelIoEx(server.Get(), &overlap);
        return false;
    }
    if (connectError == ERROR_IO_PENDING)
    {
        DWORD ignored = 0;
        if (!GetOverlappedResult(server.Get(), &overlap, &ignored, TRUE)) return false;
    }
    if (!SetHandleInformation(server.Get(), HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(client.Get(), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) return false;
    parent = std::move(server);
    child = std::move(client);
    return true;
}

struct OverlappedRead
{
    UniqueHandle event;
    OVERLAPPED overlap{};
    std::array<char, 4096> buffer{};
    bool pending = false;

    bool Initialize()
    {
        event.Reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        overlap = OVERLAPPED{};
        overlap.hEvent = event.Get();
        return event.Valid();
    }
};

bool PumpOverlappedRead(HANDLE handle, OverlappedRead& operation, std::string& output, bool& eof)
{
    eof = false;
    DWORD count = 0;
    if (operation.pending)
    {
        if (!GetOverlappedResult(handle, &operation.overlap, &count, FALSE))
        {
            DWORD const error = GetLastError();
            if (error == ERROR_IO_INCOMPLETE) return true;
            operation.pending = false;
            eof = error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED;
            return eof;
        }
        operation.pending = false;
        if (count == 0) { eof = true; return true; }
        output.append(operation.buffer.data(), count);
    }

    ResetEvent(operation.event.Get());
    operation.overlap = OVERLAPPED{};
    operation.overlap.hEvent = operation.event.Get();
    count = 0;
    if (ReadFile(handle, operation.buffer.data(), static_cast<DWORD>(operation.buffer.size()), &count, &operation.overlap))
    {
        if (count == 0) eof = true;
        else output.append(operation.buffer.data(), count);
        return true;
    }
    DWORD const error = GetLastError();
    if (error == ERROR_IO_PENDING) { operation.pending = true; return true; }
    eof = error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED;
    return eof;
}

void CancelAndDrainOverlappedRead(HANDLE handle, OverlappedRead& operation)
{
    if (!operation.pending) return;
    CancelIoEx(handle, &operation.overlap);
    DWORD ignored = 0;
    GetOverlappedResult(handle, &operation.overlap, &ignored, TRUE);
    operation.pending = false;
}

enum class WriteResult { Complete, Cancelled, Failed };

WriteResult WriteAllOverlapped(HANDLE handle, HANDLE process, std::string const& data,
    std::function<bool()> const& shouldCancel)
{
    UniqueHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.Valid()) return WriteResult::Failed;
    std::size_t offset = 0;
    while (offset < data.size())
    {
        OVERLAPPED overlap{};
        overlap.hEvent = event.Get();
        ResetEvent(event.Get());
        DWORD written = 0;
        DWORD const amount = static_cast<DWORD>(data.size() - offset);
        BOOL const immediate = WriteFile(handle, data.data() + offset, amount, &written, &overlap);
        if (!immediate)
        {
            DWORD const error = GetLastError();
            if (error != ERROR_IO_PENDING) return WriteResult::Failed;
            HANDLE waits[] = { event.Get(), process };
            for (;;)
            {
                DWORD const wait = WaitForMultipleObjects(2, waits, FALSE, 10);
                if (wait == WAIT_OBJECT_0)
                {
                    if (!GetOverlappedResult(handle, &overlap, &written, FALSE)) return WriteResult::Failed;
                    break;
                }
                if (wait == WAIT_OBJECT_0 + 1 || wait == WAIT_FAILED) return WriteResult::Failed;
                if (shouldCancel())
                {
                    CancelIoEx(handle, &overlap);
                    WaitForSingleObject(event.Get(), INFINITE);
                    GetOverlappedResult(handle, &overlap, &written, FALSE);
                    return WriteResult::Cancelled;
                }
            }
        }
        if (written == 0) return WriteResult::Failed;
        offset += written;
    }
    return WriteResult::Complete;
}
#endif

std::string LowerHex(unsigned char const* data, std::size_t count)
{
    static char const digits[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(count * 2);
    for (std::size_t i = 0; i < count; ++i)
    {
        out.push_back(digits[data[i] >> 4]);
        out.push_back(digits[data[i] & 0x0f]);
    }
    return out;
}

bool Sha256File(std::filesystem::path const& path, std::string& digest)
{
#ifdef _WIN32
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectLength = 0, resultLength = 0;
    std::vector<unsigned char> object;
    std::array<unsigned char, 32> bytes{};
    std::ifstream input(path, std::ios::binary);
    if (!input) return false;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return false;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectLength), sizeof(objectLength), &resultLength, 0) != 0)
    { BCryptCloseAlgorithmProvider(algorithm, 0); return false; }
    object.resize(objectLength);
    if (BCryptCreateHash(algorithm, &hash, object.data(), objectLength, nullptr, 0, 0) != 0)
    { BCryptCloseAlgorithmProvider(algorithm, 0); return false; }
    std::array<char, 8192> buffer{};
    while (input)
    {
        input.read(buffer.data(), buffer.size());
        std::streamsize const count = input.gcount();
        if (count > 0 && BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()), static_cast<ULONG>(count), 0) != 0)
        { BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0); return false; }
    }
    if (input.bad() || (!input.eof() && input.fail()))
    { BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0); return false; }
    bool const ok = BCryptFinishHash(hash, bytes.data(), static_cast<ULONG>(bytes.size()), 0) == 0;
    BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok) return false;
    digest = LowerHex(bytes.data(), bytes.size());
    return true;
#else
    (void)path; (void)digest; return false;
#endif
}

bool PathHasReparsePoint(std::filesystem::path path, std::filesystem::path const& root)
{
#ifdef _WIN32
    for (;;)
    {
        DWORD const attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return true;
        if (path == root) return false;
        std::filesystem::path const parent = path.parent_path();
        if (parent == path) return true;
        path = parent;
    }
#else
    (void)path; (void)root; return false;
#endif
}

bool OriginalAbsolutePathHasReparsePoint(std::filesystem::path const& path)
{
#ifdef _WIN32
    if (!path.is_absolute()) return true;
    std::filesystem::path current = path.root_path();
    for (auto const& part : path.relative_path())
    {
        if (part.empty() || part == "." || part == "..") return true;
        current /= part;
        DWORD const attributes = GetFileAttributesW(current.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return true;
    }
    return false;
#else
    (void)path; return false;
#endif
}

bool IsSafeRelativePath(std::string const& value)
{
    if (value.empty() || value.find('\\') != std::string::npos || value.find(':') != std::string::npos || value.front() == '/') return false;
    std::filesystem::path path(value);
    for (auto const& part : path)
        if (part == "." || part == ".." || part.empty()) return false;
    return true;
}

struct PackagePins
{
    std::string manifest;
    std::string config;
    std::string personality;
    std::string cli;
};

bool VerifyPackageWithPins(std::string const& rootText, PackagePins const& pins,
    std::filesystem::path& cliPath, std::string& error)
{
    try
    {
        std::filesystem::path const originalRoot = std::filesystem::u8path(rootText);
        if (!originalRoot.is_absolute()) { error = "package_root_not_absolute"; return false; }
        if (OriginalAbsolutePathHasReparsePoint(originalRoot)) { error = "package_root_reparse_component"; return false; }
        std::filesystem::path root = originalRoot;
        root = std::filesystem::weakly_canonical(root);
        if (!std::filesystem::is_directory(root) || PathHasReparsePoint(root, root)) { error = "package_root_invalid"; return false; }
        std::filesystem::path const bridge = root / "bridge";
        std::filesystem::path const manifest = bridge / "sha256-manifest.txt";
        std::string digest;
        if (OriginalAbsolutePathHasReparsePoint(manifest) || !std::filesystem::is_regular_file(manifest) ||
            !Sha256File(manifest, digest) || digest != pins.manifest)
        { error = "payload_manifest_pin_mismatch"; return false; }

        std::ifstream input(manifest, std::ios::binary);
        if (!input) { error = "payload_manifest_open"; return false; }
        std::set<std::string> seen;
        std::string line;
        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.size() < 67 || line[64] != ' ' || (line[65] != '*' && line[65] != ' ')) { error = "payload_manifest_format"; return false; }
            std::string expected = line.substr(0, 64);
            if (!std::all_of(expected.begin(), expected.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'); }))
            { error = "payload_manifest_hash_format"; return false; }
            std::string relative = line.substr(66);
            if (!IsSafeRelativePath(relative) || !seen.insert(relative).second) { error = "payload_manifest_path"; return false; }
            std::filesystem::path const originalFile = bridge / std::filesystem::u8path(relative);
            if (OriginalAbsolutePathHasReparsePoint(originalFile)) { error = "payload_file_reparse_component"; return false; }
            std::filesystem::path file = std::filesystem::weakly_canonical(originalFile);
            std::wstring const rootNative = bridge.native();
            std::wstring const fileNative = file.native();
            if (fileNative.size() <= rootNative.size() || fileNative.compare(0, rootNative.size(), rootNative) != 0 ||
                (fileNative[rootNative.size()] != L'\\' && fileNative[rootNative.size()] != L'/') || PathHasReparsePoint(file, bridge) ||
                !std::filesystem::is_regular_file(file) || !Sha256File(file, digest) || digest != expected)
            { error = "payload_file_mismatch"; return false; }
        }
        if (input.bad() || (!input.eof() && input.fail())) { error = "payload_manifest_stream_error"; return false; }
        if (seen.empty()) { error = "payload_manifest_empty"; return false; }
        auto pin = [&](std::filesystem::path const& path, char const* expected) {
            return Sha256File(path, digest) && digest == expected && !PathHasReparsePoint(path, bridge);
        };
        if (!pin(bridge / "config" / "bridge-config-v1.json", pins.config.c_str())) { error = "config_pin_mismatch"; return false; }
        if (!pin(bridge / "context" / "personality-context-profile-v1.json", pins.personality.c_str())) { error = "personality_pin_mismatch"; return false; }
        cliPath = bridge / "src" / "cli.mjs";
        if (!pin(cliPath, pins.cli.c_str())) { error = "cli_pin_mismatch"; return false; }
        return true;
    }
    catch (...)
    {
        error = "package_verification_exception";
        return false;
    }
}

bool VerifyPackage(std::string const& rootText, std::filesystem::path& cliPath, std::string& error)
{
    return VerifyPackageWithPins(rootText,
        PackagePins{ kPayloadManifestHash, kConfigHash, kPersonalityHash, kCliHash }, cliPath, error);
}
}

class ExternalLLMBridgeService::Impl
{
public:
    Impl() = default;
    ~Impl() { Shutdown(); }

    State GetState() const { return m_state.load(std::memory_order_acquire); }
    bool IsReadyForAdmission() const { return GetState() == State::Ready; }

    void ObserveSession(std::uint64_t guid, std::uint32_t accountId, std::int64_t loginTime, std::string const& name)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        SessionFingerprint& fingerprint = m_sessions[guid];
        fingerprint.generation = ++m_nextSessionGeneration;
        fingerprint.guid = guid;
        fingerprint.accountId = accountId;
        fingerprint.loginTime = loginTime;
        fingerprint.name = name;
        fingerprint.active = true;
    }

    void InvalidateSession(std::uint64_t guid)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_sessions.erase(guid);
    }

    SubmitResult TrySubmit(std::uint64_t botGuid, std::uint64_t targetGuid, std::string const& targetName, std::string const& message)
    {
        State const state = GetState();
        if (state == State::LedgerExhausted) return SubmitResult::LocallyRejectedLedgerExhausted;
        if (state != State::Ready || botGuid != BotGuid || targetGuid == 0 || botGuid == targetGuid || targetName.empty() ||
            IsTrimEmpty(message) || message.size() > 2048) return SubmitResult::LocallyRejected;
        std::size_t messageCodepoints = 0;
        if (!DecodeUtf8(message, messageCodepoints, true)) return SubmitResult::LocallyRejected;

        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_state.load(std::memory_order_relaxed) != State::Ready || m_routes.size() >= OutstandingRouteCapacity)
            return m_state.load(std::memory_order_relaxed) == State::LedgerExhausted ? SubmitResult::LocallyRejectedLedgerExhausted : SubmitResult::LocallyRejected;
        auto bot = m_sessions.find(botGuid);
        auto target = m_sessions.find(targetGuid);
        if (bot == m_sessions.end() || target == m_sessions.end() || !bot->second.active || !target->second.active || target->second.name != targetName)
            return SubmitResult::LocallyRejected;

        Route route;
        route.requestId = NewUuidV4();
        if (!IsCanonicalUuidV4(route.requestId)) return SubmitResult::LocallyRejected;
        route.botGuid = botGuid;
        route.targetGuid = targetGuid;
        route.targetName = targetName;
        route.message = message;
        route.botSession = bot->second;
        route.targetSession = target->second;
        auto const admittedWallTime = std::chrono::system_clock::now();
        route.createdUtc = FormatUtc(admittedWallTime);
        route.expiresUtc = FormatUtc(admittedWallTime + m_requestTtl);
        route.deadline = Clock::now() + m_requestTtl;
        m_routes.emplace(route.requestId, std::move(route));
        m_cv.notify_all();
        return SubmitResult::Admitted;
    }

    bool Start(std::string const& nodeExecutable, std::string const& packageRoot)
    {
        State expected = State::Disabled;
        if (!m_state.compare_exchange_strong(expected, State::Starting)) return false;
#ifndef _WIN32
        Fail(State::ChildFailed, "unsupported_platform");
        return false;
#else
        std::filesystem::path cli;
        std::string error;
        if (!VerifyPackage(packageRoot, cli, error))
        {
            Fail(State::ProtocolFailed, error);
            return false;
        }
        std::filesystem::path node;
        try { node = std::filesystem::weakly_canonical(std::filesystem::u8path(nodeExecutable)); }
        catch (...) { Fail(State::ProtocolFailed, "node_executable_invalid"); return false; }
        if (!node.is_absolute() || !std::filesystem::is_regular_file(node) || PathHasReparsePoint(node, node.parent_path()))
        {
            Fail(State::ProtocolFailed, "node_executable_invalid");
            return false;
        }
        return StartProcess(node.native(), { cli.native(), L"--run" }, ReadyTimeoutMs);
#endif
    }

#ifdef _WIN32
    bool StartProcess(std::wstring const& executable, std::vector<std::wstring> const& arguments, std::uint32_t readyTimeout)
    {
        UniqueHandle childStdinRead, parentStdinWrite, parentStdoutRead, childStdoutWrite, parentStderrRead, childStderrWrite;
        if (!CreateOverlappedPipePair(false, parentStdinWrite, childStdinRead))
        { Fail(State::ChildFailed, "create_stdin_pipe"); return false; }
        if (!CreateOverlappedPipePair(true, parentStdoutRead, childStdoutWrite))
        { Fail(State::ChildFailed, "create_stdout_pipe"); return false; }
        if (!CreateOverlappedPipePair(true, parentStderrRead, childStderrWrite))
        { Fail(State::ChildFailed, "create_stderr_pipe"); return false; }

        SIZE_T bytes = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
        std::vector<unsigned char> attributeStorage(bytes);
        auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(attributeStorage.data());
        if (!InitializeProcThreadAttributeList(attributes, 1, 0, &bytes)) { Fail(State::ChildFailed, "attribute_list_init"); return false; }
        HANDLE allowlist[] = { childStdinRead.Get(), childStdoutWrite.Get(), childStderrWrite.Get() };
        if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, allowlist, sizeof(allowlist), nullptr, nullptr))
        { DeleteProcThreadAttributeList(attributes); Fail(State::ChildFailed, "handle_allowlist"); return false; }

        STARTUPINFOEXW startup{};
        startup.StartupInfo.cb = sizeof(startup);
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = childStdinRead.Get();
        startup.StartupInfo.hStdOutput = childStdoutWrite.Get();
        startup.StartupInfo.hStdError = childStderrWrite.Get();
        startup.lpAttributeList = attributes;
        std::wstring command = QuoteWindowsArg(executable);
        for (auto const& argument : arguments) { command.push_back(L' '); command += QuoteWindowsArg(argument); }
        std::vector<wchar_t> mutableCommand(command.begin(), command.end());
        mutableCommand.push_back(L'\0');
        PROCESS_INFORMATION process{};
        BOOL const created = CreateProcessW(executable.c_str(), mutableCommand.data(), nullptr, nullptr, TRUE,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, nullptr, nullptr, &startup.StartupInfo, &process);
        DWORD const createError = created ? ERROR_SUCCESS : GetLastError();
        DeleteProcThreadAttributeList(attributes);
        if (!created) { Fail(State::ChildFailed, "create_process_" + std::to_string(createError)); return false; }

        m_process.Reset(process.hProcess);
        m_processId = process.dwProcessId;
        CloseHandle(process.hThread);
        childStdinRead.Reset(); childStdoutWrite.Reset(); childStderrWrite.Reset();
        m_stdin = std::move(parentStdinWrite);
        m_stdout = std::move(parentStdoutRead);
        m_stderr = std::move(parentStderrRead);
        m_readyDeadline = Clock::now() + std::chrono::milliseconds(readyTimeout);
        try
        {
            m_worker = std::thread(&Impl::WorkerMain, this);
        }
        catch (...)
        {
            Fail(State::ChildFailed, "worker_start_failed");
            if (m_process.Valid() && WaitForSingleObject(m_process.Get(), 0) == WAIT_TIMEOUT)
            {
                TerminateProcess(m_process.Get(), 0x53434304);
                WaitForSingleObject(m_process.Get(), 1000);
            }
            m_stdin.Reset(); m_stdout.Reset(); m_stderr.Reset(); m_process.Reset(); m_processId = 0;
            return false;
        }

        std::unique_lock<std::mutex> lock(m_mutex);
        m_cv.wait_until(lock, m_readyDeadline, [&] { State s = m_state.load(); return s != State::Starting; });
        if (m_state.load() == State::Starting)
        {
            lock.unlock();
            Fail(State::ProtocolFailed, "ready_timeout");
            RequestWorkerStop(true);
            JoinWorker(std::chrono::milliseconds(readyTimeout));
            return false;
        }
        bool const ready = m_state.load() == State::Ready;
        lock.unlock();
        if (!ready)
        {
            RequestWorkerStop(true);
            JoinWorker(std::chrono::milliseconds(std::max<std::uint32_t>(readyTimeout, 1000)));
        }
        return ready;
    }
#endif

    void UpdateWorld()
    {
        std::deque<Delivery> deliveries;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            deliveries.swap(m_deliveries);
        }
#ifndef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
        for (Delivery const& delivery : deliveries)
        {
            SessionFingerprint botSnapshot, targetSnapshot;
            bool evidenceValid = false;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                auto route = m_routes.find(delivery.route.requestId);
                auto bot = m_sessions.find(delivery.route.botGuid);
                auto target = m_sessions.find(delivery.route.targetGuid);
                if (route != m_routes.end() && route->second.phase == Route::Phase::DeliveryPending &&
                    route->second.requestId == delivery.route.requestId && route->second.botGuid == delivery.route.botGuid &&
                    route->second.targetGuid == delivery.route.targetGuid && route->second.targetName == delivery.route.targetName &&
                    ValidateDeliveryEvidence(route->second, delivery.completion, Clock::now()) &&
                    bot != m_sessions.end() && target != m_sessions.end())
                {
                    botSnapshot = bot->second;
                    targetSnapshot = target->second;
                    evidenceValid = true;
                }
            }
            if (!evidenceValid) { RetireRoute(delivery.route.requestId); continue; }
            auto same = [](SessionFingerprint const& current, SessionFingerprint const& admitted) {
                return current.active && current.guid == admitted.guid && current.accountId == admitted.accountId &&
                    current.loginTime == admitted.loginTime && current.generation == admitted.generation && current.name == admitted.name;
            };
            if (!same(botSnapshot, delivery.route.botSession) || !same(targetSnapshot, delivery.route.targetSession))
            { RetireRoute(delivery.route.requestId); continue; }

            Player* bot = sObjectAccessor.FindPlayer(ObjectGuid(delivery.route.botGuid));
            Player* target = sObjectAccessor.FindPlayer(ObjectGuid(delivery.route.targetGuid));
            if (!bot || !target || bot == target || !bot->IsInWorld() || !target->IsInWorld() || !GetBotAI(bot) || !IsRealPlayer(target) ||
                bot->GetGUIDLow() != BotGuid || !bot->GetSession() || !target->GetSession() ||
                bot->GetSession()->isLogingOut() || target->GetSession()->isLogingOut() ||
                bot->GetSession()->GetAccountId() != botSnapshot.accountId || target->GetSession()->GetAccountId() != targetSnapshot.accountId ||
                static_cast<std::int64_t>(bot->GetLoginTime()) != botSnapshot.loginTime || static_cast<std::int64_t>(target->GetLoginTime()) != targetSnapshot.loginTime ||
                target->GetName() != delivery.route.targetName)
            { RetireRoute(delivery.route.requestId); continue; }
            std::uint32_t const protocolLanguage = bot->GetTeam() == ALLIANCE ? LANG_COMMON : LANG_ORCISH;
            RetireRoute(delivery.route.requestId);
            bot->Whisper(delivery.completion.text, protocolLanguage, target->GetObjectGuid());
        }
#else
        (void)deliveries;
#endif
    }

    void Shutdown()
    {
        State state = m_state.load();
        if (state == State::Disabled || state == State::Stopped) return;
        m_state.store(State::ShuttingDown);
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_shutdownRequested = true;
            m_shutdownDeadline = Clock::now() + m_shutdownTimeout;
        }
        m_cv.notify_all();
        JoinWorker(m_shutdownTimeout);
        m_state.store(State::Stopped);
    }

#ifdef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
    bool TestStart(std::wstring const& executable, std::vector<std::wstring> const& arguments, std::uint32_t timeout)
    {
        State expected = State::Disabled;
        if (!m_state.compare_exchange_strong(expected, State::Starting)) return false;
#ifdef _WIN32
        return StartProcess(executable, arguments, timeout);
#else
        return false;
#endif
    }
    std::string TestStderr() const { std::lock_guard<std::mutex> lock(m_mutex); return m_stderrRing; }
    std::size_t TestRouteCount() const { std::lock_guard<std::mutex> lock(m_mutex); return m_routes.size(); }
    std::size_t TestDeliveryCount() const { std::lock_guard<std::mutex> lock(m_mutex); return m_deliveries.size(); }
    std::size_t TestSessionCount() const { std::lock_guard<std::mutex> lock(m_mutex); return m_sessions.size(); }
    bool TestOwnedResourcesClosed() const
    {
#ifdef _WIN32
        return !m_worker.joinable() && !m_process.Valid() && !m_stdin.Valid() && !m_stdout.Valid() &&
            !m_stderr.Valid() && m_processId == 0;
#else
        return !m_worker.joinable();
#endif
    }
    void TestSetTimeouts(std::chrono::milliseconds requestTtl, std::chrono::milliseconds shutdownTimeout)
    { m_requestTtl = requestTtl; m_shutdownTimeout = shutdownTimeout; }
    std::size_t TestDrainValidDeliveries()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        std::size_t valid = 0;
        for (Delivery const& delivery : m_deliveries)
        {
            auto route = m_routes.find(delivery.route.requestId);
            auto bot = m_sessions.find(delivery.route.botGuid);
            auto target = m_sessions.find(delivery.route.targetGuid);
            auto same = [](SessionFingerprint const& current, SessionFingerprint const& admitted) {
                return current.active && current.guid == admitted.guid && current.accountId == admitted.accountId &&
                    current.loginTime == admitted.loginTime && current.generation == admitted.generation && current.name == admitted.name;
            };
            if (route != m_routes.end() && route->second.phase == Route::Phase::DeliveryPending &&
                ValidateDeliveryEvidence(route->second, delivery.completion, Clock::now()) &&
                bot != m_sessions.end() && target != m_sessions.end() &&
                same(bot->second, delivery.route.botSession) && same(target->second, delivery.route.targetSession)) ++valid;
            if (route != m_routes.end()) m_routes.erase(route);
        }
        m_deliveries.clear();
        return valid;
    }
    static bool TestStrictJson(std::string const& line) { Json value; return StrictJson(line, value); }
    static bool TestResponse(CommandKind kind, std::string const& line, std::string const& requestId)
    { Json value; return StrictJson(line, value) && ValidateResponse(kind, value, requestId).valid; }
    static bool TestText(std::string const& value) { return IsCanonicalSanitizedText(value); }
#endif

private:
    void RetireRoute(std::string const& requestId)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_routes.erase(requestId);
    }

    void Fail(State state, std::string const& reason)
    {
        State current = m_state.load();
        if (current != State::ProtocolFailed && current != State::ChildFailed && current != State::Stopped)
            m_state.store(state);
        std::unique_lock<std::mutex> lock(m_mutex);
        if (m_failureReason.empty()) m_failureReason = reason;
        m_cv.notify_all();
#ifndef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
        sLog.outError("external_llm_bridge admission_closed reason=%s", reason.c_str());
#endif
    }

    void LatchLedger()
    {
        State expected = State::Ready;
        if (m_state.compare_exchange_strong(expected, State::LedgerExhausted) && !m_ledgerWarning.exchange(true))
        {
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                for (auto route = m_routes.begin(); route != m_routes.end();)
                {
                    if (route->second.phase == Route::Phase::PendingSubmit)
                        route = m_routes.erase(route);
                    else
                        ++route;
                }
            }
#ifndef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
            sLog.outError("external_llm_bridge state=ledger_exhausted admission=closed retry=disabled");
#endif
        }
    }

    Json SubmitCommand(Route const& route)
    {
        return Json{ { "command", "submit" }, { "request", Json{
            { "schema_version", 1 }, { "request_id", route.requestId }, { "bot_guid", BotGuid },
            { "created_utc", route.createdUtc }, { "expires_utc", route.expiresUtc }, { "message", route.message }
        } } };
    }

    Json KeyCommand(char const* command, Route const& route)
    {
        return Json{ { "command", command }, { "request_id", route.requestId }, { "bot_guid", BotGuid } };
    }

    bool ChooseCommand(Json& command, CommandKind& kind, std::string& requestId)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        Clock::time_point const now = Clock::now();
        for (auto it = m_routes.begin(); it != m_routes.end();)
        {
            if (now >= it->second.deadline && it->second.phase != Route::Phase::Consuming)
                it = m_routes.erase(it);
            else ++it;
        }
        if (m_shutdownRequested && !m_shutdownSent)
        {
            command = Json{ { "command", "shutdown" }, { "drain", true } };
            kind = CommandKind::Shutdown;
            m_shutdownSent = true;
            return true;
        }
        if (m_state.load() != State::Ready && m_state.load() != State::LedgerExhausted)
            return false;
        for (auto& item : m_routes)
        {
            Route& route = item.second;
            if (route.phase == Route::Phase::PendingSubmit && m_state.load() == State::Ready)
            {
                command = SubmitCommand(route); kind = CommandKind::Submit; requestId = route.requestId; return true;
            }
            if (route.phase == Route::Phase::Terminal && m_deliveries.size() < CompletionCapacity)
            {
                command = KeyCommand("consume", route); kind = CommandKind::Consume; requestId = route.requestId;
                route.phase = Route::Phase::Consuming; return true;
            }
        }
        if (now < m_nextPoll) return false;
        std::vector<std::string> accepted;
        for (auto const& item : m_routes)
            if (item.second.phase == Route::Phase::Accepted) accepted.push_back(item.first);
        if (accepted.empty()) return false;
        m_pollCursor %= accepted.size();
        requestId = accepted[m_pollCursor++];
        command = KeyCommand("status", m_routes.at(requestId));
        kind = CommandKind::Status;
        m_nextPoll = now + std::chrono::milliseconds(StatusPollIntervalMs);
        return true;
    }

    bool ApplyResponse(CommandKind kind, std::string const& requestId, Json const& value)
    {
        ResponseDisposition const response = ValidateResponse(kind, value, requestId);
        if (!response.valid) return false;
        std::unique_lock<std::mutex> lock(m_mutex);
        if (kind == CommandKind::Shutdown)
        {
            m_shutdownAcknowledged = true;
            return true;
        }
        auto found = m_routes.find(requestId);
        if (found == m_routes.end()) return false;
        Route& route = found->second;
        if (response.ledgerFull)
        {
            m_routes.erase(found);
            lock.unlock();
            LatchLedger();
            return true;
        }
        if (kind == CommandKind::Submit)
        {
            if (value["code"].get<std::string>() == "identity_mismatch") { m_routes.erase(found); return true; }
            route.phase = response.terminal ? Route::Phase::Terminal : Route::Phase::Accepted;
            return true;
        }
        if (kind == CommandKind::Status)
        {
            if (value["code"].get<std::string>() != "ok") { m_routes.erase(found); return true; }
            route.phase = response.terminal ? Route::Phase::Terminal : Route::Phase::Accepted;
            if (response.statusState == "consumed") m_routes.erase(found);
            return true;
        }
        if (kind == CommandKind::Consume)
        {
            if (response.consumed)
            {
                if (response.completion.outcome == "ready" && Clock::now() < route.deadline && m_deliveries.size() < CompletionCapacity)
                {
                    m_deliveries.push_back(Delivery{ route, response.completion });
                    route.phase = Route::Phase::DeliveryPending;
                }
                else
                    m_routes.erase(found);
            }
            else if (response.alreadyConsumed || value["code"].get<std::string>() != "not_ready")
                m_routes.erase(found);
            else
                route.phase = Route::Phase::Accepted;
            return true;
        }
        return true;
    }

#ifdef _WIN32
    void WorkerMain()
    {
        std::string stdoutBuffer;
        CommandKind pendingKind = CommandKind::None;
        std::string pendingRequest;
        bool ready = false;
        OverlappedRead stdoutRead, stderrRead;
        if (!stdoutRead.Initialize() || !stderrRead.Initialize())
        {
            Fail(State::ChildFailed, "overlapped_event_create_failed");
            goto done;
        }
        for (;;)
        {
            bool stdoutEof = false, stderrEof = false;
            std::string stdoutBytes, stderrBytes;
            if (!PumpOverlappedRead(m_stdout.Get(), stdoutRead, stdoutBytes, stdoutEof) ||
                !PumpOverlappedRead(m_stderr.Get(), stderrRead, stderrBytes, stderrEof))
            {
                if (m_forceStop.load()) break;
                Fail(State::ChildFailed, "pipe_read_failed"); break;
            }
            if (!stderrBytes.empty())
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_stderrRing += stderrBytes;
                if (m_stderrRing.size() > StderrDiagnosticCapBytes)
                    m_stderrRing.erase(0, m_stderrRing.size() - StderrDiagnosticCapBytes);
            }
            if (!stdoutBytes.empty()) stdoutBuffer += stdoutBytes;
            if (stdoutBuffer.size() > StdoutNdjsonLineCapBytes && stdoutBuffer.find('\n') == std::string::npos)
            { Fail(State::ProtocolFailed, "stdout_line_too_large"); break; }

            for (;;)
            {
                std::size_t const newline = stdoutBuffer.find('\n');
                if (newline == std::string::npos) break;
                std::string line = stdoutBuffer.substr(0, newline);
                stdoutBuffer.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                Json record;
                if (!StrictJson(line, record)) { Fail(State::ProtocolFailed, "invalid_ndjson"); goto done; }
                if (!ready)
                {
                    if (IsFatalTopLevelError(record)) { Fail(State::ChildFailed, "fatal_startup_error"); goto done; }
                    if (!ValidateReady(record)) { Fail(State::ProtocolFailed, "ready_mismatch"); goto done; }
                    ready = true;
                    m_state.store(State::Ready);
                    m_cv.notify_all();
                }
                else
                {
                    if (pendingKind == CommandKind::None || !ApplyResponse(pendingKind, pendingRequest, record))
                    { Fail(State::ProtocolFailed, "response_contract_mismatch"); goto done; }
                    pendingKind = CommandKind::None;
                    pendingRequest.clear();
                }
            }

            if (!ready && Clock::now() >= m_readyDeadline) { Fail(State::ProtocolFailed, "ready_timeout"); break; }
            if (stdoutEof)
            {
                if (!ShutdownWasAcknowledged()) Fail(State::ChildFailed, "stdout_eof");
                break;
            }
            if (WaitForSingleObject(m_process.Get(), 0) == WAIT_OBJECT_0)
            {
                if (!ShutdownWasAcknowledged()) Fail(State::ChildFailed, "child_exit_or_abort");
                break;
            }
            if (m_forceStop.load()) break;
            if (ShutdownDeadlineReached()) break;

            if (ready && pendingKind == CommandKind::None)
            {
                Json command;
                if (ChooseCommand(command, pendingKind, pendingRequest))
                {
                    std::string wire = command.dump();
                    wire.push_back('\n');
                    WriteResult const write = wire.size() > StdoutNdjsonLineCapBytes ? WriteResult::Failed :
                        WriteAllOverlapped(m_stdin.Get(), m_process.Get(), wire, [this] { return ShouldCancelIo(); });
                    if (write != WriteResult::Complete)
                    {
                        if (write == WriteResult::Failed && !m_forceStop.load() && !ShutdownDeadlineReached())
                            Fail(State::ChildFailed, "stdin_write_failed");
                        break;
                    }
                }
            }
            std::unique_lock<std::mutex> lock(m_mutex);
            m_cv.wait_for(lock, std::chrono::milliseconds(5));
        }
done:
        if (m_stdout.Valid()) CancelAndDrainOverlappedRead(m_stdout.Get(), stdoutRead);
        if (m_stderr.Valid()) CancelAndDrainOverlappedRead(m_stderr.Get(), stderrRead);
        if (!ShutdownWasAcknowledged() && m_process.Valid() && WaitForSingleObject(m_process.Get(), 0) == WAIT_TIMEOUT)
            TerminateProcess(m_process.Get(), 0x53434303);
        m_workerDone.store(true);
        m_cv.notify_all();
    }

    void RequestWorkerStop(bool terminateOwned)
    {
        m_forceStop.store(true);
        m_cv.notify_all();
        if (m_stdin.Valid()) CancelIoEx(m_stdin.Get(), nullptr);
        if (m_stdout.Valid()) CancelIoEx(m_stdout.Get(), nullptr);
        if (m_stderr.Valid()) CancelIoEx(m_stderr.Get(), nullptr);
        if (terminateOwned && m_process.Valid() && WaitForSingleObject(m_process.Get(), 0) == WAIT_TIMEOUT)
            TerminateProcess(m_process.Get(), 0x53434301);
    }

    void JoinWorker(std::chrono::milliseconds timeout)
    {
        if (!m_worker.joinable()) return;
        Clock::time_point const deadline = Clock::now() + timeout;
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            m_cv.wait_until(lock, deadline, [&] { return m_workerDone.load(); });
        }
        if (!m_workerDone.load()) RequestWorkerStop(true);
        if (m_process.Valid() && WaitForSingleObject(m_process.Get(), 0) == WAIT_TIMEOUT)
        {
            TerminateProcess(m_process.Get(), 0x53434302);
            WaitForSingleObject(m_process.Get(), 1000);
        }
        m_worker.join();
        m_stdin.Reset(); m_stdout.Reset(); m_stderr.Reset(); m_process.Reset(); m_processId = 0;
    }
#else
    void JoinWorker(std::chrono::milliseconds) {}
#endif

private:
    bool ShutdownWasAcknowledged() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_shutdownRequested && m_shutdownAcknowledged;
    }

    bool ShutdownDeadlineReached() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_shutdownRequested && Clock::now() >= m_shutdownDeadline;
    }

    bool ShouldCancelIo() const
    {
        if (m_forceStop.load()) return true;
        return ShutdownDeadlineReached();
    }

    std::atomic<State> m_state{ State::Disabled };
    std::atomic<bool> m_ledgerWarning{ false };
    std::atomic<bool> m_forceStop{ false };
    std::atomic<bool> m_workerDone{ false };
    mutable std::mutex m_mutex;
    std::condition_variable m_cv;
    std::map<std::uint64_t, SessionFingerprint> m_sessions;
    std::uint64_t m_nextSessionGeneration = 0;
    std::map<std::string, Route> m_routes;
    std::deque<Delivery> m_deliveries;
    std::string m_stderrRing;
    std::string m_failureReason;
    std::size_t m_pollCursor = 0;
    Clock::time_point m_nextPoll{};
    Clock::time_point m_readyDeadline{};
    Clock::time_point m_shutdownDeadline{};
    bool m_shutdownRequested = false;
    bool m_shutdownSent = false;
    bool m_shutdownAcknowledged = false;
    std::chrono::milliseconds m_requestTtl{ kRequestTtl };
    std::chrono::milliseconds m_shutdownTimeout{ ShutdownOverallTimeoutMs };
    std::thread m_worker;
#ifdef _WIN32
    UniqueHandle m_process, m_stdin, m_stdout, m_stderr;
    DWORD m_processId = 0;
#endif
};

#ifdef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
class ExternalLLMBridgeTestHarness
{
public:
    ExternalLLMBridgeTestHarness() : m_impl(new ExternalLLMBridgeService::Impl) {}
    bool Start(std::wstring const& executable, std::vector<std::wstring> const& arguments, std::uint32_t readyTimeoutMs)
    { return m_impl->TestStart(executable, arguments, readyTimeoutMs); }
    void Observe(std::uint64_t guid, std::uint32_t account, std::int64_t login, std::string const& name)
    { m_impl->ObserveSession(guid, account, login, name); }
    void Invalidate(std::uint64_t guid) { m_impl->InvalidateSession(guid); }
    ExternalLLMBridgeService::SubmitResult Submit(std::uint64_t bot, std::uint64_t target, std::string const& name, std::string const& message)
    { return m_impl->TrySubmit(bot, target, name, message); }
    ExternalLLMBridgeService::State State() const { return m_impl->GetState(); }
    std::size_t Routes() const { return m_impl->TestRouteCount(); }
    std::size_t Deliveries() const { return m_impl->TestDeliveryCount(); }
    std::size_t Sessions() const { return m_impl->TestSessionCount(); }
    bool OwnedResourcesClosed() const { return m_impl->TestOwnedResourcesClosed(); }
    std::string Stderr() const { return m_impl->TestStderr(); }
    void SetTimeouts(std::uint32_t requestTtlMs, std::uint32_t shutdownTimeoutMs)
    { m_impl->TestSetTimeouts(std::chrono::milliseconds(requestTtlMs), std::chrono::milliseconds(shutdownTimeoutMs)); }
    std::size_t DrainValidDeliveries() { return m_impl->TestDrainValidDeliveries(); }
    void Shutdown() { m_impl->Shutdown(); }
    static bool Strict(std::string const& line) { return ExternalLLMBridgeService::Impl::TestStrictJson(line); }
    static bool Response(int kind, std::string const& line, std::string const& requestId)
    { return ExternalLLMBridgeService::Impl::TestResponse(static_cast<CommandKind>(kind), line, requestId); }
    static bool Text(std::string const& value) { return ExternalLLMBridgeService::Impl::TestText(value); }
private:
    std::unique_ptr<ExternalLLMBridgeService::Impl> m_impl;
};
#endif

ExternalLLMBridgeService& ExternalLLMBridgeService::Instance()
{
    static ExternalLLMBridgeService service;
    return service;
}

ExternalLLMBridgeService::ExternalLLMBridgeService() : m_impl(new Impl) {}
ExternalLLMBridgeService::~ExternalLLMBridgeService() = default;

bool ExternalLLMBridgeService::Start()
{
#ifndef SSC_EXTERNAL_LLM_BRIDGE_STANDALONE
    if (!sPlayerbotAIConfig.externalLLMBridgeEnabled) return false;
    return m_impl->Start(sPlayerbotAIConfig.externalLLMBridgeNodeExecutable, sPlayerbotAIConfig.externalLLMBridgePackageRoot);
#else
    return false;
#endif
}

ExternalLLMBridgeService::SubmitResult ExternalLLMBridgeService::TrySubmit(std::uint64_t botGuid, std::uint64_t targetGuid,
    std::string const& targetName, std::string const& message)
{
    return m_impl->TrySubmit(botGuid, targetGuid, targetName, message);
}

void ExternalLLMBridgeService::UpdateWorld() { m_impl->UpdateWorld(); }
void ExternalLLMBridgeService::ObserveSession(std::uint64_t guid, std::uint32_t accountId, std::int64_t loginTime, std::string const& name)
{ m_impl->ObserveSession(guid, accountId, loginTime, name); }
void ExternalLLMBridgeService::InvalidateSession(std::uint64_t guid) { m_impl->InvalidateSession(guid); }
void ExternalLLMBridgeService::Shutdown() { m_impl->Shutdown(); }
ExternalLLMBridgeService::State ExternalLLMBridgeService::GetState() const { return m_impl->GetState(); }
bool ExternalLLMBridgeService::IsReadyForAdmission() const { return m_impl->IsReadyForAdmission(); }
