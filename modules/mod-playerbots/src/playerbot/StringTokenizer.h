#pragma once

#include <string>
#include <vector>

namespace playerbot
{
// Appends each non-empty token in input to destination. Every byte in
// delimiters is an independent separator, matching strtok_r's delimiter-set
// semantics without process-wide or thread-local parser state.
void AppendTokens(std::vector<std::string>& destination, std::string const& input,
                  char const* delimiters);
}
