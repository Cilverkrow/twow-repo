#!/usr/bin/env bash
# Compare every GitHub issue against the manifest entry it came from.
#
# The importer creates issues and, with --update, rewrites them. Nothing
# otherwise checks that what is on GitHub still matches what is in
# docs/issues/. Two silent corruptions were found by running this once:
#
#   * A manifest entry missing its closing `---` merged two entries into one.
#     The awk parser overwrites the id on the second `id:` line while still
#     accumulating the body, so it emitted a single record carrying both bodies
#     and dropped the first entry entirely. ARCH-003 vanished from the tracker
#     that way. The importer now refuses such a manifest; this catches the
#     result if one ever slips through another route.
#   * The importer shell-escaped apostrophes for single-quote embedding and then
#     passed the body in double quotes, so the escape landed in the text. 32 of
#     117 issues rendered every apostrophe as a four-character mess.
#
# Usage: bash ops/audit/issue-tracker-drift.sh [--repo owner/name]

set -euo pipefail
REPO="${2:-Cilverkrow/twow-repo}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

gh issue list --repo "$REPO" --state all --limit 300 --json number,title,body,state > "$TMP/issues.json"

python3 - "$ROOT" "$TMP/issues.json" <<'PY'
import io, json, glob, re, sys, os
root, issues_path = sys.argv[1], sys.argv[2]

man = {}
for f in sorted(glob.glob(os.path.join(root, 'docs/issues/*.md'))):
    cur = None; inbody = False; body = []
    def flush():
        if cur and cur[0]:
            man[cur[0]] = (cur[1], "".join(body), os.path.basename(f))
    for line in io.open(f, encoding='utf-8').read().split('\n'):
        if line == '---':
            flush(); cur = None; inbody = False; body = []; continue
        if line.startswith('id: '):
            cur = [line[4:].strip(), None]; inbody = False; body = []; continue
        if line.startswith('title: ') and cur:
            cur[1] = line[7:].strip(); continue
        if line == 'body: |':
            inbody = True; continue
        if inbody:
            body.append((line[2:] if line.startswith('  ') else line) + "\n")
    flush()

issues = json.load(open(issues_path, encoding='utf-8'))
by_id = {}
for it in issues:
    m = re.match(r'^([A-Z]+\d*-\d+):', it['title'] or '')
    if m:
        by_id.setdefault(m.group(1), []).append(it)

MANGLED = "'" + "\\" + "'" + "'"
problems = 0

def report(kind, detail):
    global problems
    problems += 1
    print("  %-18s %s" % (kind, detail))

print("manifest entries: %d | issues with an id: %d" % (len(man), sum(len(v) for v in by_id.values())))
print()
for mid, (mtitle, mbody, src) in sorted(man.items()):
    got = by_id.get(mid)
    if not got:
        report("NOT FILED", "%s (%s)" % (mid, src)); continue
    open_ones = [g for g in got if g['state'] == 'OPEN']
    it = (open_ones or sorted(got, key=lambda x: x['number']))[0]
    if len(open_ones) > 1:
        report("DUPLICATE OPEN", "%s -> #%s" % (mid, ", #".join(str(g['number']) for g in open_ones)))
    ght = (it['title'] or '').split(': ', 1)[1] if ': ' in (it['title'] or '') else ''
    if ght.strip() != (mtitle or '').strip():
        report("TITLE DRIFT", "%s #%d" % (mid, it['number']))
    if it['body'] and MANGLED in it['body']:
        report("MANGLED QUOTES", "%s #%d" % (mid, it['number']))

print()
if problems:
    print("%d problem(s). Re-sync with: bash ops/issues/import-issues.sh --apply --update --only <ID>" % problems)
    sys.exit(1)
print("tracker matches the manifests")
PY
