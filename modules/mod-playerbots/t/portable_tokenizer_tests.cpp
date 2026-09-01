#include "StringTokenizer.h"

#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace
{
std::atomic<unsigned> failures{0};

void Check(std::vector<std::string> const& actual, std::vector<std::string> const& expected,
           char const* testName)
{
    if (actual == expected)
        return;

    ++failures;
    std::cerr << testName << ": token sequence mismatch\n";
}

void CheckSplit(std::string const& input, char const* delimiters,
                std::vector<std::string> const& expected, char const* testName)
{
    std::vector<std::string> actual;
    playerbot::AppendTokens(actual, input, delimiters);
    Check(actual, expected, testName);
}

void RunSemanticTests()
{
    CheckSplit("", ",", {}, "empty string");
    CheckSplit("alpha", ",", {"alpha"}, "no delimiter");
    CheckSplit("alpha,beta", ",", {"alpha", "beta"}, "single delimiter");
    CheckSplit("alpha,beta;gamma", ",;", {"alpha", "beta", "gamma"},
               "multiple delimiter bytes");
    CheckSplit(",,alpha,,beta,", ",", {"alpha", "beta"},
               "leading repeated trailing delimiters");
    CheckSplit(",;;;,,", ",;", {}, "only delimiters");
    CheckSplit(u8"Grüße|世界|🙂", "|", {u8"Grüße", u8"世界", u8"🙂"},
               "UTF-8 bytes");
    CheckSplit(";alpha,,beta|gamma;", ",;|", {"alpha", "beta", "gamma"},
               "documented legacy token sequence");

    std::vector<std::string> appended{"existing"};
    playerbot::AppendTokens(appended, "alpha,beta", ",");
    Check(appended, {"existing", "alpha", "beta"}, "append preserves destination");
}

void RunParallelTests()
{
    std::atomic<bool> start{false};
    auto worker = [&start](std::string const& input, char const* delimiters,
                           std::vector<std::string> const& expected, char const* testName)
    {
        while (!start.load(std::memory_order_acquire))
            std::this_thread::yield();

        for (unsigned iteration = 0; iteration < 2000; ++iteration)
            CheckSplit(input, delimiters, expected, testName);
    };

    std::thread first(worker, "a,b;;c", ",;", std::vector<std::string>{"a", "b", "c"},
                      "parallel first");
    std::thread second(worker, "one|two::three", "|:",
                       std::vector<std::string>{"one", "two", "three"}, "parallel second");
    start.store(true, std::memory_order_release);
    first.join();
    second.join();
}
}

int main()
{
    RunSemanticTests();
    for (unsigned repetition = 0; repetition < 32; ++repetition)
        RunParallelTests();

    if (failures.load() != 0)
    {
        std::cerr << failures.load() << " tokenizer checks failed\n";
        return 1;
    }

    std::cout << "portable tokenizer tests passed\n";
    return 0;
}
