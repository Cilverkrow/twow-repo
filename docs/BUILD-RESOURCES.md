# Windows build resources outside Git

This repository intentionally contains source and reproducible text metadata, but not compiled dependencies or binary resource assets. A successful Windows build therefore requires explicitly provisioned external inputs. Their presence is a build prerequisite, never permission to copy them into Git or deploy the result.

## Pinned `mangosd.ico` input

The unchanged resource script `src/mangosd/mangosd.rc` references `mangosd.ico`. For the verified 2026-08-31 Release build, the external input had this identity:

| Property | Value |
|---|---|
| Expected relative destination during build | `src/mangosd/mangosd.ico` |
| Bytes | `16958` |
| SHA-256 | `0BF6E8E0DAB99D6E47E3DC3FFCB02820414CBA97BCF97A79BFF4C2AE59896D4A` |
| Historical Git blob identity | `06327ff7c112754762c91a02ac1d26b5d76e20eb` |
| Repository policy | external prerequisite; do not track |

Materialize this file only in the isolated build worktree, verify its byte count and SHA-256 before use, and remove it after the build. Do not weaken or bypass the resource script to make a filtered checkout appear self-contained.

## Compiled Windows dependency input

The Windows linker also requires the externally provisioned `dep/windows/lib` hierarchy, including the appropriate architecture/configuration directory such as `x64_release`. These libraries are compiled artifacts and stay outside Git.

For the verified build, an exact temporary directory junction exposed the external dependency hierarchy at `dep/windows/lib` inside the isolated worktree. Before building, verify that the destination does not exist, that the link target is the intended external dependency root, and that required inputs such as `x64_release/libmySQL.lib` are present. Remove only the verified junction after the build; never recursively delete through it.

A future stable build-provenance task must create a reviewed manifest for every dependency actually consumed by the linker. The successful build recorded here proves the current source can build with the available external set; it is not yet a portable dependency lockfile.

## Verified toolchain profile

The successful clean Release build used:

- Visual Studio 2022 Build Tools;
- MSVC `19.44.35228` / linker `14.44`;
- CMake `4.4.2`;
- Windows SDK `10.0.26100.0`;
- a sanitized child environment containing only one case-insensitive `Path` key;
- an isolated build directory and serial MSBuild target `Release/mangosd`.

On Windows, inheriting both `Path` and `PATH` can cause opaque MSBuild failures. Build launchers must de-duplicate environment keys case-insensitively rather than relying on caller state.

## Boundary and cleanup contract

- Never stage `.ico`, `.lib`, `.dll`, `.exe`, `.pdb`, build logs, binlogs, or generated build trees.
- Keep candidate EXE/PDB files local and identify them by byte count and SHA-256 in text evidence.
- Remove temporary resource copies and dependency junctions after the build.
- A successful build is not deployment authorization.
- See [ADR-0019](adr/ADR-0019-external-windows-build-inputs.md), [External requirements](EXTERNAL-REQUIREMENTS.md), and [Footguns](FOOTGUNS.md).
