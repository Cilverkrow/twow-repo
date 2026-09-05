# llm-bridge

Promoted out of `runbooks/`, where it was the **only** copy. Not wired into anything yet, and
deliberately so — see "Before integrating" below.

Two halves of one contract:

| | |
|---|---|
| `bridge/` | The Node runtime. Reads NDJSON requests on stdin, talks to a local Ollama, writes NDJSON responses on stdout. 683 automated cases, passed twice. |
| `client-cpp/` | `ExternalLLMBridgeService`, the server-side client. Spawns `bridge/` as a child process and speaks that NDJSON over pipes. |

Neither does anything alone.

## Why it was in `runbooks/`

It was developed as an evidence-packaged deliverable rather than a merged branch, so the only
copy lived under `runbooks/ssc-llm-production-bridge-01-phase-b-r1-.../source-copies/` and
`runbooks/ssc-llm-bridge-v1-english-correction-.../bridge/`. `docs/FOOTGUNS.md` FG-008 and
FG-054 both record that as a hazard, and `docs/issues/00-refactor-plan.md:496` lists promoting
it as intended work. A pass over `runbooks/` nearly deleted it: `ExternalLLMBridgeService`
existed in **zero** places outside that tree.

## Layout is load-bearing

`bridge/src/cli.mjs` is fixed. LLM-002 records that the package resolves its CLI at
`PackageRoot/bridge/src/cli.mjs` with no configuration option to move it, so the `bridge/`
level is kept rather than flattened into `services/llm-bridge/src/`.

## Before integrating — read this first

**`client-cpp/` is not dropped back into `modules/mod-playerbots/`, and should not be.**

As written it modifies six files in the vendored bot tree — `PlayerbotAI.{h,cpp}`,
`PlayerbotAIConfig.{h,cpp}`, `PlayerbotScripts.cpp`, `SayAction.cpp` — for a total of **325
changed lines**. That tree is deliberately kept close to upstream; its delta is currently 29
differences, each of which has to be justifiable one line at a time. Re-adding 325 lines of
in-process LLM plumbing reverses a lot of work.

**`modules/mod-bot-brain` already solves the same shape of problem with zero bot-tree delta.**
It attaches through `RegisterAiContextAugmenter` and the `ScriptObjects.h` hooks, talks to
`services/bot-brain` out of process, and `git diff --stat modules/mod-playerbots` is empty.
That is the seam this should use.

Three things to settle before any integration:

1. **Does `services/bot-brain` supersede this?** Both put planning out of process. bot-brain is
   Go over HTTP and already attaches cleanly; this is Node over pipes with a C++ child-process
   supervisor. Issues #11, #12, #15 and #16 turn on that question, and it has not been answered.
2. **If it survives, attach through the existing seam**, not by patching upstream files.
3. **Transport.** The C++ half was written against Windows named pipes and later NDJSON over
   pipes. `docs/issues/00-refactor-plan.md:389` calls for rewriting it to a network transport
   so it works in a Linux container, keeping the fail-closed admission and the world-thread
   session re-validation the ADRs got right.

Also note `ExternalLLMBridgeService::BotGuid = 18281` is hardcoded to one test bot.

## What it is not

Not built, not referenced by any `CMakeLists.txt`, not started by anything. Moving it here
makes it findable and reviewable; it does not make it live.
