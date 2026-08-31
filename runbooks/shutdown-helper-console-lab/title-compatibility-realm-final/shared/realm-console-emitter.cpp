#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace
{
    HANDLE gCtrlBreakEvent = nullptr;
    volatile LONG gCtrlBreakCount = 0;

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

        int required = WideCharToMultiByte(
            CP_UTF8,
            WC_ERR_INVALID_CHARS,
            value.data(),
            static_cast<int>(value.size()),
            nullptr,
            0,
            nullptr,
            nullptr);
        if (required <= 0)
            throw std::runtime_error("WideCharToMultiByte size calculation failed.");

        std::string result(static_cast<std::size_t>(required), '\0');
        int written = WideCharToMultiByte(
            CP_UTF8,
            WC_ERR_INVALID_CHARS,
            value.data(),
            static_cast<int>(value.size()),
            &result[0],
            required,
            nullptr,
            nullptr);
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

    unsigned long ParseUnsigned(const wchar_t* value, unsigned long maximum, const char* description)
    {
        wchar_t* end = nullptr;
        unsigned long parsed = std::wcstoul(value, &end, 10);
        if (value == end || *end != L'\0' || parsed > maximum)
            throw std::runtime_error(std::string("Invalid ") + description + ".");

        return parsed;
    }

    void WriteResult(
        const std::wstring& directory,
        unsigned long exitCode,
        LONG breakCount,
        const std::string& reason)
    {
        std::ostringstream result;
        result << "EXIT_CODE=" << exitCode << "\n"
               << "CTRL_BREAK_COUNT=" << breakCount << "\n"
               << "REASON=" << reason << "\n"
               << "COMPLETED_UTC=" << GetUtcTimestamp() << "\n";
        WriteBytes(JoinPath(directory, L"emitter-result.txt"), result.str());
    }

    BOOL WINAPI ConsoleControlHandler(DWORD controlType)
    {
        if (controlType != CTRL_BREAK_EVENT)
            return FALSE;

        InterlockedIncrement(&gCtrlBreakCount);
        if (gCtrlBreakEvent != nullptr)
            SetEvent(gCtrlBreakEvent);
        return TRUE;
    }
}

int wmain(int argc, wchar_t* argv[])
{
    std::wstring directory;
    bool handlerInstalled = false;
    std::wstring requestedTitle = L"realmd";
    unsigned long ctrlBreakExitCode = 0;
    bool holdAfterBreak = false;
    DWORD idleExitMilliseconds = INFINITE;

    try
    {
        for (int index = 1; index < argc; ++index)
        {
            const std::wstring argument(argv[index]);
            if (argument == L"--title")
            {
                if (++index >= argc || argv[index][0] == L'\0')
                    throw std::runtime_error("--title requires a non-empty value.");
                requestedTitle = argv[index];
            }
            else if (argument == L"--ctrl-break-exit-code")
            {
                if (++index >= argc)
                    throw std::runtime_error("--ctrl-break-exit-code requires a value.");
                ctrlBreakExitCode = ParseUnsigned(argv[index], 255, "control-break exit code");
            }
            else if (argument == L"--hold-after-break")
            {
                holdAfterBreak = true;
            }
            else if (argument == L"--idle-exit-ms")
            {
                if (++index >= argc)
                    throw std::runtime_error("--idle-exit-ms requires a value.");
                idleExitMilliseconds = static_cast<DWORD>(
                    ParseUnsigned(argv[index], 60000, "idle exit timeout"));
                if (idleExitMilliseconds == 0)
                    throw std::runtime_error("The idle exit timeout must be greater than zero.");
            }
            else
            {
                throw std::runtime_error("Unknown emitter argument: " + WideToUtf8(argument));
            }
        }

        const std::wstring executablePath = GetExecutablePath();
        directory = GetDirectoryName(executablePath);
        const DWORD processId = GetCurrentProcessId();

        if (!SetConsoleTitleW(requestedTitle.c_str()))
            throw std::runtime_error("SetConsoleTitleW failed.");
        Sleep(100);
        const std::wstring actualTitle = GetConsoleTitleText();
        if (actualTitle != requestedTitle)
            throw std::runtime_error("The console title did not match the requested title.");

        gCtrlBreakEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (gCtrlBreakEvent == nullptr)
            throw std::runtime_error("CreateEventW failed.");

        if (!SetConsoleCtrlHandler(ConsoleControlHandler, TRUE))
            throw std::runtime_error("SetConsoleCtrlHandler failed.");
        handlerInstalled = true;

        WriteBytes(JoinPath(directory, L"received-control-events.log"), std::string());
        WriteBytes(JoinPath(directory, L"twrealmd.pid"), std::to_string(processId));

        std::ostringstream ready;
        ready << "PID=" << processId << "\n"
              << "EXE=" << WideToUtf8(executablePath) << "\n"
              << "TITLE=" << WideToUtf8(actualTitle) << "\n"
              << "CTRL_BREAK_EXIT_CODE=" << ctrlBreakExitCode << "\n"
              << "HOLD_AFTER_BREAK=" << (holdAfterBreak ? "true" : "false") << "\n"
              << "IDLE_EXIT_MS=";
        if (idleExitMilliseconds == INFINITE)
            ready << "INFINITE\n";
        else
            ready << idleExitMilliseconds << "\n";
        ready << "READY_UTC=" << GetUtcTimestamp() << "\n";
        WriteBytes(JoinPath(directory, L"emitter-ready.txt"), ready.str());

        std::cout << "Disposable realmd console emitter ready. PID=" << processId << std::endl;

        DWORD waitResult = WaitForSingleObject(gCtrlBreakEvent, idleExitMilliseconds);
        if (waitResult == WAIT_TIMEOUT)
        {
            WriteResult(directory, 0, gCtrlBreakCount, "idle_timeout");
            SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
            handlerInstalled = false;
            CloseHandle(gCtrlBreakEvent);
            gCtrlBreakEvent = nullptr;
            return 0;
        }
        if (waitResult != WAIT_OBJECT_0)
            throw std::runtime_error("WaitForSingleObject failed.");

        const LONG observedBreakCount = InterlockedCompareExchange(&gCtrlBreakCount, 0, 0);
        std::ostringstream controlEvent;
        controlEvent << "CTRL_BREAK_EVENT|COUNT=" << observedBreakCount
                     << "|UTC=" << GetUtcTimestamp() << "\n";
        WriteBytes(JoinPath(directory, L"received-control-events.log"), controlEvent.str());

        if (holdAfterBreak)
        {
            std::ostringstream state;
            state << "STATE=HOLDING_AFTER_CTRL_BREAK\n"
                  << "CTRL_BREAK_COUNT=" << observedBreakCount << "\n"
                  << "RECORDED_UTC=" << GetUtcTimestamp() << "\n";
            WriteBytes(JoinPath(directory, L"emitter-state.txt"), state.str());
            Sleep(INFINITE);
        }

        WriteResult(directory, ctrlBreakExitCode, observedBreakCount, "ctrl_break_received");
        SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
        handlerInstalled = false;
        CloseHandle(gCtrlBreakEvent);
        gCtrlBreakEvent = nullptr;
        return static_cast<int>(ctrlBreakExitCode);
    }
    catch (const std::exception& error)
    {
        try
        {
            if (!directory.empty())
            {
                WriteBytes(
                    JoinPath(directory, L"emitter-fatal.txt"),
                    std::string("ERROR=") + error.what() + "\nUTC=" + GetUtcTimestamp() + "\n");
            }
        }
        catch (...)
        {
        }

        if (handlerInstalled)
            SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
        if (gCtrlBreakEvent != nullptr)
        {
            CloseHandle(gCtrlBreakEvent);
            gCtrlBreakEvent = nullptr;
        }

        std::cerr << "Disposable realm emitter failure: " << error.what() << std::endl;
        return 4;
    }
}
