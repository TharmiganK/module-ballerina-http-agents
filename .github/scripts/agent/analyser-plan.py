#!/usr/bin/env python3
"""Selects the weekly analyser's scope unit and writes its context.

Selection: a unit given in SCOPE_INPUT; otherwise units never analysed (in catalogue order); otherwise the highest
score of weeks since the last analysis plus 4 if any of the unit's files changed on master since then.

Env: REPO, GH_TOKEN, SCOPE_INPUT (optional). Expects the agent-state branch fetched as origin/agent-state if it exists.
Writes agent-context/{scope.json,known-issues.json} and the step outputs unit, prev_sha, reason.
"""
import datetime
import json
import os
import subprocess
from pathlib import Path

SCOPES = json.loads(Path(".github/agent-prompts/analyser/scopes.json").read_text())["units"]
OUT = Path("agent-context")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def load_state():
    shown = git("show", "origin/agent-state:analyser/state.json")
    return json.loads(shown.stdout) if shown.returncode == 0 else {"units": {}}


def changed_files(unit, since_sha):
    if not since_sha or git("cat-file", "-e", f"{since_sha}^{{commit}}").returncode != 0:
        return []
    diff = git("diff", "--name-only", f"{since_sha}..HEAD", "--", *unit["paths"])
    return [line for line in diff.stdout.splitlines() if line]


def select(state):
    requested = os.environ.get("SCOPE_INPUT", "").strip()
    if requested:
        matches = [u for u in SCOPES if u["id"] == requested]
        if not matches:
            raise SystemExit(f"::error::Unknown scope unit '{requested}'")
        return matches[0], "requested"
    analysed = state.get("units", {})
    for unit in SCOPES:
        if unit["id"] not in analysed:
            return unit, "never analysed"
    now = datetime.datetime.now(datetime.timezone.utc)
    best, best_score, best_reason = None, -1.0, ""
    for unit in SCOPES:
        entry = analysed[unit["id"]]
        weeks = (now - datetime.datetime.fromisoformat(entry["last_analysed"])).days / 7
        changed = bool(changed_files(unit, entry.get("sha")))
        score = weeks + (4 if changed else 0)
        if score > best_score:
            reason = f"{weeks:.1f} weeks since last analysis" + (", files changed since" if changed else "")
            best, best_score, best_reason = unit, score, reason
    return best, best_reason


def list_issues(repo, label):
    listed = subprocess.run(
        ["gh", "issue", "list", "--repo", repo, "--state", "all", "--label", label,
         "--limit", "2000", "--json", "number,title,state,labels,body,url"],
        capture_output=True, text=True, check=True)
    return json.loads(listed.stdout)


def known_issues():
    """Issues of this repository plus, for a mirror, the upstream trackers in UPSTREAM_ISSUE_REPOS
    ("owner/repo:label" entries separated by spaces)."""
    sources = [(os.environ["REPO"], "module/http"), (os.environ["REPO"], "agent/generated")]
    for entry in os.environ.get("UPSTREAM_ISSUE_REPOS", "").split():
        repo, _, label = entry.partition(":")
        sources.append((repo, label or "module/http"))
    issues = {}
    for repo, label in sources:
        for issue in list_issues(repo, label):
            issues[issue["url"]] = {"repo": repo, "number": issue["number"], "url": issue["url"],
                                    "title": issue["title"], "state": issue["state"],
                                    "labels": [l["name"] for l in issue["labels"]],
                                    "body": (issue["body"] or "")[:500]}
    return sorted(issues.values(), key=lambda i: (i["repo"], i["number"]))


def main():
    state = load_state()
    unit, reason = select(state)
    previous = state.get("units", {}).get(unit["id"], {})
    prev_sha = previous.get("sha", "")
    OUT.mkdir(exist_ok=True)
    scope = dict(unit, selection_reason=reason, previous_analysis=previous or None,
                 changed_since_previous=changed_files(unit, prev_sha))
    (OUT / "scope.json").write_text(json.dumps(scope, indent=2))
    (OUT / "known-issues.json").write_text(json.dumps(known_issues(), indent=2))
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write(f"unit={unit['id']}\nprev_sha={prev_sha}\nreason={reason}\n")
    print(f"Selected unit {unit['id']} ({reason})")


if __name__ == "__main__":
    main()
