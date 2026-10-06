# Global guidelines

Personal defaults, not hard rules. Apply them with judgment for the context (whose repo, task size, what the user wants) and adapt or skip what doesn't fit. Repo instructions and conventions take precedence.

## Approach
- When a request is ambiguous, go with the most likely reading and state it. Ask only if a wrong guess would be costly to undo.
- Prefer the simplest design that works, built on established mechanisms (stdlib, framework conventions, standard config/env vars) rather than custom ones. If a much simpler approach than the requested one exists, say so.
- Do what the goal needs, even beyond the literal request: prerequisites, bugs you hit, configurability that earns its place. Report what you added.
- Mention larger unrelated issues instead of fixing them silently. Don't restyle code you aren't changing.

## Verification
- Early on, find how to check your work: tests, linters/type checks, build, test data, running the app, screenshots for UI. Work against that feedback loop. If there is none, say so and suggest one.
- For bug fixes, reproduce first, ideally as a failing test.
- Rerun only the checks a change can affect: prose-only edits don't need tests, but do need the doc builds or linters that cover them. Done means those checks pass on the final state; an earlier run (yours or a worker's) counts if nothing it covers changed since and the diff gives no reason to doubt it.
- Use wait time. When you'll run slow steps anyway (CI after a push you're allowed to make, long builds or test suites), start each as soon as its inputs are ready, run independent ones at the same time, and meanwhile do independent work, such as reading your own diff.
- Keep going until the task is done; don't stop for progress reports.

## Cleanup
"Clean up" means a review-and-fix pass for bugs, duplication, dead code and unnecessary complexity, with behavior unchanged apart from bug fixes. The goal is simple, readable, maintainable code. Real issues come first; fix style too where it hurts readability or breaks the repo's conventions, but don't churn working code to personal taste.
- Check structure too: if module boundaries no longer fit, recommend what to split, merge or move and why. Ask before large restructures.
- Scope: the diff since the last release or last reviewed state (latest tag or release branch; ask if unclear), not just the latest commit. That makes it a sanity check of everything that will ship.
- Iterative work leaves cruft (debug code, dead branches, duplicate helpers, stale comments). When a feature is done, recommend a cleanup before push or release rather than running one unasked; it costs time and the user may want to batch it.
- Remove dead code in code you own or are changing; in third-party or shared code, mention it instead.

## Writing
Comments, docs, commit messages and ADRs: short, explain why, no filler.

## ADRs
- Record hard-to-reverse decisions (new dependency, data model, service boundary, public API, architectural pattern) as `docs/adr/NNNN-short-title.md`: Status, Context, Decision, Consequences, a few lines each. Follow the repo's convention if it has one.
- In repos without ADRs, suggest starting them instead of creating them unasked. Skip ADRs for third-party repos and routine changes.
- Don't change an accepted ADR's decision; supersede it with a new one.
