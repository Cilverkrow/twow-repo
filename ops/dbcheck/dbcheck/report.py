"""Deterministic report: same database + same inputs -> same bytes -> same hash."""

from __future__ import annotations

import hashlib
import json

from . import __version__
from .engine import Run
from .expected import Expected

_SEV_ORDER = {"error": 0, "warn": 1, "info": 2}


def _cell(v) -> str:
    return "" if v is None else str(v).replace("|", "\\|").replace("\n", " ")


def build(run: Run, expected: list[Expected], max_rows: int = 50) -> tuple[str, dict]:
    """Return (markdown, json-able summary). No timestamps: the hash must be stable."""
    counts = {"error": 0, "warn": 0, "info": 0}
    for r in run.results:
        if r.rows:
            counts[r.rule.severity] += len(r.rows)
    lines = [
        "# dbcheck report",
        "",
        f"- tool: dbcheck {__version__}",
        f"- binding: {run.binding.id} (sha256 {run.binding.sha256[:16]})",
        f"- schema fingerprint: {run.fingerprint[:16]}",
    ]
    for e in expected:
        lines.append(f"- expected: {e.id} (sha256 {e.sha256[:16]}; source {e.source}, {e.source_date})")
    lines += [
        f"- findings: {counts['error']} error, {counts['warn']} warn, {counts['info']} info",
        "",
    ]
    ordered = sorted(
        (r for r in run.results if r.rows),
        key=lambda r: (_SEV_ORDER[r.rule.severity], r.rule.name, r.subject),
    )
    for r in ordered:
        head = f"## [{r.rule.severity}] {r.rule.name}: {r.rule.title}"
        lines.append(head)
        if r.subject:
            lines.append(f"Subject: {r.subject}")
        if r.rule.description:
            lines.append(f"{r.rule.description}")
        lines.append("")
        lines.append("| " + " | ".join(r.columns) + " |")
        lines.append("|" + "---|" * len(r.columns))
        for row in r.rows[:max_rows]:
            lines.append("| " + " | ".join(_cell(v) for v in row) + " |")
        if len(r.rows) > max_rows:
            lines.append(f"\n... {len(r.rows) - max_rows} more rows (total {len(r.rows)}); see the JSON report.")
        lines.append("")
    passed = sorted({(r.rule.name, r.subject) for r in run.results if not r.rows and not r.skipped})
    skipped = sorted({(r.rule.name, r.subject, r.skipped) for r in run.results if r.skipped})
    lines.append("## Passed")
    lines.append("")
    lines.append(f"{len(passed)} rule checks returned no rows.")
    if skipped:
        lines += ["", "## Skipped", ""]
        lines += [f"- {n}{': ' + s if s else ''} ({why})" for n, s, why in skipped]
    text = "\n".join(lines) + "\n"
    data = {
        "tool": f"dbcheck {__version__}",
        "binding": {"id": run.binding.id, "sha256": run.binding.sha256},
        "schema_fingerprint": run.fingerprint,
        "expected": [{"id": e.id, "sha256": e.sha256, "source": e.source, "source_date": e.source_date} for e in expected],
        "counts": counts,
        "findings": [
            {
                "rule": r.rule.name,
                "severity": r.rule.severity,
                "subject": r.subject,
                "columns": r.columns,
                "rows": [list(row) for row in r.rows],
            }
            for r in ordered
        ],
    }
    return text, data


def sha256_of(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def dump_json(data: dict) -> str:
    return json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
