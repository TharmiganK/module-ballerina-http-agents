#!/usr/bin/env python3
"""Writes the defect scanner's run report and updates the coverage state in a checkout of the agent-state branch.
A unit is only marked as analysed when its agent job completed and this was not a dry run. Security findings appear
only as counts.

Usage: scanner-state.py <state-dir>
Find-similar runs (SEED set) write their report under a seed-specific name and never advance the rotation.

Env: SCANNER (defect or gap; gap uses the gap-scanner state directory and has no security section), UNITS (JSON array of planned units), SEED, SHA, RUN_URL, RUN_NUMBER, DRY_RUN, SEC_FOUND, SEC_DELIVERED, OUTPUTS_DIR,
REPORT_DIR. Reads <OUTPUTS_DIR>/<artifact>/{meta.json,scope.json,result.json,usage.json,completed} per unit and
<REPORT_DIR>/publish-report.json.
"""
import datetime
import json
import os
import sys
from pathlib import Path

GAP = os.environ.get("SCANNER", "defect") == "gap"
STATE_DIR = Path(sys.argv[1]) / ("gap-scanner" if GAP else "defect-scanner")
OUTPUTS = Path(os.environ.get("OUTPUTS_DIR", "outputs"))
REPORT_DIR = Path(os.environ.get("REPORT_DIR", "publish"))
env = os.environ



def unit_dirs(root):
    """One directory per unit. download-artifact extracts a single matching artifact into root itself."""
    if (root / "meta.json").exists():
        return [root]
    return sorted(p for p in root.iterdir() if p.is_dir()) if root.exists() else []

def load(path, default):
    try:
        text = path.read_text() if path.exists() else ""
        return json.loads(text) if text.strip() else default
    except json.JSONDecodeError:
        return default


def unit_outputs():
    by_unit = {}
    for unit_dir in unit_dirs(OUTPUTS):
        meta = load(unit_dir / "meta.json", None)
        if meta:
            by_unit[meta["unit"]] = unit_dir
    return by_unit


def coverage_text(result):
    coverage = result.get("coverage") or "_No coverage summary (the agent did not finish)._"
    if "\n" not in coverage and "\\n" in coverage:
        # The agent sometimes double-escapes newlines in the structured output.
        coverage = coverage.replace("\\n", "\n")
    return coverage


def main():
    now = datetime.datetime.now(datetime.timezone.utc)
    dry_run = env.get("DRY_RUN") == "true"
    planned = json.loads(env.get("UNITS") or "[]")
    outputs = unit_outputs()
    publish = load(REPORT_DIR / "publish-report.json", {"filed": [], "would_file": [], "dropped": []})

    completed = [u for u in planned if u in outputs and (outputs[u] / "completed").exists()]
    lines = [
        (f"# Find-similar run {env['RUN_NUMBER']} for {env['SEED']}" if env.get("SEED")
         else f"# {'Gap' if GAP else 'Defect'} scanner run {env['RUN_NUMBER']}") + (" (dry run)" if dry_run else ""), "",
        f"- **Date:** {now:%Y-%m-%d %H:%M} UTC",
        f"- **Commit:** `{env['SHA'][:12]}`",
        f"- **Units:** {', '.join(f'`{u}`' for u in planned)} ({len(completed)} completed)",
        f"- **Run:** {env['RUN_URL']}",
        "", "## Issues",
    ]
    for item in publish.get("filed", []):
        lines.append(f"- Filed ({item['unit']}, {item['category']}): [{item['title']}]({item['url']})")
    for item in publish.get("would_file", []):
        lines.append(f"- Would file ({item['unit']}, {item['category']}): {item['title']}")
    if not publish.get("filed") and not publish.get("would_file"):
        lines.append("- None")
    if publish.get("dropped"):
        lines += ["", "## Dropped findings"]
        lines += [f"- ({d.get('unit', '?')}) {d['title']} — {d['reason']}" for d in publish["dropped"]]
    if not GAP:
        lines += ["", "## Security",
                  f"- {env.get('SEC_FOUND') or 0} found, {env.get('SEC_DELIVERED') or 0} delivered privately"]

    for unit in planned:
        unit_dir = outputs.get(unit)
        scope = load(unit_dir / "scope.json", {}) if unit_dir else {}
        result = load(unit_dir / "result.json", {}) if unit_dir else {}
        usage = load(unit_dir / "usage.json", {}) if unit_dir else {}
        status = "completed" if unit in completed else ("failed" if unit_dir else "no output")
        lines += ["", f"## Unit `{unit}`", "",
                  f"- **Status:** {status}",
                  f"- **Selected because:** {scope.get('selection_reason', 'unknown')}"]
        if usage:
            lines.append(f"- **Claude:** {usage.get('num_turns', '?')} turns, "
                         f"{round((usage.get('duration_ms') or 0) / 60000, 1)} min")
        lines += ["", "### Coverage", "", coverage_text(result)]
    report = "\n".join(lines) + "\n"

    week = now.isocalendar()
    seed = env.get("SEED", "").replace(":", "-")
    name = f"{week.year}-W{week.week:02d}-" + (f"similar-{seed}-" if seed else "") + f"run{env['RUN_NUMBER']}.md"
    report_path = STATE_DIR / "reports" / name
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report)

    state_file = STATE_DIR / "state.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {"units": {}, "runs": []}
    if not dry_run and not env.get("SEED"):
        for unit in completed:
            state["units"][unit] = {"last_analysed": now.isoformat(), "sha": env["SHA"], "run_url": env["RUN_URL"]}
    state["runs"] = (state.get("runs", []) + [{
        "date": now.isoformat(), "units": planned, "completed": completed, "sha": env["SHA"], "dry_run": dry_run,
        "filed": len(publish.get("filed", [])), "dropped": len(publish.get("dropped", [])),
        "report": str(report_path.relative_to(STATE_DIR)), "run_url": env["RUN_URL"]}])[-100:]
    state_file.write_text(json.dumps(state, indent=2) + "\n")

    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(report)
    print(report)


if __name__ == "__main__":
    main()
