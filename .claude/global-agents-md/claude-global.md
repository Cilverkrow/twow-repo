@AGENTS.md

# Models and delegation
Default setup for cost and quality: Opus plans, decides, reviews and coordinates; Sonnet implements; the advisor (Fable) helps with hard calls.

## When delegating (main session or an agent coordinating a large task)
- Plan yourself and consult the advisor on hard-to-reverse choices. For large work with truly different possible approaches, you may spawn fresh planning agents (`model: opus`), in parallel if useful. Built-in Plan agents don't see this file, so put requirements and constraints in the brief. Split into parts only where they can run in parallel or must wait on a slow step (CI, long builds), and let the plan's order show which; otherwise keep one coherent chunk.
- Implementation defaults to `model: sonnet`: much cheaper, and strong once the decisions are made. Interdependence or judgment calls aren't reasons to keep coding yourself: make the decisions, then give one Sonnet worker the whole coherent chunk. Implement yourself only when it takes a handful of tool calls and won't pull in bulky content you don't need yourself (other repos' docs, logs, large outputs), or while exploring (e.g. debugging an unknown cause); once the cause or design is clear, hand off the rest.
- Make passing tests/lint part of the worker's done criteria. Send CI failures or review findings back to the same worker; fix them yourself only if it's a few lines.
- Large tasks that need investigation or coordination of their own → `model: opus`.
- Forks inherit the whole conversation and your model, so don't fork implementation. Fork only for small side tasks that need this conversation's context, while it's still short. Otherwise spawn fresh with a self-contained brief: goal, decisions made, files and interfaces, constraints, relevant ADRs, done criteria, and commit/push permission only if the user asked and the worker has its own worktree or repo.
- Run substantial independent parts (e.g. the same change across several repos) as parallel workers when they share no files or state (lockfile/installs, build output, ports, databases, git index). Worktrees separate files and the index, not ports, databases or shared caches. Otherwise run them in sequence.
- A task arriving mid-work means re-plan, not extend your flow: give each substantial independent task its own worker, the current one too if it's substantial and not mostly done. When handing off a started task, state its branch and uncommitted changes in the brief, and stop touching that checkout.
- Review worker diffs yourself; don't spawn agents to re-verify routine work.
- At milestones (a plan for large or hard-to-reverse work, cleanup after a batch of features or before a release), consider an adversarial review: a fresh subagent that sees only the plan or diff plus the requirements, Opus for plans and Sonnet for diffs. Ask it for bugs, requirement gaps and structural problems. Reviewers always find something, so fix what's real and drop nitpicks.

## When working for another agent
- Your brief is your job: deliver and verify it, including tests and fixing failures, but don't commit or push unless your brief says to. An Opus worker coordinating a large brief follows the delegation rules above.
- Use the advisor when stuck.
- If your task splits into substantial, independent parts, delegate them (brief and parallelism rules above). Nest as deep as the task's structure warrants, as long as each level owns a coherent part rather than just passing work along.
- Keep fixes beyond your brief within your assigned files and shared state; report the rest.
- Settle minor ambiguities yourself and list them. Return early only when a choice would change the design.
- Your parent sees only your final message: report what you did, what you decided and what's open, concisely.
