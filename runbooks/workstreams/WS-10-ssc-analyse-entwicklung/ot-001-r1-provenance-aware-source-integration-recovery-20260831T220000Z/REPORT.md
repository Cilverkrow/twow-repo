# OT-001-R1 Recovery Build Report

This package records the clean-build recovery attempt for the already integrated OT-001-R1 worktree. It does not modify the earlier OT-001-R1 evidence package.

## Immutable integration reference

- Worktree: `C:\TW\worktrees\ot-001-r1-persistent-roster`
- Branch: `work/ot-001-r1-persistent-roster-integration`
- Parent commit: `f1f2e01026e54cd5c119c1e8e95fc107a01f4e2b`
- Parent tree: `8e0ef387913e67dfd44577cf58e6bc7d830f49dd`
- Integration scope: the same 28 validated paths documented by the prior target and integration matrices.

## Recovery build result

The serial Visual Studio 2022 Release/mangosd build configured successfully with MSVC 19.44.35228, Windows SDK 10.0.26100.0, ACE and Boost 1.92. The local Git executable was included in the build-only process environment, so CMake reported core revision `f1f2e01026e54cd5c119`.

Compilation completed for the integrated `playerbots` library. The final `mangosd` resource compilation failed with `RC2135: file not found: mangosd.ico`.

This is not caused by the 28-path roster integration: `src/mangosd/mangosd.rc` is an unchanged target file and contains `IDI_APPICON ICON DISCARDABLE "mangosd.ico"`. The target repository tree has no `src/mangosd/mangosd.ico` entry, the worktree contains no such file, and its `.gitignore` ignores `*.ico`. The verified baseline Git object does contain the asset as blob `06327ff7c112754762c91a02ac1d26b5d76e20eb` (16,958 bytes), but importing or committing that binary is forbidden by this task.

No workaround was applied. In particular, no icon, resource wrapper, source workaround, candidate executable or PDB was created.

## Gates retained from the prior package

The prior immutable package recorded two PASS fake-unit runs, two PASS real C++/isolated-MariaDB adapter runs, and PASS static scope, secret, binary and diff-check gates. This recovery made no change to the source diff; its current scope remains exactly those 28 expected paths. It also re-ran `git diff --check`, a scoped added-line secret scan and an untracked-file secret scan; all passed. The source matrices are referenced below by path and SHA-256 rather than copied.

## Production boundary

The recovery did not access a production database or port 3307, control a server process, start a candidate, change active configuration, install artifacts, deploy, or resume LLM work. Production EXE and configuration hashes remain the expected values.

## Conclusion

The source integration is auditable and unchanged, but the required clean Release/mangosd build cannot pass within the authorized 28-path/non-binary scope. The appropriate next task is a separate repository-baseline resource-provenance decision: either restore a verified, tracked icon through an explicitly authorized repository change, or formally define and approve a reproducible non-repository resource prerequisite. Until then, no local feature commit is created.
