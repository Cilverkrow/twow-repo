#!/usr/bin/env python3
"""Inventory configured CTest tests and summarize their JUnit result.

The inventory is generated from CTest's JSON model, not a maintained target
list. After the normal CMake ``all`` target has built, every test command that
points into the build tree must exist and be executable. Script-driven tests
(for example ``cmake -P`` contracts) remain registered but are not counted as
executable build targets.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def emit(values: dict[str, int]) -> None:
    for key, value in values.items():
        print(f"{key}={value}")


def inventory(build_dir: Path) -> int:
    result = subprocess.run(
        ["ctest", "--test-dir", str(build_dir), "--show-only=json-v1"],
        check=True,
        capture_output=True,
        text=True,
    )
    model = json.loads(result.stdout)
    tests = model.get("tests", [])
    build_root = build_dir.resolve()
    executable_commands: set[Path] = set()
    missing: list[tuple[str, Path]] = []

    for test in tests:
        command = test.get("command") or []
        if not command:
            print(f"ERROR: registered test has no command: {test.get('name', '<unnamed>')}", file=sys.stderr)
            return 1
        candidate = Path(command[0])
        if not candidate.is_absolute():
            continue
        resolved = candidate.resolve()
        try:
            resolved.relative_to(build_root)
        except ValueError:
            continue
        executable_commands.add(resolved)
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            missing.append((test.get("name", "<unnamed>"), resolved))

    emit(
        {
            "registered": len(tests),
            "executable_targets": len(executable_commands),
            "missing_executables": len(missing),
        }
    )
    for name, path in missing:
        print(f"ERROR: test {name!r} cannot execute missing target {path}", file=sys.stderr)
    return 1 if missing or not tests else 0


def junit(path: Path) -> int:
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.findall("testsuite"))
    tests = sum(int(suite.attrib.get("tests", 0)) for suite in suites)
    failures = sum(int(suite.attrib.get("failures", 0)) for suite in suites)
    errors = sum(int(suite.attrib.get("errors", 0)) for suite in suites)
    skipped = sum(int(suite.attrib.get("skipped", suite.attrib.get("disabled", 0))) for suite in suites)
    passed = tests - failures - errors - skipped
    emit({"executed": tests, "passed": passed, "failed": failures + errors, "skipped": skipped})
    return 1 if tests == 0 or failures or errors or skipped else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("build_dir", type=Path)
    junit_parser = subparsers.add_parser("junit")
    junit_parser.add_argument("junit_file", type=Path)
    args = parser.parse_args()
    if args.command == "inventory":
        return inventory(args.build_dir)
    return junit(args.junit_file)


if __name__ == "__main__":
    raise SystemExit(main())
