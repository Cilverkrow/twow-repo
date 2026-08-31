# Handoff: Repository Resource-Provenance Gate

Do not change the 28 integrated roster paths, commit, deploy, or enter Phase C under this handoff.

The sole remaining blocker is a target-repository baseline defect: `src/mangosd/mangosd.rc` requires `mangosd.ico`, but current `main` does not track the file and `.gitignore` excludes it. A clean worktree therefore cannot link the Windows resource.

A successor task must first decide, with explicit binary/provenance authorization, one of the following:

1. Add the verified asset as a tracked repository baseline file, proving its exact source and review status; or
2. Define an approved, immutable external build prerequisite and make the clean-build contract explicitly depend on it.

After that decision, run a fresh build directory with the same sanitized one-case PATH, VsDevCmd, ACE_ROOT, BOOST_ROOT and local Git configuration. Re-run final static scope checks. Create the local feature commit only if Release/mangosd then succeeds and its EXE/PDB hashes are captured.
