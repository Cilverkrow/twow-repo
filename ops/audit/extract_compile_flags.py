"""Print the compiler and flags used for one src/game translation unit.

Reads compile_commands.json and strips the parts that name the input file and
the output object, so the result can be reused to compile a probe file with the
exact include path and macro set the real build uses. Anything less and the
audit tests a configuration nobody ships.
"""

import json
import shlex
import sys


def main(path: str) -> int:
    for entry in json.load(open(path, encoding="utf-8")):
        source = entry["file"].replace("\\", "/")
        if "/src/game/" not in source or not source.endswith((".cpp", ".cc")):
            continue

        argv = entry.get("arguments") or shlex.split(entry["command"])
        rest = argv[1:]
        kept, skip_next = [], False
        for i, arg in enumerate(rest):
            if skip_next:
                skip_next = False
                continue
            if arg == "-o":
                skip_next = True
                continue
            if arg == "-c" or arg.endswith((".cpp", ".cc", ".o", ".obj")):
                continue
            # A precompiled header is built for one specific source, so reusing
            # it for a probe file is rejected and is not what we are testing.
            #
            # It has to go as a PAIR. Dropping only the path leaves a bare
            # "-include", which then consumes whatever comes next -- the audit's
            # first run reported all 216 headers as broken with "fatal error:
            # -fsyntax-only: No such file or directory", because -include had
            # eaten the flag rather than a filename.
            if arg == "-include" and i + 1 < len(rest) and "cmake_pch" in rest[i + 1]:
                skip_next = True
                continue
            if "cmake_pch" in arg:
                continue
            kept.append(arg)

        print(shlex.quote(argv[0]), " ".join(shlex.quote(a) for a in kept))
        return 0

    print("no src/game entry in compile_commands.json", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
