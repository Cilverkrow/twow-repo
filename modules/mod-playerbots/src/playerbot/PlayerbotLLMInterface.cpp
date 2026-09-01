//These methods are supposed to be called asynchronous from the main processes 'and' be greatly delayed by LLM interfernece.
//As such performance (such as opting to use regex) was not a consideration.
//And yes I used chat-gpt to write most of this. LLM for LLM code is what I call fitting.

#include "PlayerbotLLMInterface.h"

// Penqle's Singleton<> requires an explicit instantiation in a .cpp file.
INSTANTIATE_SINGLETON_1(PlayerbotLLMInterface);

#include <algorithm>
#include <iostream>
#include <array>
#include <string>
#include <cstring>
#include <sstream>
#include <regex>
#include <chrono>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <thread>
#include "Log.h"
#include "Util.h"
#include "httplib.h"
#include "PlayerbotAIConfig.h"
#include "PlayerbotTextMgr.h"
#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netinet/in.h>
#include <cstring>
#include <fcntl.h>
#include <errno.h>
#include <netdb.h>
#endif


namespace
{

    constexpr size_t MAX_DEBUG_REQUEST_BODY_SIZE = 64 * 1024;
    constexpr size_t MAX_DEBUG_RESPONSE_BODY_SIZE = 64 * 1024;
    constexpr size_t MAX_DEBUG_OUTPUT_SIZE = 1024;

    // Win-1251 to Unicode codepoint table for bytes 0x80-0xFF
    static const uint32_t win1251_to_unicode[128] = {
        0x0402,
        0x0403,
        0x201A,
        0x0453,
        0x201E,
        0x2026,
        0x2020,
        0x2021,
        0x20AC,
        0x2030,
        0x0409,
        0x2039,
        0x040A,
        0x040C,
        0x040B,
        0x040F,
        0x0452,
        0x2018,
        0x2019,
        0x201C,
        0x201D,
        0x2022,
        0x2013,
        0x2014,
        0x0000,
        0x2122,
        0x0459,
        0x203A,
        0x045A,
        0x045C,
        0x045B,
        0x045F,
        0x00A0,
        0x040E,
        0x045E,
        0x0408,
        0x00A4,
        0x0490,
        0x00A6,
        0x00A7,
        0x0401,
        0x00A9,
        0x0404,
        0x00AB,
        0x00AC,
        0x00AD,
        0x00AE,
        0x0407,
        0x00B0,
        0x00B1,
        0x0406,
        0x0456,
        0x0491,
        0x00B5,
        0x00B6,
        0x00B7,
        0x0451,
        0x2116,
        0x0454,
        0x00BB,
        0x0458,
        0x0405,
        0x0455,
        0x0457,
        0x0410,
        0x0411,
        0x0412,
        0x0413,
        0x0414,
        0x0415,
        0x0416,
        0x0417,
        0x0418,
        0x0419,
        0x041A,
        0x041B,
        0x041C,
        0x041D,
        0x041E,
        0x041F,
        0x0420,
        0x0421,
        0x0422,
        0x0423,
        0x0424,
        0x0425,
        0x0426,
        0x0427,
        0x0428,
        0x0429,
        0x042A,
        0x042B,
        0x042C,
        0x042D,
        0x042E,
        0x042F,
        0x0430,
        0x0431,
        0x0432,
        0x0433,
        0x0434,
        0x0435,
        0x0436,
        0x0437,
        0x0438,
        0x0439,
        0x043A,
        0x043B,
        0x043C,
        0x043D,
        0x043E,
        0x043F,
        0x0440,
        0x0441,
        0x0442,
        0x0443,
        0x0444,
        0x0445,
        0x0446,
        0x0447,
        0x0448,
        0x0449,
        0x044A,
        0x044B,
        0x044C,
        0x044D,
        0x044E,
        0x044F,
    };

    static void AppendUtf8(std::string& out, uint32_t cp)
    {
        if (cp < 0x80) {
            out += (char)cp;
        }
        else if (cp < 0x800) {
            out += (char)(0xC0 | (cp >> 6));
            out += (char)(0x80 | (cp & 0x3F));
        }
        else {
            out += (char)(0xE0 | (cp >> 12));
            out += (char)(0x80 | ((cp >> 6) & 0x3F));
            out += (char)(0x80 | (cp & 0x3F));
        }
    }

    static bool IsValidUtf8(const std::string& s)
    {
        size_t i = 0;
        while (i < s.size()) {
            unsigned char c = (unsigned char)s[i];
            int bytes;
            if (c < 0x80) {
                i++;
                continue;
            }
            else if ((c & 0xE0) == 0xC0)
                bytes = 2;
            else if ((c & 0xF0) == 0xE0)
                bytes = 3;
            else if ((c & 0xF8) == 0xF0)
                bytes = 4;
            else
                return false;
            for (int j = 1; j < bytes; j++)
                if (i + j >= s.size() || ((unsigned char)s[i + j] & 0xC0) != 0x80)
                    return false;
            i += bytes;
        }
        return true;
    }

    static std::string Win1251ToUtf8(const std::string& input)
    {
        std::string result;
        result.reserve(input.size() * 2);
        for (unsigned char c : input) {
            if (c < 0x80)
                result += (char)c;
            else {
                uint32_t cp = win1251_to_unicode[c - 0x80];
                if (cp)
                    AppendUtf8(result, cp);
            }
        }
        return result;
    }

    static std::string ReplaceDebugTemplateString(const std::string& input, const std::string& prompt)
    {
        const std::string empty;
        const std::array<std::pair<const char*, const std::string*>, 4> replacements = {{
            {"<prompt>", &prompt},
            {"<context>", &empty},
            {"<pre prompt>", &empty},
            {"<post prompt>", &empty}
        }};

        std::string output;
        output.reserve(input.size() + prompt.size());

        size_t cursor = 0;
        while (cursor < input.size())
        {
            size_t nextPosition = std::string::npos;
            const std::pair<const char*, const std::string*>* nextReplacement = nullptr;

            for (const auto& replacement : replacements)
            {
                size_t position = input.find(replacement.first, cursor);
                if (position != std::string::npos && (nextPosition == std::string::npos || position < nextPosition))
                {
                    nextPosition = position;
                    nextReplacement = &replacement;
                }
            }

            if (!nextReplacement)
            {
                output.append(input, cursor, std::string::npos);
                break;
            }

            output.append(input, cursor, nextPosition - cursor);
            output.append(*nextReplacement->second);
            cursor = nextPosition + std::strlen(nextReplacement->first);
        }

        return output;
    }

    static bool ReplaceDebugJsonStrings(rapidjson::Value& value, rapidjson::Document::AllocatorType& allocator, const std::string& prompt, std::string& error)
    {
        if (value.IsString())
        {
            std::string input(value.GetString(), value.GetStringLength());
            std::string output = ReplaceDebugTemplateString(input, prompt);
            std::wstring wideOutput;
            if (!Utf8toWStr(output, wideOutput))
            {
                error = "LLM debug request contains invalid UTF-8.";
                return false;
            }

            value.SetString(output.data(), static_cast<rapidjson::SizeType>(output.size()), allocator);
            return true;
        }

        if (value.IsArray())
        {
            for (auto& entry : value.GetArray())
            {
                if (!ReplaceDebugJsonStrings(entry, allocator, prompt, error))
                    return false;
            }
        }
        else if (value.IsObject())
        {
            for (auto entry = value.MemberBegin(); entry != value.MemberEnd(); ++entry)
            {
                if (!ReplaceDebugJsonStrings(entry->value, allocator, prompt, error))
                    return false;
            }
        }

        return true;
    }

    static size_t Utf8PrefixSize(const std::string& input, size_t maxBytes)
    {
        if (input.size() <= maxBytes)
            return input.size();

        size_t end = maxBytes;
        while (end > 0 && (static_cast<unsigned char>(input[end]) & 0xC0) == 0x80)
            --end;
        return end;
    }

} // namespace

std::string PlayerbotLLMInterface::SanitizeForJson(const std::string& input)
{
    // If input is not valid UTF-8, assume Win-1251 (WoW 1.12.1 client encoding)
    bool inputIsUtf8 = IsValidUtf8(input);
    const std::string src = inputIsUtf8 ? input : Win1251ToUtf8(input);

    std::string sanitized;
    sanitized.reserve(src.size());
    for (size_t i = 0; i < src.size(); i++) {
        unsigned char c = (unsigned char)src[i];
        switch (c) {
            case '\"': sanitized += "\\\""; break;
            case '\\': sanitized += "\\\\"; break;
            case '\b': sanitized += "\\b"; break;
            case '\f': sanitized += "\\f"; break;
            case '\n': sanitized += "\\n"; break;
            case '\r': sanitized += "\\r"; break;
            case '\t': sanitized += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buffer[7];
                    snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    sanitized += buffer;
                }
                else {
                    sanitized += (char)c;
                }
        }
    }
    return sanitized;
}

inline void SetNonBlockingSocket(int sock) {
#ifdef _WIN32
    u_long mode = 1;
    if (ioctlsocket(sock, FIONBIO, &mode) != 0) {
        sLog.outError("BotLLM: Failed to set non-blocking mode on socket. Error: %d", WSAGetLastError());
    }
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags == -1 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) == -1) {
        sLog.outError("BotLLM: Failed to set non-blocking mode on socket. Error: %s", strerror(errno));
    }
#endif
}

inline void RestoreBlockingSocket(int sock) {
#ifdef _WIN32
    u_long mode = 0;
    ioctlsocket(sock, FIONBIO, &mode);
#else
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags != -1) {
        fcntl(sock, F_SETFL, flags & ~O_NONBLOCK);
    }
#endif
}

inline std::string SSLRecvWithTimeout(SSL* ssl, int timeout_seconds, int& bytesRead) {
    char buffer[4096];
    std::string response;
    
    auto start = std::chrono::steady_clock::now();
    
    while (true) {
        bytesRead = SSL_read(ssl, buffer, sizeof(buffer) - 1);
        
        if (bytesRead > 0) {
            buffer[bytesRead] = '\0';
            response += buffer;
        }
        else {
            int ssl_error = SSL_get_error(ssl, bytesRead);
            if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::seconds>(now - start).count() >= timeout_seconds) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            else {
                break;
            }
        }
    }
    
    return response;
}

inline std::string RecvWithTimeout(int sock, int timeout_seconds, int& bytesRead) {
    char buffer[4096];
    int bufferSize = sizeof(buffer);
    std::string response;

    SetNonBlockingSocket(sock);

    auto start = std::chrono::steady_clock::now();

    while (true) {
        bytesRead = recv(sock, buffer, bufferSize - 1, 0);

        if (bytesRead > 0) {
            buffer[bytesRead] = '\0';
            response += buffer;
        }
        else if (bytesRead == -1) {
#ifdef _WIN32
            if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
#endif
                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::seconds>(now - start).count() >= timeout_seconds) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            else {
#ifdef _WIN32
                sLog.outError("BotLLM: recv error: %d", WSAGetLastError());
#else
                sLog.outError("BotLLM: recv error: %s", strerror(errno));
#endif
                break;
            }
            }
        else {
            break;
        }
        }

    RestoreBlockingSocket(sock);

    return response;
    }

std::string GetSSLError() {
    unsigned long err = ERR_get_error();
    char err_buf[256];
    ERR_error_string_n(err, err_buf, sizeof(err_buf));
    return std::string(err_buf);
}

std::string PlayerbotLLMInterface::Generate(const std::string& prompt, int timeOutSeconds, int maxGenerations, std::vector<std::string> & debugLines) {
    // LLM gateway network client removed. Always report "no response" so callers fall back
    // to their existing silent/no-op reply path.
    (void)prompt; (void)timeOutSeconds; (void)maxGenerations;
    if (!debugLines.empty())
        debugLines.push_back("LLM generation disabled in this build");
    return {};
}

bool PlayerbotLLMInterface::BuildDebugRequest(const std::string& requestTemplate, const std::string& prompt, uint32_t maxPromptBytes, std::string& request, std::string& error)
{
    request.clear();
    error.clear();

    if (prompt.empty())
    {
        error = "LLM debug prompt is empty.";
        return false;
    }

    if (maxPromptBytes && prompt.size() > maxPromptBytes)
    {
        error = "LLM debug prompt exceeds the configured context length.";
        return false;
    }

    std::wstring widePrompt;
    if (!Utf8toWStr(prompt, widePrompt))
    {
        error = "LLM debug prompt is not valid UTF-8.";
        return false;
    }

    rapidjson::Document document;
    document.Parse<rapidjson::kParseValidateEncodingFlag>(requestTemplate.data(), requestTemplate.size());
    if (document.HasParseError())
    {
        std::ostringstream out;
        out << "LLMApiJson is invalid: " << rapidjson::GetParseError_En(document.GetParseError())
            << " at offset " << document.GetErrorOffset() << ".";
        error = out.str();
        return false;
    }

    if (!document.IsObject())
    {
        error = "LLMApiJson must contain a JSON object.";
        return false;
    }

    if (!ReplaceDebugJsonStrings(document, document.GetAllocator(), prompt, error))
        return false;

    rapidjson::StringBuffer buffer;
    rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
    if (!document.Accept(writer))
    {
        error = "LLM debug request serialization failed.";
        return false;
    }

    request.assign(buffer.GetString(), buffer.GetSize());
    if (request.size() > MAX_DEBUG_REQUEST_BODY_SIZE)
    {
        request.clear();
        error = "LLM debug request body exceeds 64 KiB.";
        return false;
    }

    return true;
}

PlayerbotLLMInterface::DebugResult PlayerbotLLMInterface::GenerateDebugResponse(const std::string& request, const std::string& schemeHost, const std::string& path, const std::string& apiKey, uint32_t timeoutSeconds)
{
    try
    {
        httplib::Client client(schemeHost);
        if (!client.is_valid())
            return { false, "The configured LLM endpoint is invalid." };

        timeoutSeconds = std::max<uint32_t>(1, timeoutSeconds);
        client.set_connection_timeout(timeoutSeconds);
        client.set_read_timeout(timeoutSeconds);
        client.set_write_timeout(timeoutSeconds);

        httplib::Request httpRequest;
        httpRequest.method = "POST";
        httpRequest.path = path;
        httpRequest.body = request;
        httpRequest.set_header("Content-Type", "application/json");
        if (!apiKey.empty())
            httpRequest.set_header("Authorization", "Bearer " + apiKey);

        std::string responseBody;
        bool responseTooLarge = false;
        httpRequest.response_handler = [&responseTooLarge](const httplib::Response& response)
        {
            if (response.has_header("Content-Length") && response.get_header_value_u64("Content-Length") > MAX_DEBUG_RESPONSE_BODY_SIZE)
            {
                responseTooLarge = true;
                return false;
            }
            return true;
        };
        httpRequest.content_receiver = [&responseBody, &responseTooLarge](const char* data, size_t length, uint64_t, uint64_t)
        {
            if (responseBody.size() + length > MAX_DEBUG_RESPONSE_BODY_SIZE)
            {
                responseTooLarge = true;
                return false;
            }
            responseBody.append(data, length);
            return true;
        };

        httplib::Response httpResponse;
        httplib::Error httpError = httplib::Error::Unknown;
        if (!client.send(httpRequest, httpResponse, httpError))
        {
            if (responseTooLarge)
                return { false, "LLM response body exceeds 64 KiB." };
            return { false, "LLM HTTP request failed: " + httplib::to_string(httpError) + "." };
        }

        if (httpResponse.status != 200)
            return { false, "LLM endpoint returned HTTP status " + std::to_string(httpResponse.status) + "." };

        if (responseBody.empty())
            return { false, "LLM endpoint returned an empty response body." };

        rapidjson::Document document;
        document.Parse<rapidjson::kParseValidateEncodingFlag>(responseBody.data(), responseBody.size());
        if (document.HasParseError())
        {
            std::ostringstream out;
            out << "LLM response is invalid JSON or UTF-8: " << rapidjson::GetParseError_En(document.GetParseError())
                << " at offset " << document.GetErrorOffset() << ".";
            return { false, out.str() };
        }

        if (!document.IsObject() || !document.HasMember("choices") || !document["choices"].IsArray() || document["choices"].Empty())
            return { false, "LLM response is missing choices[0].message.content." };

        const rapidjson::Value& choice = document["choices"][0];
        if (!choice.IsObject() || !choice.HasMember("message") || !choice["message"].IsObject())
            return { false, "LLM response is missing choices[0].message.content." };

        const rapidjson::Value& message = choice["message"];
        if (!message.HasMember("content") || !message["content"].IsString())
            return { false, "LLM response is missing choices[0].message.content." };

        std::string content(message["content"].GetString(), message["content"].GetStringLength());
        if (content.empty())
            return { false, "LLM response content is empty." };
        if (content.find('\0') != std::string::npos)
            return { false, "LLM response content contains an unsupported null character." };

        content.resize(Utf8PrefixSize(content, MAX_DEBUG_OUTPUT_SIZE));
        return { true, content };
    }
    catch (const std::exception& e)
    {
        return { false, "LLM debug request failed: " + std::string(e.what()) };
    }
    catch (...)
    {
        return { false, "LLM debug request failed with an unknown error." };
    }
}

PlayerbotLLMInterface::DebugRequestStartStatus PlayerbotLLMInterface::StartDebugRequest(const std::string& request, uint32_t accountId, std::string& error)
{
    error.clear();

    if (!sPlayerbotAIConfig.llmMaxSimultaniousGenerations)
        return DebugRequestStartStatus::Disabled;

    const ParsedUrl endpoint = sPlayerbotAIConfig.llmEndPointUrl;
    if (endpoint.hostname.empty() || endpoint.port <= 0 || endpoint.path.empty())
    {
        error = "The configured LLM endpoint is invalid.";
        return DebugRequestStartStatus::Failed;
    }

    const std::string schemeHost = std::string(endpoint.https ? "https://" : "http://") + endpoint.hostname + ":" + std::to_string(endpoint.port);
    const std::string path = endpoint.path;
    const std::string apiKey = sPlayerbotAIConfig.llmApiKey;
    const uint32_t timeoutSeconds = sPlayerbotAIConfig.llmGenerationTimeout;

    PlayerbotLLMInterface& llmInterface = sPlayerbotLLMInterface;
    std::lock_guard<std::mutex> lock(llmInterface.debugRequestMutex);

    if (llmInterface.debugRequestFuture.valid())
    {
        if (llmInterface.debugRequestFuture.wait_for(std::chrono::seconds(0)) != std::future_status::ready)
            return DebugRequestStartStatus::Busy;

        if (llmInterface.debugRequestAccountId == accountId)
            return DebugRequestStartStatus::ResultReady;

        try
        {
            llmInterface.debugRequestFuture.get();
        }
        catch (const std::exception& e)
        {
            sLog.outError("BotLLM: Discarding failed uncollected debug result: %s", e.what());
        }
        catch (...)
        {
            sLog.outError("BotLLM: Discarding failed uncollected debug result with an unknown error.");
        }
        sLog.outString("BotLLM: Discarded an uncollected debug result for account %u.", llmInterface.debugRequestAccountId);
        llmInterface.debugRequestAccountId = 0;
    }

    try
    {
        std::future<DebugResult> future = std::async(std::launch::async,
            [request, schemeHost, path, apiKey, timeoutSeconds]()
            {
                return GenerateDebugResponse(request, schemeHost, path, apiKey, timeoutSeconds);
            });
        llmInterface.debugRequestFuture = std::move(future);
        llmInterface.debugRequestAccountId = accountId;
    }
    catch (const std::exception& e)
    {
        error = "Unable to start LLM debug worker: " + std::string(e.what());
        return DebugRequestStartStatus::Failed;
    }
    catch (...)
    {
        error = "Unable to start LLM debug worker.";
        return DebugRequestStartStatus::Failed;
    }

    return DebugRequestStartStatus::Started;
}

PlayerbotLLMInterface::DebugResultStatus PlayerbotLLMInterface::TakeDebugResult(uint32_t accountId, DebugResult& result)
{
    PlayerbotLLMInterface& llmInterface = sPlayerbotLLMInterface;
    std::lock_guard<std::mutex> lock(llmInterface.debugRequestMutex);

    if (!llmInterface.debugRequestFuture.valid())
        return DebugResultStatus::None;
    if (llmInterface.debugRequestAccountId != accountId)
        return DebugResultStatus::NotOwner;
    if (llmInterface.debugRequestFuture.wait_for(std::chrono::seconds(0)) != std::future_status::ready)
        return DebugResultStatus::Pending;

    try
    {
        result = llmInterface.debugRequestFuture.get();
    }
    catch (const std::exception& e)
    {
        result = { false, "LLM debug worker failed: " + std::string(e.what()) };
    }
    catch (...)
    {
        result = { false, "LLM debug worker failed with an unknown error." };
    }
    llmInterface.debugRequestAccountId = 0;
    return DebugResultStatus::Ready;
}

inline std::string extractAfterPattern(const std::string& content, const std::string& startPattern) {
    if (startPattern.empty())
        return content;
        
    std::regex pattern(startPattern);
    std::smatch match;

    if (std::regex_search(content, match, pattern)) {
        size_t start_pos = match.position() + match.length();
        return content.substr(start_pos);
    }
    else {
        return "";
    }

}

inline std::string extractBeforePattern(const std::string& content, const std::string& endPattern) {
    if (endPattern.empty())
        return content;
        
    std::regex pattern(endPattern);
    std::smatch match;

    if (std::regex_search(content, match, pattern)) {
        size_t end_pos = match.position();

        return content.substr(0, end_pos);
    }
    else {
        return content;
    }
}

inline std::vector<std::string> splitResponse(const std::string& response, const std::string& splitPattern) {
    std::vector<std::string> result;
    
    if (splitPattern.empty()) {
        result.push_back(response);
        return result;
    }
    
    std::regex pattern(splitPattern);
    std::smatch match;
    
    std::sregex_iterator begin(response.begin(), response.end(), pattern);
    std::sregex_iterator end;
    for (auto it = begin; it != end; ++it) {
        result.push_back(it->str());
    }

    if(result.empty())
        result.push_back(response);

    return result;
}

std::vector<std::string> PlayerbotLLMInterface::ParseResponse(const std::string& response, const std::string& startPattern, const std::string& endPattern, const std::string& deletePattern, const std::string& splitPattern, std::vector<std::string>& debugLines)
{
    bool debug = !(debugLines.empty());
    uint32 startCursor = 0;
    uint32 endCursor = 0;

    std::string actualResponse = response;

    if (debug)
        debugLines.push_back("start pattern:" + startPattern);
    
    actualResponse = extractAfterPattern(actualResponse, startPattern);

    PlayerbotTextMgr::ReplaceAll(actualResponse, R"(\")", "'");

    if (debug)
    {
        debugLines.push_back(!actualResponse.empty() ? actualResponse : "Empty response");
        debugLines.push_back("end pattern:" + endPattern);
    }

    actualResponse = extractBeforePattern(actualResponse, endPattern);

    if (debug)
    {
        debugLines.push_back(!actualResponse.empty() ? actualResponse : "Empty response");
        debugLines.push_back("delete pattern:" + deletePattern);
    }

    if (!deletePattern.empty()) {
        std::regex regexPattern(deletePattern);
        actualResponse = std::regex_replace(actualResponse, regexPattern, "");
    }

    if (debug)
    {
        debugLines.push_back(!actualResponse.empty() ? actualResponse : "Empty response");
        debugLines.push_back("split pattern:" + splitPattern);
    }

    std::vector<std::string> responses = splitResponse(actualResponse, splitPattern);   

    if (debug)
        debugLines.insert(debugLines.end(), responses.begin(), responses.end());

    return responses;
}

void PlayerbotLLMInterface::LimitContext(std::string& context, int currentLength)
{
    if (sPlayerbotAIConfig.llmContextLength && (uint32)currentLength > sPlayerbotAIConfig.llmContextLength)
    {
        uint32 cutNeeded = currentLength - sPlayerbotAIConfig.llmContextLength;

        if (cutNeeded >= context.size())
        {
            context.clear();
        }
        else
        {
            uint32 cutPosition = cutNeeded;
            for (size_t i = cutNeeded; i < context.size(); ++i) {
                if (context[i] == ' ' || context[i] == '.') {
                    cutPosition = i + 1;
                    break;
                }
            }
            
            if (cutPosition < context.size()) {
                context = context.substr(cutPosition);
            }
            else {
                context.clear();
            }
        }
    }
}
