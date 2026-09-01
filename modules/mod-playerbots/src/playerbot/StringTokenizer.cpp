#include "StringTokenizer.h"

namespace playerbot
{
void AppendTokens(std::vector<std::string>& destination, std::string const& input,
                  char const* delimiters)
{
    std::string const delimiterSet = delimiters ? delimiters : "";
    std::string::size_type tokenStart = input.find_first_not_of(delimiterSet);

    while (tokenStart != std::string::npos)
    {
        std::string::size_type const tokenEnd = input.find_first_of(delimiterSet, tokenStart);
        destination.emplace_back(input.substr(tokenStart, tokenEnd - tokenStart));

        if (tokenEnd == std::string::npos)
            break;

        tokenStart = input.find_first_not_of(delimiterSet, tokenEnd);
    }
}
}
