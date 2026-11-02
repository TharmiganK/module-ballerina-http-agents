#!/usr/bin/env python3
"""Files the defect scanner's (or, with SCANNER=gap, the gap scanner's) public findings as issues, across all scope units of the run: drops unverified bugs and
questions, skips findings whose fingerprint already exists in any agent-generated issue (open or closed), files at most
MAX_ISSUES (default 6) per run with bugs first, and writes a publish report. With DRY_RUN=true nothing is filed.

Env: REPO, RUN_URL, GH_TOKEN, DRY_RUN, MAX_ISSUES, SCANNER (defect or gap). Reads <OUTPUTS_DIR>/*/{result.json,repro.json,meta.json,completed}
(one directory per unit; units without the completed marker are skipped); writes publish-report.json and dry-run-*.md
to REPORT_DIR.
"""
import json
import os
import re
import subprocess
from pathlib import Path

REPO, RUN_URL = os.environ["REPO"], os.environ["RUN_URL"]
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
OUTPUTS = Path(os.environ.get("OUTPUTS_DIR", "outputs"))
REPORT_DIR = Path(os.environ.get("REPORT_DIR", "publish"))
MAX_ISSUES = int(os.environ.get("MAX_ISSUES") or 6)
GAP = os.environ.get("SCANNER", "defect") == "gap"
CATEGORY = {
    "improvement": ("Improvement", ["Type/Improvement", "module/http", "agent/generated"]),
    "feature": ("New feature", ["Type/NewFeature", "module/http", "agent/generated"]),
} if GAP else {
    "bug": ("Bug", ["Type/Bug", "module/http", "agent/generated"]),
    "spec": ("Spec issue", ["Type/Improvement", "Area/Spec", "module/http", "agent/generated"]),
    "question": ("Question", ["Type/Question", "Area/Spec", "module/http", "agent/generated"]),
}
FP_MARKER = re.compile(r"<!--\s*(?:analyser|scanner):fp=([a-z0-9-]+/[a-z0-9-]+)\s*-->")



def unit_dirs(root):
    """One directory per unit. download-artifact extracts a single matching artifact into root itself."""
    if (root / "meta.json").exists():
        return [root]
    return sorted(p for p in root.iterdir() if p.is_dir()) if root.exists() else []

def gh(*args, payload=None):
    proc = subprocess.run(["gh", *args], input=json.dumps(payload) if payload is not None else None,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()}")
    return proc.stdout


ATTRIBUTION = re.compile(r"^.*Generated with \[Claude Code\].*$\n?", re.MULTILINE)


def clean(text):
    text = text or ""
    if "\n" not in text.strip() and "\\n" in text:
        text = text.replace("\\n", "\n")
    return ATTRIBUTION.sub("", re.sub(r"<!--\s*(?:analyser|scanner):[^>]*-->", "", text)).strip()


def slug(key):
    return re.sub(r"[^a-z0-9-]+", "-", key.lower()).strip("-")[:60] or "finding"


def existing_fingerprints():
    listed = gh("issue", "list", "--repo", REPO, "--state", "all", "--label", "agent/generated", "--limit", "2000",
                "--json", "body")
    return {fp for issue in json.loads(listed) for fp in FP_MARKER.findall(issue["body"] or "")}


def issue_body(finding, category_label, verification, meta, fingerprint):
    parts = [clean(finding["body"]), "",
             f"**Classification:** {category_label} — {clean(finding['rule'])}"]
    if meta.get("seed"):
        parts += ["", f"**Found while looking for {'gaps' if GAP else 'defects'} similar to #{meta['seed'].split(':', 1)[1]}.**"]
    if meta.get("handoff"):
        parts += ["", f"**Noticed by the [{meta['handoff']['from']}]({meta['handoff']['run_url']}) and verified "
                      f"by the {'gap' if GAP else 'defect'} scanner.**"]
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
    name = ("gap scanner" if GAP else "defect scanner") + (" (find similar)" if meta.get("seed") else "")
    parts += ["", "---",
              f"<sub>Found by the {name} in scope "
              f"`{meta['unit']}` at `{meta['sha'][:12]}` · "
              f"[workflow run]({RUN_URL})</sub>", "", f"<!-- scanner:fp={fingerprint} -->"]
    return "\n".join(parts)


def load_units():
    """Returns [(meta, finding, repro)] for every finding of every completed unit, in unit then priority order."""
    entries = []
    for unit_dir in unit_dirs(OUTPUTS):
        if not (unit_dir / "completed").exists():
            print(f"Skipping {unit_dir.name}: the agent job did not complete")
            continue
        result = json.loads((unit_dir / "result.json").read_text() or "null")
        if not isinstance(result, dict) or not isinstance(result.get("findings"), list):
            print(f"::warning::Skipping {unit_dir.name}: no valid structured output")
            continue
        meta = json.loads((unit_dir / "meta.json").read_text())
        scope = json.loads((unit_dir / "scope.json").read_text()) if (unit_dir / "scope.json").exists() else {}
        meta["seed"] = scope.get("seed", "")
        meta["handoff"] = scope.get("handoff")
        repro = json.loads((unit_dir / "repro.json").read_text()) if (unit_dir / "repro.json").exists() else {}
        entries += [(meta, finding, repro) for finding in result["findings"]]
    return entries


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    known = existing_fingerprints()
    report = {"filed": [], "would_file": [], "dropped": []}
    # Bugs take the capped slots first; otherwise unit and priority order are kept (sorted() is stable). Gap findings
    # are ranked by the agent's demand score instead.
    rank = (lambda e: -e[1].get("demand", 0)) if GAP else (lambda e: e[1].get("category") != "bug")
    for meta, finding, repro in sorted(load_units(), key=rank):
        title = clean(finding.get("title", ""))
        category = finding.get("category")
        unit = meta["unit"]
        if category not in CATEGORY or not title or not finding.get("body") or not finding.get("rule"):
            report["dropped"].append({"unit": unit, "title": title or "(untitled)", "reason": "invalid finding"})
            continue
        fingerprint = f"{'gap-' if GAP else ''}{unit}/{slug(finding.get('key', ''))}"
        verification = None
        if category in ("bug", "question"):
            verification = repro.get(finding.get("key"), {})
            if verification.get("status") != "reproduced":
                reason = verification.get("reason", "no reproduction")
                report["dropped"].append({"unit": unit, "title": title, "category": category,
                                          "reason": f"not reproduced by the workflow: {reason}"})
                continue
        if fingerprint in known:
            report["dropped"].append({"unit": unit, "title": title, "category": category,
                                      "reason": f"already filed (fingerprint {fingerprint})"})
            continue
        if len(report["filed"]) + len(report["would_file"]) >= MAX_ISSUES:
            report["dropped"].append({"unit": unit, "title": title, "category": category,
                                      "reason": f"over the cap of {MAX_ISSUES} issues per run"})
            continue
        label, labels = CATEGORY[category]
        body = issue_body(finding, label, verification, meta, fingerprint)
        entry = {"unit": unit, "title": title, "category": category, "fingerprint": fingerprint}
        if DRY_RUN:
            (REPORT_DIR / f"dry-run-{len(report['would_file']) + 1}.md").write_text(f"# {title}\n\n{body}")
            report["would_file"].append(entry)
        else:
            url = gh("issue", "create", "--repo", REPO, "--title", title, "--body", body,
                     *[arg for l in labels for arg in ("--label", l)]).strip()
            report["filed"].append(dict(entry, url=url))
        known.add(fingerprint)

    (REPORT_DIR / "publish-report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
