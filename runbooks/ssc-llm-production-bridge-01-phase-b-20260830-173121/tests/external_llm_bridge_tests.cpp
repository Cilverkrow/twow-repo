#define SSC_EXTERNAL_LLM_BRIDGE_STANDALONE 1
#include "playerbot/ExternalLLMBridgeService.cpp"

#include <iostream>

namespace
{
int failures = 0;
int tests = 0;

void Check(bool condition, char const* name)
{
    ++tests;
    std::cout << (condition ? "ok " : "not ok ") << tests << " - " << name << "\n";
    if (!condition) ++failures;
}

Json Status(std::string const& id, char const* state, int attempt, Json error)
{
    return Json{ {"schema_version",1}, {"request_id",id}, {"bot_guid",18281}, {"state",state},
        {"queued_utc","2026-08-30T12:00:00.000Z"}, {"updated_utc","2026-08-30T12:00:00.100Z"},
        {"attempt_count",attempt}, {"error_code",error} };
}

Json Metrics(bool stopped)
{
    return Json{ {"lifecycle",stopped ? "stopped" : "running"}, {"accepting",!stopped}, {"waiting",0},
        {"ledger_entries",1}, {"active",0}, {"max_active_observed",1}, {"inference_attempts",1},
        {"stale_results_discarded",0}, {"worker_owned",true}, {"worker_settled",stopped} };
}

void WriteJson(Json const& value)
{
    std::cout << value.dump() << '\n' << std::flush;
}

long long ParseUtcMilliseconds(std::string const& value)
{
    SYSTEMTIME time{};
    int millis=0;
    if (std::sscanf(value.c_str(), "%hu-%hu-%huT%hu:%hu:%hu.%dZ", &time.wYear,&time.wMonth,&time.wDay,
        &time.wHour,&time.wMinute,&time.wSecond,&millis) != 7) return -1;
    time.wMilliseconds=static_cast<WORD>(millis);
    FILETIME file{};
    if (!SystemTimeToFileTime(&time,&file)) return -1;
    ULARGE_INTEGER ticks{}; ticks.LowPart=file.dwLowDateTime; ticks.HighPart=file.dwHighDateTime;
    return static_cast<long long>(ticks.QuadPart/10000ULL);
}

int ChildMain(std::string mode, std::string handleText)
{
    if (mode == "timeout") { Sleep(5000); return 0; }
    if (mode == "eof") return 0;
    if (mode == "invalid") { std::cout << "{bad\n" << std::flush; Sleep(100); return 0; }
    if (mode == "sentinel")
    {
        std::wstring eventName(handleText.begin(), handleText.end());
        HANDLE event = OpenEventW(SYNCHRONIZE, FALSE, eventName.c_str());
        if (!event) return 8;
        WaitForSingleObject(event, 60000);
        CloseHandle(event);
        return 0;
    }
    if (mode == "inherit")
    {
        HANDLE candidate = reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(std::stoull(handleText)));
        DWORD flags = 0;
        bool inherited = GetHandleInformation(candidate, &flags) != FALSE;
        std::cerr << "inherited=" << (inherited ? 1 : 0) << '\n' << std::flush;
    }
    if (mode == "stderr")
    {
        std::string flood(70000, 'X');
        flood.replace(flood.size() - 12, 12, "STDERR_TAIL!");
        std::cerr << flood << std::flush;
    }
    Json ready{ {"code","ready"}, {"mode","server_free_ndjson"}, {"active_limit",1}, {"waiting_capacity",2},
        {"ledger_capacity",64}, {"bot_guid",18281}, {"model","qwen2.5:7b"} };
    if (mode == "badready") ready["extra"] = true;
    WriteJson(ready);
    if (mode == "badready") return 0;
    if (mode == "unsolicited") { WriteJson(ready); Sleep(100); return 0; }

    std::map<std::string, int> polls;
    int submits = 0;
    int consumes = 0;
    Clock::time_point lastPoll{};
    for (std::string line; std::getline(std::cin, line);)
    {
        Json command;
        try { command = Json::parse(line); } catch (...) { return 9; }
        std::string type = command["command"].get<std::string>();
        if (type == "submit")
        {
            ++submits;
            std::string id = command["request"]["request_id"].get<std::string>();
            long long created=ParseUtcMilliseconds(command["request"]["created_utc"].get<std::string>());
            long long expires=ParseUtcMilliseconds(command["request"]["expires_utc"].get<std::string>());
            std::cerr << "wire_ttl_ms=" << (expires-created) << '\n' << std::flush;
            if (mode == "ledger" && submits == 2)
                WriteJson(Json{ {"accepted",false}, {"code","ledger_full"}, {"status",nullptr} });
            else
                WriteJson(Json{ {"accepted",true}, {"code","queued"}, {"status",Status(id,"queued",0,nullptr)} });
        }
        else if (type == "status")
        {
            std::string id = command["request_id"].get<std::string>();
            ++polls[id];
            Clock::time_point now = Clock::now();
            if (lastPoll != Clock::time_point{})
                std::cerr << "poll_delta_ms=" << std::chrono::duration_cast<std::chrono::milliseconds>(now-lastPoll).count() << '\n' << std::flush;
            lastPoll = now;
            bool running = mode == "hold" || mode == "deadline" || (mode == "poll" && polls[id] == 1);
            WriteJson(Json{ {"code","ok"}, {"status",Status(id,running ? "running" : "ready",1,nullptr)} });
        }
        else if (type == "consume")
        {
            ++consumes;
            std::string id = command["request_id"].get<std::string>();
            Json completion{ {"schema_version",1}, {"request_id",id}, {"bot_guid",18281}, {"outcome","ready"},
                {"model","qwen2.5:7b"}, {"attempt_count",1}, {"started_utc","2026-08-30T12:00:00.010Z"},
                {"completed_utc","2026-08-30T12:00:00.090Z"}, {"text","I will patrol the road today."},
                {"error_code",nullptr}, {"raw_response_bytes",120} };
            WriteJson(Json{ {"code","consumed"}, {"status",Status(id,"consumed",1,nullptr)}, {"completion",completion} });
        }
        else if (type == "shutdown")
        {
            std::cerr << "submit_count=" << submits << " consume_count=" << consumes << '\n' << std::flush;
            if (mode == "hangshutdown") { Sleep(5000); return 0; }
            WriteJson(Json{ {"code","shutdown"}, {"metrics",Metrics(true)} });
            return 0;
        }
        else return 10;
    }
    return 0;
}

std::wstring SelfPath()
{
    std::vector<wchar_t> buffer(32768);
    DWORD count = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    return std::wstring(buffer.data(), count);
}

bool WaitUntil(std::function<bool()> predicate, std::uint32_t timeoutMs)
{
    Clock::time_point deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (Clock::now() < deadline)
    {
        if (predicate()) return true;
        Sleep(10);
    }
    return predicate();
}

bool StartSentinel(std::wstring const& self, std::wstring const& eventName, UniqueHandle& process)
{
    std::wstring command = QuoteWindowsArg(self) + L" --child sentinel " + QuoteWindowsArg(eventName);
    std::vector<wchar_t> mutableCommand(command.begin(), command.end()); mutableCommand.push_back(0);
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION info{};
    if (!CreateProcessW(self.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &info)) return false;
    CloseHandle(info.hThread); process.Reset(info.hProcess); return true;
}

void TestWireMatrix()
{
    std::string const id = "12345678-1234-4abc-8def-1234567890ab";
    Json ready{ {"code","ready"}, {"mode","server_free_ndjson"}, {"active_limit",1}, {"waiting_capacity",2},
        {"ledger_capacity",64}, {"bot_guid",18281}, {"model","qwen2.5:7b"} };
    Check(ValidateReady(ready), "exact Ready accepted");
    for (char const* field : {"code","mode","active_limit","waiting_capacity","ledger_capacity","bot_guid","model"})
    { Json changed=ready; changed.erase(field); Check(!ValidateReady(changed), (std::string("Ready missing ")+field).c_str()); }
    { Json changed=ready; changed["extra"]=1; Check(!ValidateReady(changed), "Ready extra field rejected"); }
    { Json changed=ready; changed["bot_guid"]=nullptr; Check(!ValidateReady(changed), "Ready null rejected"); }
    { Json changed=ready; changed["active_limit"]="1"; Check(!ValidateReady(changed), "Ready wrong type rejected"); }
    { Json changed=ready; changed["model"]="other"; Check(!ValidateReady(changed), "Ready wrong pin rejected"); }

    Check(ExternalLLMBridgeTestHarness::Strict("{\"a\":1}"), "strict JSON valid");
    Check(!ExternalLLMBridgeTestHarness::Strict("{\"a\":1,\"a\":2}"), "duplicate key rejected");
    Check(!ExternalLLMBridgeTestHarness::Strict(std::string("\xef\xbb\xbf")+"{}"), "UTF-8 BOM rejected");
    Check(!ExternalLLMBridgeTestHarness::Strict(std::string("{\"x\":\"")+char(0xc0)+char(0x80)+"\"}"), "malformed UTF-8 rejected");
    Check(!ExternalLLMBridgeTestHarness::Strict("{}{}"), "trailing JSON rejected");
    Check(!ExternalLLMBridgeTestHarness::Strict(""), "empty NDJSON line rejected");
    Check(!ExternalLLMBridgeTestHarness::Strict(std::string(ExternalLLMBridgeService::StdoutNdjsonLineCapBytes+1,'x')), "NDJSON line cap enforced");

    Json queued{ {"accepted",true}, {"code","queued"}, {"status",Status(id,"queued",0,nullptr)} };
    Check(ExternalLLMBridgeTestHarness::Response(1,queued.dump(),id), "submit queued variant");
    Check(ExternalLLMBridgeTestHarness::Response(1,Json{{"accepted",false},{"code","duplicate"},{"status",Status(id,"running",1,nullptr)}}.dump(),id), "submit duplicate variant");
    Check(ExternalLLMBridgeTestHarness::Response(1,Json{{"accepted",false},{"code","identity_mismatch"},{"status",nullptr}}.dump(),id), "submit mismatch variant");
    Check(ExternalLLMBridgeTestHarness::Response(1,Json{{"accepted",false},{"code","queue_full"},{"status",Status(id,"failed",0,"queue_full")}}.dump(),id), "submit queue-full variant");
    Check(ExternalLLMBridgeTestHarness::Response(1,Json{{"accepted",false},{"code","expired"},{"status",Status(id,"expired",0,"expired_before_run")}}.dump(),id), "submit expired variant");
    Check(ExternalLLMBridgeTestHarness::Response(1,Json{{"accepted",false},{"code","ledger_full"},{"status",nullptr}}.dump(),id), "submit ledger-full variant");
    { Json changed=queued; changed["extra"]=1; Check(!ExternalLLMBridgeTestHarness::Response(1,changed.dump(),id), "submit extra field rejected"); }
    { Json changed=queued; changed["accepted"]=nullptr; Check(!ExternalLLMBridgeTestHarness::Response(1,changed.dump(),id), "submit null rejected"); }
    { Json changed=queued; changed["code"]="metrics"; Check(!ExternalLLMBridgeTestHarness::Response(1,changed.dump(),id), "wrong-context code rejected"); }
    { Json changed=queued; changed["code"]="future_code"; Check(!ExternalLLMBridgeTestHarness::Response(1,changed.dump(),id), "unknown code rejected"); }
    Check(!ExternalLLMBridgeTestHarness::Response(1,Json{{"code","invalid_uuid"},{"message","bad"}}.dump(),id), "exact CLI error closes rather than becoming normal result");

    Check(ExternalLLMBridgeTestHarness::Response(2,Json{{"code","ok"},{"status",Status(id,"ready",1,nullptr)}}.dump(),id), "status ok variant");
    for (char const* code : {"invalid_uuid","invalid_bot_guid","not_found","identity_mismatch"})
        Check(ExternalLLMBridgeTestHarness::Response(2,Json{{"code",code},{"status",nullptr}}.dump(),id), (std::string("status ")+code).c_str());

    Json completion{ {"schema_version",1},{"request_id",id},{"bot_guid",18281},{"outcome","ready"},{"model","qwen2.5:7b"},
        {"attempt_count",1},{"started_utc","2026-08-30T12:00:00.010Z"},{"completed_utc","2026-08-30T12:00:00.090Z"},
        {"text","Two short sentences. Exactly two!"},{"error_code",nullptr},{"raw_response_bytes",50} };
    Check(ExternalLLMBridgeTestHarness::Response(3,Json{{"code","consumed"},{"status",Status(id,"consumed",1,nullptr)},{"completion",completion}}.dump(),id), "consume consumed ready variant");
    Check(ExternalLLMBridgeTestHarness::Response(3,Json{{"code","not_ready"},{"status",Status(id,"running",1,nullptr)},{"completion",nullptr}}.dump(),id), "consume not-ready variant");
    Check(ExternalLLMBridgeTestHarness::Response(3,Json{{"code","already_consumed"},{"status",Status(id,"consumed",1,nullptr)},{"completion",nullptr}}.dump(),id), "consume already-consumed no text");
    for (char const* code : {"invalid_uuid","invalid_bot_guid","not_found","identity_mismatch"})
        Check(ExternalLLMBridgeTestHarness::Response(3,Json{{"code",code},{"status",nullptr},{"completion",nullptr}}.dump(),id), (std::string("consume ")+code).c_str());
    Check(ExternalLLMBridgeTestHarness::Response(4,Json{{"code","metrics"},{"metrics",Metrics(false)}}.dump(),id), "metrics exact envelope");
    Check(ExternalLLMBridgeTestHarness::Response(5,Json{{"code","shutdown"},{"metrics",Metrics(true)}}.dump(),id), "shutdown exact envelope");
    Check(!ExternalLLMBridgeTestHarness::Response(5,Json{{"code","shutdown"},{"metrics",Metrics(false)}}.dump(),id), "shutdown running metrics rejected");

    Json failed=completion; failed["outcome"]="failed"; failed["model"]=nullptr; failed["attempt_count"]=0;
    failed["started_utc"]=nullptr; failed["text"]=nullptr; failed["error_code"]="queue_full"; failed["raw_response_bytes"]=nullptr;
    Completion nonready;
    Check(ValidateCompletion(failed,id,nonready), "nonready attempt-zero invariants");
    failed["text"]="leak"; Completion sink; Check(!ValidateCompletion(failed,id,sink), "nonready text rejected");

    Check(ExternalLLMBridgeTestHarness::Text("First sentence. Second sentence!"), "exact two sentences accepted");
    Check(!ExternalLLMBridgeTestHarness::Text("One.Two!Three?"), "three sentences without spaces rejected");
    Check(ExternalLLMBridgeTestHarness::Text("Wait… Really?"), "Unicode ellipsis counted as terminator run");
    Check(!ExternalLLMBridgeTestHarness::Text("One…Two?Three!"), "three Unicode/ASCII terminator runs rejected");
    Check(!ExternalLLMBridgeTestHarness::Text(std::string(241,'a')), "240-byte limit enforced without truncation");
    Check(!ExternalLLMBridgeTestHarness::Text(std::string("not")+"\xc2\xa0"+"canonical"), "non-ASCII sanitizer whitespace rejected");
}

void TestProcessScenarios()
{
    std::wstring const self=SelfPath();
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"good"},1000),"fake child exact Ready");
        h.Observe(0x0000000000004769ULL,1,100,"Bot"); h.Observe(0x0000000000000100ULL,2,200,"Player");
        Check(h.Submit(0x4769,0x100,"Player","Was hast du heute vor?")==ExternalLLMBridgeService::SubmitResult::Admitted,"one request admitted");
        Check(WaitUntil([&]{return h.Deliveries()==1;},2000),"completion consumed once");
        Check(h.DrainValidDeliveries()==1,"valid snapshot yields exactly one whisper token");
        Check(h.DrainValidDeliveries()==0,"delivery retired before second whisper");
        h.Shutdown(); Check(h.Stderr().find("consume_count=1")!=std::string::npos,"exactly one consume sent");
        Check(h.Stderr().find("wire_ttl_ms=45000")!=std::string::npos,"wire evidence uses exact 45-second lifetime");
    }
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"good"},1000),"revalidation child Ready");
        h.Observe(0x4769,1,100,"Bot"); h.Observe(0x101,2,200,"Player");
        Check(h.Submit(0x4769,0x101,"Player","Hello") == ExternalLLMBridgeService::SubmitResult::Admitted,"revalidation request admitted");
        Check(WaitUntil([&]{return h.Deliveries()==1;},2000),"revalidation completion ready");
        h.Invalidate(0x101); Check(h.Sessions()==1,"logout removes inactive session fingerprint"); h.Observe(0x101,2,200,"Player");
        Check(h.DrainValidDeliveries()==0,"logout/relog generation mismatch discards completion"); h.Shutdown();
    }
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"ledger"},1000),"ledger child Ready");
        h.Observe(0x4769,1,100,"Bot"); h.Observe(0x102,2,200,"A"); h.Observe(0x103,3,300,"B"); h.Observe(0x104,4,400,"C"); h.Observe(0x105,5,500,"D");
        Check(h.Submit(0x4769,0x102,"A","one")==ExternalLLMBridgeService::SubmitResult::Admitted,"pre-latch route one admitted");
        Check(h.Submit(0x4769,0x103,"B","two")==ExternalLLMBridgeService::SubmitResult::Admitted,"latch-triggering route admitted locally");
        Check(h.Submit(0x4769,0x104,"C","pending")==ExternalLLMBridgeService::SubmitResult::Admitted,"third local route admitted before latch");
        Check(WaitUntil([&]{return h.State()==ExternalLLMBridgeService::State::LedgerExhausted;},2000),"ledger_full permanent latch set");
        Check(h.Routes()<=1,"unsubmitted local route retired by latch");
        Check(h.Submit(0x4769,0x105,"D","three")==ExternalLLMBridgeService::SubmitResult::LocallyRejectedLedgerExhausted,"post-latch request rejected before wire");
        Check(WaitUntil([&]{return h.Deliveries()==1;},2000),"pre-latch accepted route still polled and consumed");
        Check(h.DrainValidDeliveries()==1,"pre-latch completion remains deliverable"); h.Shutdown();
        Check(h.Stderr().find("submit_count=2")!=std::string::npos,"no post-latch submit bytes");
    }
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"hold"},1000),"queue child Ready");
        h.Observe(0x4769,1,100,"Bot"); for(int i=0;i<4;++i) h.Observe(0x200+i,10+i,200+i,"P"+std::to_string(i));
        Check(h.Submit(0x4769,0x200,"P0","a")==ExternalLLMBridgeService::SubmitResult::Admitted,"queue slot 1");
        Check(h.Submit(0x4769,0x201,"P1","b")==ExternalLLMBridgeService::SubmitResult::Admitted,"queue slot 2");
        Check(h.Submit(0x4769,0x202,"P2","c")==ExternalLLMBridgeService::SubmitResult::Admitted,"queue slot 3");
        Check(h.Submit(0x4769,0x203,"P3","d")==ExternalLLMBridgeService::SubmitResult::LocallyRejected,"fourth route rejected by bound"); h.Shutdown();
    }
    {
        ExternalLLMBridgeTestHarness h; h.SetTimeouts(100,1000); Check(h.Start(self,{L"--child",L"deadline"},1000),"deadline child Ready");
        h.Observe(0x4769,1,100,"Bot"); h.Observe(0x300,2,200,"P"); h.Submit(0x4769,0x300,"P","deadline");
        Check(WaitUntil([&]{return h.Routes()==0;},1000),"steady deadline expires route"); h.Shutdown();
        Check(h.Stderr().find("wire_ttl_ms=100")!=std::string::npos,"wire TTL and internal steady TTL derive from one admission");
    }
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"stderr"},2000),"large stderr child Ready without deadlock");
        Check(h.Stderr().size()==ExternalLLMBridgeService::StderrDiagnosticCapBytes,"stderr ring exactly bounded");
        Check(h.Stderr().find("STDERR_TAIL!")!=std::string::npos,"stderr ring retains newest bytes"); h.Shutdown();
    }
    {
        SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE}; UniqueHandle event(CreateEventW(&sa,TRUE,FALSE,nullptr));
        std::wstring handle=std::to_wstring(reinterpret_cast<std::uintptr_t>(event.Get())); ExternalLLMBridgeTestHarness h;
        Check(h.Start(self,{L"--child",L"inherit",handle},1000),"handle test child Ready"); h.Shutdown();
        Check(h.Stderr().find("inherited=0")!=std::string::npos,"non-allowlisted inheritable handle not inherited");
    }
    {
        ExternalLLMBridgeTestHarness h; Check(!h.Start(self,{L"--child",L"timeout"},100),"Ready timeout closes admission");
        Check(h.State()==ExternalLLMBridgeService::State::ProtocolFailed,"Ready timeout classified protocol failure"); h.Shutdown();
    }
    {
        ExternalLLMBridgeTestHarness h; Check(!h.Start(self,{L"--child",L"eof"},1000),"EOF before Ready rejected"); h.Shutdown();
        ExternalLLMBridgeTestHarness i; Check(!i.Start(self,{L"--child",L"invalid"},1000),"invalid NDJSON rejected"); i.Shutdown();
        ExternalLLMBridgeTestHarness j; Check(!j.Start(self,{L"--child",L"badready"},1000),"Ready extra field rejected by process path"); j.Shutdown();
        ExternalLLMBridgeTestHarness k; Check(k.Start(self,{L"--child",L"unsolicited"},1000),"unsolicited test reaches Ready");
        Check(WaitUntil([&]{return k.State()==ExternalLLMBridgeService::State::ProtocolFailed;},1000),"unsolicited duplicate response closes admission"); k.Shutdown();
    }
    {
        ExternalLLMBridgeTestHarness h; Check(h.Start(self,{L"--child",L"poll"},1000),"poll child Ready");
        h.Observe(0x4769,1,100,"Bot"); h.Observe(0x400,2,200,"P"); h.Submit(0x4769,0x400,"P","poll");
        Check(WaitUntil([&]{return h.Deliveries()==1;},2500),"round-robin poll reaches completion"); h.DrainValidDeliveries(); h.Shutdown();
        std::string diagnostic=h.Stderr(); std::size_t marker=diagnostic.find("poll_delta_ms=");
        long long delta=marker==std::string::npos ? -1 : std::stoll(diagnostic.substr(marker+14));
        std::cout << "# observed_poll_delta_ms=" << delta << "\n";
        Check(delta>=100,"global poll interval is at least 100 ms");
    }
    {
        std::wstring eventName=L"Local\\SSCPhaseBSentinel-"+std::to_wstring(GetCurrentProcessId());
        UniqueHandle event(CreateEventW(nullptr,TRUE,FALSE,eventName.c_str())), sentinel;
        Check(event.Valid() && StartSentinel(self,eventName,sentinel),"sentinel fake process started");
        ExternalLLMBridgeTestHarness h; h.SetTimeouts(45000,250); Check(h.Start(self,{L"--child",L"hangshutdown"},1000),"hung-shutdown child Ready");
        h.Shutdown(); Check(WaitForSingleObject(sentinel.Get(),0)==WAIT_TIMEOUT,"shutdown timeout leaves sentinel process untouched");
        SetEvent(event.Get()); Check(WaitForSingleObject(sentinel.Get(),2000)==WAIT_OBJECT_0,"sentinel exits only after explicit test event");
    }
}
}

int wmain(int argc, wchar_t** argv)
{
    std::cout.setf(std::ios::unitbuf);
    std::cerr.setf(std::ios::unitbuf);
    if (argc >= 3 && std::wstring(argv[1]) == L"--child")
    {
        std::string mode; for (wchar_t c : std::wstring(argv[2])) mode.push_back(static_cast<char>(c));
        std::string extra; if (argc >= 4) for (wchar_t c : std::wstring(argv[3])) extra.push_back(static_cast<char>(c));
        return ChildMain(mode,extra);
    }
    std::cout << "TAP version 13\n";
    Check(ExternalLLMBridgeService::ReadyTimeoutMs==35000,"CORE_READY_TIMEOUT_MS pin");
    Check(ExternalLLMBridgeService::StatusPollIntervalMs==100,"CORE_STATUS_POLL_INTERVAL_MS pin");
    Check(ExternalLLMBridgeService::ShutdownOverallTimeoutMs==40000,"CORE_SHUTDOWN_OVERALL_TIMEOUT_MS pin");
    Check(ExternalLLMBridgeService::StderrDiagnosticCapBytes==65536,"CORE_STDERR_DIAGNOSTIC_CAP_BYTES pin");
    Check(ExternalLLMBridgeService::StdoutNdjsonLineCapBytes==16384,"CORE_STDOUT_NDJSON_LINE_CAP_BYTES pin");
    TestWireMatrix();
    TestProcessScenarios();
    std::cout << "1.." << tests << "\n";
    std::cout << "# failures=" << failures << "\n";
    return failures ? 1 : 0;
}
