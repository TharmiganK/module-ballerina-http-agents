#!/usr/bin/env python3
"""Turns the handoffs of a defect or gap scanner run into custom scope units for the scanner each one targets, and
dispatches those runs.

Skips handoffs already passed on by an earlier run (keys recorded in the source scanner's state.json as handed_off),
handoffs whose paths do not exist, and every handoff of a run that was itself a handoff run, so notes are passed on
at most one level. At most MAX_HANDOFFS (default 3) are passed on per run. With DRY_RUN=true nothing is dispatched.

Env: SCANNER (source: defect or gap), REPO, GH_TOKEN, RUN_URL, RUN_NUMBER, DRY_RUN, IS_HANDOFF, MAX_HANDOFFS.
Reads <OUTPUTS_DIR>/*/{result.json,meta.json,scope.json,completed}; writes <REPORT_DIR>/handoff-report.json.
"""
import base64
import json
import os
import re
import subprocess
from pathlib import Path

SOURCE = os.environ.get("SCANNER", "defect")
REPO, RUN_URL = os.environ["REPO"], os.environ["RUN_URL"]
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
OUTPUTS = Path(os.environ.get("OUTPUTS_DIR", "outputs"))
REPORT_DIR = Path(os.environ.get("REPORT_DIR", "publish"))
MAX_HANDOFFS = int(os.environ.get("MAX_HANDOFFS") or 3)
NAME = {"defect": "defect scanner", "gap": "gap scanner"}
WORKFLOW = {"defect": "agent-defect-scanner.yml", "gap": "agent-gap-scanner.yml"}
REFERENCES = Path(".github/agent-prompts/gap-scanner/references.json")
MAX_INPUT = 60000


def slug(text, size=40):
    return re.sub(r"[^a-z0-9-]+", "-", text.lower()).strip("-")[:size] or "note"


def unit_dirs(root):
    """One directory per unit. download-artifact extracts a single matching artifact into root itself."""
    if (root / "meta.json").exists():
        return [root]
    return sorted(p for p in root.iterdir() if p.is_dir()) if root.exists() else []


def handed_off_before():
    path = f"repos/{REPO}/contents/{SOURCE}-scanner/state.json?ref=agent-state"
    shown = subprocess.run(["gh", "api", path, "--jq", ".content"], capture_output=True, text=True)
    if shown.returncode != 0:
        return set()
    return set(json.loads(base64.b64decode(shown.stdout)).get("handed_off", []))


def load(path, default):
    try:
        text = path.read_text() if path.exists() else ""
        return json.loads(text) if text.strip() else default
    except json.JSONDecodeError:
        return default


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    report = {"passed": [], "skipped": []}
    if os.environ.get("IS_HANDOFF") == "true":
        print("This run was itself a handoff run; its notes stay in the report.")
        (REPORT_DIR / "handoff-report.json").write_text(json.dumps(report, indent=2))
        return
    done = handed_off_before()
    references = json.loads(REFERENCES.read_text()) if REFERENCES.exists() else {}
    known_packages = {p.name for p in Path("ballerina-tests").iterdir() if p.is_dir()} | {"native", "compiler-plugin"}
    units = {"defect": [], "gap": []}
    for unit_dir in unit_dirs(OUTPUTS):
        if not (unit_dir / "completed").exists():
            continue
        result = load(unit_dir / "result.json", {})
        meta = load(unit_dir / "meta.json", {})
        scope = load(unit_dir / "scope.json", {})
        for note in result.get("handoffs", []) if isinstance(result, dict) else []:
            target, key = note.get("target"), slug(note.get("key", ""), 60)
            entry = {"from_unit": meta.get("unit"), "target": target, "key": key, "title": note.get("title", "")}
            if target not in WORKFLOW:
                report["skipped"].append(dict(entry, reason="unknown target"))
                continue
            done_key = f"{target}:{key}"
            if done_key in done:
                report["skipped"].append(dict(entry, reason="already passed on by an earlier run"))
                continue
            paths = [p.strip().removeprefix("./") for p in note.get("paths", []) if Path(p.strip().removeprefix("./")).exists()]
            if not paths:
                report["skipped"].append(dict(entry, reason="none of its paths exist"))
                continue
            if len(report["passed"]) >= MAX_HANDOFFS:
                report["skipped"].append(dict(entry, reason=f"over the cap of {MAX_HANDOFFS} handoffs per run"))
                continue
            packages = [t for t in note.get("test_packages") or scope.get("test_packages", []) if t in known_packages]
            unit = {
                "id": f"handoff-{SOURCE}{os.environ.get('RUN_NUMBER', '')}-{slug(key)}",
                "description": note.get("title", ""),
                "spec_sections": note.get("spec_sections") or scope.get("spec_sections", []),
                "paths": paths,
                "test_packages": packages,
                "hints": [note.get("details", "")],
                "handoff": {"from": f"{NAME[SOURCE]} run {os.environ.get('RUN_NUMBER', '')} (unit {meta.get('unit')})",
                            "run_url": RUN_URL, "title": note.get("title", ""), "details": note.get("details", "")},
            }
            if target == "gap":
                unit["references"] = references.get(meta.get("unit", ""), {})
            units[target].append(unit)
            done.add(done_key)
            report["passed"].append(dict(entry, done_key=done_key, unit=unit["id"]))

    for target, batch in units.items():
        if not batch:
            continue
        payload = json.dumps(batch, separators=(",", ":"))
        if len(payload) > MAX_INPUT:
            print(f"::warning::Handoffs for the {NAME[target]} are too large for a workflow input; not dispatched")
            report["passed"] = [p for p in report["passed"] if p["target"] != target]
            continue
        if DRY_RUN:
            print(f"Would dispatch the {NAME[target]} with {len(batch)} handoff unit(s)")
            continue
        subprocess.run(["gh", "workflow", "run", WORKFLOW[target], "--repo", REPO, "-f", f"custom_scopes={payload}",
                        "-f", "handoff=true"], check=True)
        print(f"Dispatched the {NAME[target]} with {len(batch)} handoff unit(s)")
    report["dry_run"] = DRY_RUN
    (REPORT_DIR / "handoff-report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
