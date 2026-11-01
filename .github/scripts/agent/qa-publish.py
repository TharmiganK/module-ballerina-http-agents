#!/usr/bin/env python3
"""Publishes the QA agent's findings as one PR review (event COMMENT): validates the output, downgrades
unverified bugs to questions, drops findings already reported on the PR, anchors findings to commentable diff
lines, caps inline comments and moves the rest into the review body.

Env: REPO, PR, RUN_URL, GH_TOKEN. Reads agent-output/{result.json,repro.json,meta.json}.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO, PR, RUN_URL = os.environ["REPO"], os.environ["PR"], os.environ["RUN_URL"]
OUT = Path("agent-output")
BOT = "github-actions[bot]"
MAX_INLINE = 8
MAX_BODY = 60000
LABELS = {"bug": "Bug", "spec": "Spec", "missing-test": "Missing test", "question": "Question"}
SPEC_LABELS = {"deviation": "Spec deviation", "not-updated": "Spec not updated"}
KEY_MARKER = re.compile(r"<!--\s*qa:key=([a-z0-9-]+)\s*-->")


def gh_api(path, method="GET", payload=None, paginate=False):
    args = ["gh", "api", path, "-X", method]
    if paginate:
        args += ["--paginate", "--jq", ".[] | tojson"]
    if payload is not None:
        args += ["--input", "-"]
    proc = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"gh api {method} {path} failed: {proc.stderr.strip()} {proc.stdout.strip()[:500]}")
    if paginate:
        return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


ATTRIBUTION = re.compile(r"^.*Generated with \[Claude Code\].*$\n?", re.MULTILINE)


def clean(text):
    return ATTRIBUTION.sub("", re.sub(r"<!--\s*qa:[^>]*-->", "", text or "")).strip()


def slug(key):
    return re.sub(r"[^a-z0-9-]+", "-", key.lower()).strip("-")[:60] or "finding"


def commentable_lines(files):
    lines = {}
    for f in files:
        sides = {"LEFT": set(), "RIGHT": set()}
        left = right = 0
        for row in (f.get("patch") or "").splitlines():
            hunk = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", row)
            if hunk:
                left, right = int(hunk.group(1)), int(hunk.group(2))
            elif row.startswith("+"):
                sides["RIGHT"].add(right)
                right += 1
            elif row.startswith("-"):
                sides["LEFT"].add(left)
                left += 1
            elif row.startswith("\\"):
                continue
            else:
                sides["LEFT"].add(left)
                sides["RIGHT"].add(right)
                left += 1
                right += 1
        lines[f["filename"]] = sides
    return lines


def previous_keys():
    keys = set()
    for review in gh_api(f"repos/{REPO}/pulls/{PR}/reviews", paginate=True) or []:
        if review["user"]["login"] == BOT:
            keys.update(KEY_MARKER.findall(review.get("body") or ""))
    for comment in gh_api(f"repos/{REPO}/pulls/{PR}/comments", paginate=True) or []:
        if comment["user"]["login"] == BOT:
            keys.update(KEY_MARKER.findall(comment.get("body") or ""))
    return keys


def needs_repro(finding):
    return finding["kind"] == "bug" or (finding["kind"] == "spec" and finding.get("spec_case") == "deviation")


def render(finding, kind, verification):
    title = clean(finding["title"])
    downgraded = needs_repro(finding) and kind == "question"
    if downgraded:
        prefix = "Possible spec deviation" if finding["kind"] == "spec" else "Possible issue"
        title = f"{prefix} (not reproduced): {title}"
    label = SPEC_LABELS[finding["spec_case"]] if kind == "spec" else LABELS[kind]
    parts = [f"**[{label}]** {title}", ""]
    if finding["kind"] == "spec" and finding.get("spec_section"):
        parts += [f"_Spec: {clean(finding['spec_section'])}_", ""]
    parts.append(clean(finding["body"]))
    repro = finding.get("repro")
    if needs_repro(finding) and repro:
        if not downgraded:
            parts += ["", f"> [!NOTE]\n> **Reproduction verified by the workflow:** `{verification['command']}` → "
                          f"{verification['reason']}."]
            if verification.get("message"):
                quoted = "\n".join("> " + line for line in verification["message"].splitlines())
                parts += [">", "> ````text", quoted, "> ````"]
        else:
            reason = (verification or {}).get("reason", "verification did not run")
            parts += ["", f"_The workflow re-ran the reproduction below and it did not confirm the issue: {reason}._"]
        code = clean(repro["test_code"])
        parts += ["", "<details><summary>Reproduction test</summary>", "", "````ballerina", code, "````", "",
                  "</details>"]
    parts += ["", f"<!-- qa:key={finding['key']} -->"]
    return "\n".join(parts)


def main():
    result = json.loads((OUT / "result.json").read_text() or "null")
    if not isinstance(result, dict) or not isinstance(result.get("findings"), list) or not result.get("summary"):
        fail("Agent produced no valid structured output")
    repro_file = OUT / "repro.json"
    repro = json.loads(repro_file.read_text()) if repro_file.exists() else {}
    reviewed_sha = json.loads((OUT / "meta.json").read_text())["head_sha"]

    pr = gh_api(f"repos/{REPO}/pulls/{PR}")
    stale = pr["head"]["sha"] != reviewed_sha
    anchors = commentable_lines(gh_api(f"repos/{REPO}/pulls/{PR}/files", paginate=True) or [])
    seen = previous_keys()

    inline, other, duplicates = [], [], 0
    counts = {"bug": 0, "spec": 0, "missing-test": 0, "question": 0}
    for finding in result["findings"]:
        if finding.get("kind") not in LABELS or not finding.get("title") or not finding.get("body"):
            fail(f"Invalid finding: {json.dumps(finding)[:300]}")
        finding["key"] = slug(finding.get("key", ""))
        if finding["key"] in seen:
            duplicates += 1
            continue
        seen.add(finding["key"])
        if finding["kind"] == "spec" and finding.get("spec_case") not in SPEC_LABELS:
            finding["spec_case"] = "deviation" if finding.get("repro") else "not-updated"
        kind = finding["kind"]
        verification = repro.get(finding["key"]) if needs_repro(finding) else None
        if needs_repro(finding) and (verification or {}).get("status") != "reproduced":
            kind = "question"
        counts[kind] += 1
        body = render(finding, kind, verification)
        path, line, side = finding.get("path"), finding.get("line"), finding.get("side") or "RIGHT"
        if (not stale and path in anchors and isinstance(line, int) and line in anchors[path][side]
                and len(inline) < MAX_INLINE):
            inline.append({"path": path, "line": line, "side": side, "body": body})
        else:
            location = f"`{path}`" + (f" line {line}" if line else "") if path else ""
            other.append((location, body))

    header = [
        "## QA review", "",
        f"**Reviewed commit:** `{reviewed_sha[:12]}`", "",
        "| Verified bugs | Spec | Missing tests | Questions |", "|---|---|---|---|",
        f"| {counts['bug']} | {counts['spec']} | {counts['missing-test']} | {counts['question']} |", "",
    ]
    if stale:
        header += ["> [!WARNING]\n> The PR changed while this review ran; all findings are listed below instead of "
                   "inline. Comment `/qa` to review the latest commit.", ""]
    if not any(counts.values()):
        header += ["No behavioural issues, spec issues or missing tests found.", ""]
    body = "\n".join(header) + "\n" + clean(result["summary"])
    if other:
        body += "\n\n### Other findings\n"
        for location, text in other:
            body += f"\n---\n{('_' + location + '_' + chr(10) + chr(10)) if location else ''}{text}\n"
    if duplicates:
        body += f"\n\n_{duplicates} finding(s) already reported in an earlier QA review were not repeated._"
    footer = f"\n\n<!-- qa:review -->\n\n---\n<sub>Posted by the QA agent · [workflow run]({RUN_URL})</sub>\n"
    if len(body) + len(footer) > MAX_BODY:
        body = body[:MAX_BODY - len(footer) - 100] + "\n\n_(truncated; see the workflow artifacts)_"
    body += footer

    review = {"commit_id": reviewed_sha, "event": "COMMENT", "body": body, "comments": inline}
    try:
        gh_api(f"repos/{REPO}/pulls/{PR}/reviews", method="POST", payload=review)
    except RuntimeError as error:
        if not inline:
            raise
        print(f"::warning::Inline comments rejected ({error}); posting them in the review body")
        moved = "\n".join(f"\n---\n_`{c['path']}` line {c['line']}_\n\n{c['body']}\n" for c in inline)
        review = {"commit_id": reviewed_sha, "event": "COMMENT",
                  "body": body.replace("\n\n<!-- qa:review -->", "\n\n### Inline findings\n" + moved
                                       + "\n\n<!-- qa:review -->"), "comments": []}
        gh_api(f"repos/{REPO}/pulls/{PR}/reviews", method="POST", payload=review)
    print(f"Posted review: {len(inline)} inline, {len(other)} in body, {duplicates} duplicates, counts {counts}")


if __name__ == "__main__":
    main()
