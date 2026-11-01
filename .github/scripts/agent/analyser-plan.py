#!/usr/bin/env python3
"""Selects the weekly analyser's scope units and writes their context.

Selection: the units given in SCOPE_INPUT (comma-separated); otherwise UNITS_PER_RUN units (default 4): units never
analysed first (in catalogue order), then by the highest score of weeks since the last analysis plus 4 if any of the
unit's files changed on master since then.

Custom mode (find-similar): CUSTOM_SCOPES is a JSON array of generated units (same fields as the catalogue, plus
pattern, seed and exclude) and SEED names the issue or PR they were generated from; the catalogue and rotation are
not used.

Env: REPO, GH_TOKEN, SCOPE_INPUT, UNITS_PER_RUN, UPSTREAM_ISSUE_REPOS, CUSTOM_SCOPES, SEED. Expects the agent-state branch fetched as
origin/agent-state if it exists. Writes agent-context/known-issues.json and agent-context/<unit>/scope.json, and the
step output units (JSON array of unit ids).
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
    """Returns [(unit, reason)] for this run."""
    custom = os.environ.get("CUSTOM_SCOPES", "").strip()
    if custom:
        seed = os.environ.get("SEED", "")
        return [(dict(unit, seed=seed), f"similar to {seed}") for unit in json.loads(custom)]
    requested = [r.strip() for r in os.environ.get("SCOPE_INPUT", "").split(",") if r.strip()]
    if requested:
        by_id = {u["id"]: u for u in SCOPES}
        unknown = [r for r in requested if r not in by_id]
        if unknown:
            raise SystemExit(f"::error::Unknown scope unit(s): {', '.join(unknown)}")
        return [(by_id[r], "requested") for r in dict.fromkeys(requested)]
    count = max(1, int(os.environ.get("UNITS_PER_RUN") or 4))
    analysed = state.get("units", {})
    now = datetime.datetime.now(datetime.timezone.utc)
    ranked = []
    for order, unit in enumerate(SCOPES):
        entry = analysed.get(unit["id"])
        if entry is None:
            ranked.append((float("inf"), -order, unit, "never analysed"))
            continue
        weeks = (now - datetime.datetime.fromisoformat(entry["last_analysed"])).days / 7
        changed = bool(changed_files(unit, entry.get("sha")))
        reason = f"{weeks:.1f} weeks since last analysis" + (", files changed since" if changed else "")
        ranked.append((weeks + (4 if changed else 0), -order, unit, reason))
    ranked.sort(key=lambda r: (r[0], r[1]), reverse=True)
    return [(unit, reason) for _score, _order, unit, reason in ranked[:count]]


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
    selected = select(state)
    OUT.mkdir(exist_ok=True)
    for unit, reason in selected:
        previous = state.get("units", {}).get(unit["id"], {})
        scope = dict(unit, selection_reason=reason, previous_analysis=previous or None,
                     changed_since_previous=changed_files(unit, previous.get("sha", "")))
        (OUT / unit["id"]).mkdir(exist_ok=True)
        (OUT / unit["id"] / "scope.json").write_text(json.dumps(scope, indent=2))
        print(f"Selected unit {unit['id']} ({reason})")
    (OUT / "known-issues.json").write_text(json.dumps(known_issues(), indent=2))
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write(f"units={json.dumps([u['id'] for u, _ in selected])}\n")


if __name__ == "__main__":
    main()
