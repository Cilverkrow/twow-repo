#include "BotBrainClient.h"

#include "httplib.h"

#include <algorithm>

namespace botbrain
{
    namespace
    {
        // A brain that answers with a gigabyte is a brain that takes the
        // worldserver down with it. The contract's own cap is 2048 snapshots
        // per batch; a response to one bot has no business being large.
        size_t constexpr kMaxResponseBytes = 4u * 1024u * 1024u;

        HttpResult Send(std::string const& endpoint, char const* method, char const* path,
            std::string const& body, uint32_t timeoutMs)
        {
            HttpResult result;
            try
            {
                httplib::Client client(endpoint);
                if (!client.is_valid())
                {
                    result.error = "invalid endpoint: " + endpoint;
                    return result;
                }

                // httplib takes whole seconds plus microseconds; the contract
                // budget is in milliseconds and is usually under a second, so
                // rounding to seconds would multiply every deadline by ~1.3.
                uint32_t const ms = std::max<uint32_t>(50, timeoutMs);
                time_t const sec = static_cast<time_t>(ms / 1000);
                time_t const usec = static_cast<time_t>((ms % 1000) * 1000);
                client.set_connection_timeout(sec, usec);
                client.set_read_timeout(sec, usec);
                client.set_write_timeout(sec, usec);

                httplib::Request request;
                request.method = method;
                request.path = path;
                if (!body.empty())
                {
                    request.body = body;
                    request.set_header("Content-Type", "application/json");
                }
                request.set_header("Accept", "application/json");

                bool tooLarge = false;
                std::string received;
                request.response_handler = [&tooLarge](httplib::Response const& response)
                {
                    if (response.has_header("Content-Length") &&
                        response.get_header_value_u64("Content-Length") > kMaxResponseBytes)
                    {
                        tooLarge = true;
                        return false;
                    }
                    return true;
                };
                request.content_receiver = [&received, &tooLarge](char const* data, size_t length, uint64_t, uint64_t)
                {
                    if (received.size() + length > kMaxResponseBytes)
                    {
                        tooLarge = true;
                        return false;
                    }
                    received.append(data, length);
                    return true;
                };

                httplib::Response response;
                httplib::Error error = httplib::Error::Unknown;
                if (!client.send(request, response, error))
                {
                    result.error = tooLarge
                        ? "response body exceeds 4 MiB"
                        : "transport failure: " + httplib::to_string(error);
                    return result;
                }

                result.status = response.status;
                result.body = received;
                result.ok = response.status == 200;
                if (!result.ok)
                    result.error = "HTTP status " + std::to_string(response.status);
                return result;
            }
            catch (std::exception const& e)
            {
                // Nothing in httplib is documented to throw here, but this call
                // runs on a detached thread: an escaping exception is
                // std::terminate for the whole worldserver, not a failed bot.
                result.ok = false;
                result.error = std::string("exception: ") + e.what();
                return result;
            }
            catch (...)
            {
                result.ok = false;
                result.error = "unknown exception";
                return result;
            }
        }
    }

    HttpResult FetchContract(std::string const& endpoint, uint32_t timeoutMs)
    {
        return Send(endpoint, "GET", "/v1/contract", std::string(), timeoutMs);
    }

    HttpResult PostPlan(std::string const& endpoint, std::string const& body, uint32_t timeoutMs)
    {
        return Send(endpoint, "POST", "/v1/plan", body, timeoutMs);
    }
}
