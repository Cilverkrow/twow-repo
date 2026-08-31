#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

namespace
{
    std::string GetUtcTimestamp()
    {
        SYSTEMTIME time = {};
        GetSystemTime(&time);

        std::ostringstream stream;
        stream << std::setfill('0')
               << std::setw(4) << time.wYear << '-'
               << std::setw(2) << time.wMonth << '-'
               << std::setw(2) << time.wDay << 'T'
               << std::setw(2) << time.wHour << ':'
               << std::setw(2) << time.wMinute << ':'
               << std::setw(2) << time.wSecond << '.'
               << std::setw(3) << time.wMilliseconds << 'Z';
        return stream.str();
    }

    std::wstring GetExecutablePath()
    {
        std::wstring path(32768, L'\0');
        DWORD length = GetModuleFileNameW(nullptr, &path[0], static_cast<DWORD>(path.size()));
        if (length == 0 || length >= path.size())
            throw std::runtime_error("GetModuleFileNameW failed.");

        path.resize(length);
        return path;
    }

    std::wstring GetDirectoryName(const std::wstring& path)
    {
        const std::wstring::size_type separator = path.find_last_of(L"\\/");
        if (separator == std::wstring::npos)
            throw std::runtime_error("The executable path has no directory component.");

        return path.substr(0, separator);
    }

    std::wstring JoinPath(const std::wstring& directory, const wchar_t* name)
    {
        return directory + L"\\" + name;
    }

    std::wstring GetConsoleTitleText()
    {
        std::wstring title(1024, L'\0');
        DWORD length = GetConsoleTitleW(&title[0], static_cast<DWORD>(title.size()));
        if (length == 0)
            throw std::runtime_error("GetConsoleTitleW returned an empty or unreadable title.");

        title.resize(length);
        return title;
    }

    std::string WideToUtf8(const std::wstring& value)
    {
        if (value.empty())
            return std::string();

        int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
        if (required <= 0)
            throw std::runtime_error("WideCharToMultiByte size calculation failed.");

        std::string result(static_cast<std::size_t>(required), '\0');
        int written = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), &result[0], required, nullptr, nullptr);
        if (written != required)
            throw std::runtime_error("WideCharToMultiByte conversion failed.");

        return result;
    }

    void WriteBytes(const std::wstring& path, const std::string& value)
    {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if (!output)
            throw std::runtime_error("Could not open an emitter evidence file.");

        output.write(value.data(), static_cast<std::streamsize>(value.size()));
        output.flush();
        if (!output)
            throw std::runtime_error("Could not write an emitter evidence file.");
    }

    std::string ToHex(const std::string& value)
    {
        static const char digits[] = "0123456789ABCDEF";
        std::string result;
        result.reserve(value.size() * 2);
        for (unsigned char character : value)
        {
            result.push_back(digits[(character >> 4) & 0x0F]);
            result.push_back(digits[character & 0x0F]);
        }
        return result;
    }

    std::string EscapeForLog(const std::string& value)
    {
        std::ostringstream stream;
        for (unsigned char character : value)
        {
            if (character == '\\')
                stream << "\\\\";
            else if (character == '|')
                stream << "\\|";
            else if (character >= 0x20 && character <= 0x7E)
                stream << static_cast<char>(character);
            else
                stream << "\\x" << std::uppercase << std::hex << std::setw(2)
                       << std::setfill('0') << static_cast<unsigned int>(character)
                       << std::dec;
        }
        return stream.str();
    }

    void WriteResult(const std::wstring& directory, int exitCode, bool saveAllSeen,
        unsigned int receivedLineCount, const std::string& reason)
    {
        std::ostringstream result;
        result << "EXIT_CODE=" << exitCode << "\n"
               << "SAVEALL_SEEN=" << (saveAllSeen ? "true" : "false") << "\n"
               << "RECEIVED_LINE_COUNT=" << receivedLineCount << "\n"
               << "REASON=" << reason << "\n"
               << "COMPLETED_UTC=" << GetUtcTimestamp() << "\n";
        WriteBytes(JoinPath(directory, L"emitter-result.txt"), result.str());
    }
}

int main()
{
    std::wstring directory;
    bool saveAllSeen = false;
    unsigned int receivedLineCount = 0;

    try
    {
        const std::wstring executablePath = GetExecutablePath();
        directory = GetDirectoryName(executablePath);
        const DWORD processId = GetCurrentProcessId();
        const std::wstring initialConsoleTitle = GetConsoleTitleText();

        if (!SetConsoleTitleW(L"mangosd"))
            throw std::runtime_error("SetConsoleTitleW failed.");

        Sleep(100);
        const std::wstring consoleTitle = GetConsoleTitleText();

        WriteBytes(JoinPath(directory, L"twlive.pid"), std::to_string(processId));

        if (consoleTitle != L"mangosd")
        {
            WriteResult(directory, 5, false, 0, "unexpected_console_title");
            return 5;
        }

        std::ofstream commandLog(JoinPath(directory, L"received-commands.log"),
            std::ios::binary | std::ios::trunc);
        if (!commandLog)
            throw std::runtime_error("Could not open received-commands.log.");

        std::ostringstream ready;
        ready << "PID=" << processId << "\n"
              << "EXE=" << WideToUtf8(executablePath) << "\n"
              << "TITLE_BEFORE=" << WideToUtf8(initialConsoleTitle) << "\n"
              << "TITLE=" << WideToUtf8(consoleTitle) << "\n"
              << "READY_UTC=" << GetUtcTimestamp() << "\n";
        WriteBytes(JoinPath(directory, L"emitter-ready.txt"), ready.str());

        std::cout << "Disposable mangosd console emitter ready. PID=" << processId << std::endl;

        std::string line;
        while (std::getline(std::cin, line))
        {
            ++receivedLineCount;
            commandLog << GetUtcTimestamp()
                       << "|SEQUENCE=" << receivedLineCount
                       << "|HEX=" << ToHex(line)
                       << "|TEXT=" << EscapeForLog(line)
                       << "\n";
            commandLog.flush();
            if (!commandLog)
                throw std::runtime_error("Could not persist a received console line.");

            if (line == "saveall")
                saveAllSeen = true;

            if (line == "server shutdown 0")
            {
                WriteResult(directory, 0, saveAllSeen, receivedLineCount,
                    "server_shutdown_0_received");
                return 0;
            }
        }

        WriteResult(directory, 3, saveAllSeen, receivedLineCount, "console_input_eof");
        return 3;
    }
    catch (const std::exception& error)
    {
        try
        {
            if (!directory.empty())
            {
                WriteBytes(JoinPath(directory, L"emitter-fatal.txt"),
                    std::string("ERROR=") + error.what() + "\nUTC=" + GetUtcTimestamp() + "\n");
                WriteResult(directory, 4, saveAllSeen, receivedLineCount, "fatal_exception");
            }
        }
        catch (...)
        {
        }

        std::cerr << "Disposable emitter failure: " << error.what() << std::endl;
        return 4;
    }
}
