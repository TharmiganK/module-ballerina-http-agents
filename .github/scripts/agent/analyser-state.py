#!/usr/bin/env python3
"""Writes the weekly analyser's run report and updates the coverage state in a checkout of the agent-state branch.
The unit is only marked as analysed when the agent job succeeded and this was not a dry run. Security findings appear
only as counts.

Usage: analyser-state.py <state-dir>
Env: UNIT, SHA, RUN_URL, RUN_NUMBER, AGENT_RESULT, DRY_RUN, SEC_FOUND, SEC_DELIVERED, SELECTION_REASON.
Reads agent-output/{result.json,publish-report.json,usage.json} when present.
"""
import datetime
import json
import os
import sys
from pathlib import Path

STATE_DIR = Path(sys.argv[1]) / "analyser"
OUT = Path("agent-output")
env = os.environ


def load(name, default):
    path = OUT / name
    try:
        return json.loads(path.read_text()) if path.exists() and path.read_text().strip() else default
    except json.JSONDecodeError:
        return default


def main():
    now = datetime.datetime.now(datetime.timezone.utc)
    dry_run = env.get("DRY_RUN") == "true"
    succeeded = env.get("AGENT_RESULT") == "success"
    result = load("result.json", {})
    publish = load("publish-report.json", {"filed": [], "would_file": [], "dropped": []})
    usage = load("usage.json", {})

    lines = [
        f"# Weekly analyser: `{env['UNIT']}`" + (" (dry run)" if dry_run else ""), "",
        f"- **Date:** {now:%Y-%m-%d %H:%M} UTC",
        f"- **Commit:** `{env['SHA'][:12]}`",
        f"- **Selected because:** {env.get('SELECTION_REASON', '')}",
        f"- **Agent job:** {env.get('AGENT_RESULT', 'unknown')}",
        f"- **Run:** {env['RUN_URL']}",
    ]
    if usage:
        lines.append(f"- **Claude:** {usage.get('num_turns', '?')} turns, "
                     f"{round((usage.get('duration_ms') or 0) / 60000, 1)} min")
    lines += ["", "## Issues"]
    filed = publish.get("filed", []) + publish.get("would_file", [])
    if filed:
        for item in publish.get("filed", []):
            lines.append(f"- Filed ({item['category']}): [{item['title']}]({item['url']})")
        for item in publish.get("would_file", []):
            lines.append(f"- Would file ({item['category']}): {item['title']}")
    else:
        lines.append("- None")
    if publish.get("dropped"):
        lines += ["", "## Dropped findings"]
        lines += [f"- {d['title']} — {d['reason']}" for d in publish["dropped"]]
    lines += ["", "## Security", f"- {env.get('SEC_FOUND') or 0} found, {env.get('SEC_DELIVERED') or 0} delivered privately"]
    lines += ["", "## Coverage", "", result.get("coverage") or "_No coverage summary (the agent did not finish)._"]
    report = "\n".join(lines) + "\n"

    week = now.isocalendar()
    report_path = STATE_DIR / "reports" / f"{week.year}-W{week.week:02d}-{env['UNIT']}-run{env['RUN_NUMBER']}.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report)

    state_file = STATE_DIR / "state.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {"units": {}, "runs": []}
    if succeeded and not dry_run:
        state["units"][env["UNIT"]] = {"last_analysed": now.isoformat(), "sha": env["SHA"], "run_url": env["RUN_URL"]}
    state["runs"] = (state.get("runs", []) + [{
        "date": now.isoformat(), "unit": env["UNIT"], "sha": env["SHA"], "dry_run": dry_run,
        "agent_result": env.get("AGENT_RESULT"), "filed": len(publish.get("filed", [])),
        "dropped": len(publish.get("dropped", [])), "report": str(report_path.relative_to(STATE_DIR)),
        "run_url": env["RUN_URL"]}])[-100:]
    state_file.write_text(json.dumps(state, indent=2) + "\n")

    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(report)
    print(report)


if __name__ == "__main__":
    main()
