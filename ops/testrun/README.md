# ops/testrun – one config truth per run (R07a)

Harness for test arms and live starts (OB-00 order 18.10.2026, project review R07a;
ADR-0038 render + hash). Every run starts from a config folder that was rendered and
hashed **before** the start; the hash (RUNCFG) is in every measurement line.

| File | Purpose |
|---|---|
| `run-config.sh` | `render` (base + overlays → run folder, RUNCFG, keys.tsv; unknown/duplicate keys fail), `diff` (every deviation declared or UNDECLARED, exit 3), `verify` (container mounts read-only and byte-identical, base not mounted, exit 4), `override` (compose override that mounts the run folder `:ro` instead of the base), `hash` |
| `arm-lib.sh` | shim for slot jobs: `rt_arm_begin`, `setb`/`setk` (write the arm overlay, not runtime-config), `rt_arm_up`, `rt_arm_check` |
| `meas.sh` | `meas_start`/`meas_end`: `MEAS start/end slot= arm= class= reset= roster= img= cfg= …`, isolation from DISKLOAD lines and host PSI, `valid=` |
| `report.sh` | per slot and ISO week: planned / measured / valid minutes; A1–A4 acceptance counts |
| `tickmed.sh` | median [min-max] of the core `Tick stats` minute lines over a window (last N lines, default 10) — PATH-02 tail metrics |
| `routetime.awk` | `[RouteTime]` window summary (n, sum, median, min, max per field incl. dispatch reasons and level bands lv0–lv40, `[RoutePrecheck]`, `[WorldBots]`); `-v row=1` = one `PATHROW` line for a run report |

Layers of a test arm: **reference** (planned live = deploy base + live switch list) →
**environment overlay** of the track (DB connections, realm id, roster files; declared,
versioned) → **arm overlay** (what the arm tests). Everything else that differs from the
reference is an undeclared deviation and blocks the start.

Secrets: values of `*Database*Info`, password/token/key settings and any
connection-string-shaped value are never printed (`<secret>`), neither in keys.tsv nor in
diff output.

Contract: `test/contract/testrun-harness.contract.sh` (CI step "test-run harness contract"); the two PATH-02 tools: `test/contract/testrun-tools.contract.sh` (same step, mawk and gawk).
