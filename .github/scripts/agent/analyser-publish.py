#!/usr/bin/env python3
"""Files the weekly analyser's public findings as issues: drops unverified bugs and questions, skips findings whose
fingerprint already exists in any agent-generated issue (open or closed), caps the number filed, and writes a publish
report for the run report. With DRY_RUN=true nothing is filed.

Env: REPO, RUN_URL, GH_TOKEN, DRY_RUN. Reads agent-output/{result.json,repro.json,meta.json};
writes agent-output/publish-report.json.
"""
import json
import os
import re
import subprocess
from pathlib import Path

REPO, RUN_URL = os.environ["REPO"], os.environ["RUN_URL"]
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
OUT = Path("agent-output")
MAX_ISSUES = 4
CATEGORY = {
    "bug": ("Bug", ["Type/Bug", "module/http", "agent/generated"]),
    "spec": ("Spec issue", ["Type/Improvement", "Area/Spec", "module/http", "agent/generated"]),
    "question": ("Question", ["Type/Question", "Area/Spec", "module/http", "agent/generated"]),
}
FP_MARKER = re.compile(r"<!--\s*analyser:fp=([a-z0-9-]+/[a-z0-9-]+)\s*-->")


def gh(*args, payload=None):
    proc = subprocess.run(["gh", *args], input=json.dumps(payload) if payload is not None else None,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()}")
    return proc.stdout


def clean(text):
    return re.sub(r"<!--\s*analyser:[^>]*-->", "", text or "").strip()


def slug(key):
    return re.sub(r"[^a-z0-9-]+", "-", key.lower()).strip("-")[:60] or "finding"


def existing_fingerprints():
    listed = gh("issue", "list", "--repo", REPO, "--state", "all", "--label", "agent/generated", "--limit", "2000",
                "--json", "body")
    return {fp for issue in json.loads(listed) for fp in FP_MARKER.findall(issue["body"] or "")}


def issue_body(finding, category_label, verification, meta, fingerprint):
    parts = [clean(finding["body"]), "",
             f"**Classification:** {category_label} — {clean(finding['rule'])}"]
    if finding.get("related_issues"):
        parts += ["", "**Related:** " + ", ".join(f"#{n}" for n in finding["related_issues"])]
    if verification:
        parts += ["", "### Reproduction", "",
                  f"> [!NOTE]\n> **Verified by the workflow:** `{verification['command']}` → {verification['reason']}."]
        if verification.get("message"):
            parts += [">", "> ````text"] + ["> " + line for line in verification["message"].splitlines()] + ["> ````"]
        parts += ["", "<details><summary>Test code</summary>", "", "````ballerina", clean(finding["repro"]["test_code"]),
                  "````", "", "</details>"]
    elif finding.get("repro"):
        parts += ["", "<details><summary>Test showing the current behaviour</summary>", "", "````ballerina",
                  clean(finding["repro"]["test_code"]), "````", "", "</details>"]
    parts += ["", "---",
              f"<sub>Found by the weekly analyser in scope `{meta['unit']}` at `{meta['sha'][:12]}` · "
              f"[workflow run]({RUN_URL})</sub>", "", f"<!-- analyser:fp={fingerprint} -->"]
    return "\n".join(parts)


def main():
    result = json.loads((OUT / "result.json").read_text() or "null")
    if not isinstance(result, dict) or not isinstance(result.get("findings"), list):
        raise SystemExit("::error::Agent produced no valid structured output")
    repro_file = OUT / "repro.json"
    repro = json.loads(repro_file.read_text()) if repro_file.exists() else {}
    meta = json.loads((OUT / "meta.json").read_text())
    known = existing_fingerprints()

    report = {"filed": [], "would_file": [], "dropped": []}
    # Bugs take the capped slots first; otherwise the agent's priority order is kept (sorted() is stable).
    for finding in sorted(result["findings"], key=lambda f: f.get("category") != "bug"):
        title = clean(finding.get("title", ""))
        category = finding.get("category")
        if category not in CATEGORY or not title or not finding.get("body") or not finding.get("rule"):
            report["dropped"].append({"title": title or "(untitled)", "reason": "invalid finding"})
            continue
        fingerprint = f"{meta['unit']}/{slug(finding.get('key', ''))}"
        verification = None
        if category in ("bug", "question"):
            verification = repro.get(finding.get("key"), {})
            if verification.get("status") != "reproduced":
                reason = verification.get("reason", "no reproduction")
                report["dropped"].append({"title": title, "category": category,
                                          "reason": f"not reproduced by the workflow: {reason}"})
                continue
        if fingerprint in known:
            report["dropped"].append({"title": title, "category": category,
                                      "reason": f"already filed (fingerprint {fingerprint})"})
            continue
        if len(report["filed"]) + len(report["would_file"]) >= MAX_ISSUES:
            report["dropped"].append({"title": title, "category": category,
                                      "reason": f"over the cap of {MAX_ISSUES} issues per run"})
            continue
        label, labels = CATEGORY[category]
        body = issue_body(finding, label, verification, meta, fingerprint)
        entry = {"title": title, "category": category, "fingerprint": fingerprint}
        if DRY_RUN:
            (OUT / f"dry-run-{len(report['would_file']) + 1}.md").write_text(f"# {title}\n\n{body}")
            report["would_file"].append(entry)
        else:
            url = gh("issue", "create", "--repo", REPO, "--title", title, "--body", body,
                     *[arg for l in labels for arg in ("--label", l)]).strip()
            report["filed"].append(dict(entry, url=url))
        known.add(fingerprint)

    (OUT / "publish-report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
