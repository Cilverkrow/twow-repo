# CI cache retention

This policy keeps the expensive compiler cache useful without treating every
cache-shaped object as equally valuable. The repository-wide GitHub Actions
cache budget is shared across refs and cache families, so retention must be
based on reuse scope and measured benefit.

Baseline platform run 356 restored about 3.8 GB of compiler cache but recorded
only 144 hits from 1,553 cacheable calls (9.27%), 90.73% misses, 99.84% use of
the 4 GB ccache limit, and 239 cleanups. At inspection time the repository used
about 9.8 GB of its 10 GB Actions-cache budget across 91 entries. These figures
justify measurement and scoped retention, not immediate deletion or resizing.

## Compiler caches

- Keep one healthy `ci-trixie-gcc-*` cache written by `main`. Pull requests can
  restore it, but must not publish private per-PR copies.
- Keep compiler caches only after successful builds. Never replace the last
  healthy cache with output from a failed or cancelled build.
- Retain separate nightly compiler scopes only when they represent a genuinely
  different compiler or feature matrix. Do not mix GCC, Clang, and MSVC keys.
- Do not increase the current ccache size limit until the summary shows whether
  eviction cleanups or key instability, rather than capacity, causes misses.

## Nightly and release caches

- Nightly caches are diagnostic backstops. Keep the newest successful cache per
  compiler/configuration scope and expire older duplicates.
- Release artifacts are not compiler caches. Preserve them through the release
  retention policy and immutable release identity, never through a rolling
  Actions cache key.
- A cache deletion must name its exact key and retain at least one verified
  fallback. Repository-wide or prefix-wide blind deletion is not acceptable.

## BuildKit caches

- Keep BuildKit cache scopes separate from ccache. BuildKit should cover stable
  image layers; ccache should cover compilation.
- Avoid exporting the staged runtime install as a rolling BuildKit cache. It is
  large, revision-specific, and competes with the reusable compiler cache.
- Inventory BuildKit keys, sizes, last-access times, and producing workflows
  before changing retention. Remove only superseded, explicitly identified
  scopes after confirming that no active release or smoke workflow consumes
  them.

## Review cadence

Use the CI summary to compare against platform run 356: 59m24s compile/link,
9.27% compiler-cache hits, and 17m10s compose startup/smoke. Revisit retention
after several comparable `main` and pull-request runs; one run is not enough to
justify cache deletion or a larger cache limit.
