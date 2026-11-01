#!/usr/bin/env python3
"""Delivers the defect scanner's security findings privately. Never prints finding content.

Channels (SECURITY_CHANNEL):
- advisory: a draft repository security advisory per finding (public repositories only; needs
  SECURITY_ADVISORY_TOKEN with repository security advisories write access).
- issue: an issue labelled Area/Security, refused unless the repository is private (used while draft advisories are
  unavailable, which is the case for private repositories).

Env: REPO, RUN_URL, GH_TOKEN, SECURITY_CHANNEL, SECURITY_ADVISORY_TOKEN, DRY_RUN, MAX_SECURITY.
Reads <SECURITY_DIR>/*/{security.json,meta.json} (one decrypted directory per unit) and delivers at most MAX_SECURITY
(default 3) findings per run, most severe first; writes the found and delivered counts to the step output.
"""
import json
import os
import re
import subprocess
from pathlib import Path

REPO, RUN_URL = os.environ["REPO"], os.environ["RUN_URL"]
CHANNEL = os.environ.get("SECURITY_CHANNEL", "")
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
ROOT = Path(os.environ.get("SECURITY_DIR", "security"))
MAX_SECURITY = int(os.environ.get("MAX_SECURITY") or 3)
SEVERITY = {"critical": 0, "high": 1, "medium": 2, "low": 3}
FP_MARKER = re.compile(r"<!--\s*(?:analyser|scanner):sec=([a-z0-9-]+/[a-z0-9-]+)\s*-->")


def gh(args, token=None, payload=None):
    env = dict(os.environ, GH_TOKEN=token) if token else os.environ
    proc = subprocess.run(["gh", *args], input=json.dumps(payload) if payload is not None else None,
                          capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        # Error output can echo the request body; report only the status line.
        raise SystemExit(f"::error::gh {args[0]} {args[1] if len(args) > 1 else ''} failed "
                         f"({proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else 'no output'})")
    return proc.stdout


def slug(key):
    return re.sub(r"[^a-z0-9-]+", "-", key.lower()).strip("-")[:60] or "finding"


ISSUE_NOTE = ("> [!IMPORTANT]\n> Potential security vulnerability, filed as an issue because draft security advisories are only "
              "available in public repositories. Move it to a GitHub security advisory (Security tab → Advisories) "
              "before this finding or this repository becomes public, and do not copy it to public trackers.")


def body_for(finding, meta, fingerprint):
    return "\n".join([
        *([ISSUE_NOTE, ""] if CHANNEL == "issue" else []),
        re.sub(r"^.*Generated with \[Claude Code\].*$\n?", "",
               re.sub(r"<!--\s*(?:analyser|scanner):[^>]*-->", "", finding["body"]), flags=re.MULTILINE).strip(), "",
        "---",
        f"Found by the defect scanner in scope `{meta['unit']}` at `{meta['sha'][:12]}` ([workflow run]({RUN_URL})). "
        "This finding has not been reviewed by a human yet.", "",
        f"<!-- scanner:sec={fingerprint} -->",
    ])


def load():
    findings = []
    for unit_dir in sorted(p for p in ROOT.iterdir() if p.is_dir()) if ROOT.exists() else []:
        if (unit_dir / "security.json").exists() and (unit_dir / "meta.json").exists():
            meta = json.loads((unit_dir / "meta.json").read_text())
            findings += [(meta, f) for f in json.loads((unit_dir / "security.json").read_text())]
    return sorted(findings, key=lambda e: SEVERITY.get(e[1].get("severity"), 4))


def main():
    findings = load()
    delivered = 0
    if findings and not DRY_RUN:
        if CHANNEL == "issue":
            if json.loads(gh(["api", f"repos/{REPO}"]))["private"] is not True:
                raise SystemExit("::error::SECURITY_CHANNEL=issue is only allowed in private repositories")
            listed = gh(["issue", "list", "--repo", REPO, "--state", "all", "--label", "Area/Security",
                         "--limit", "1000", "--json", "body"])
            known = {fp for i in json.loads(listed) for fp in FP_MARKER.findall(i["body"] or "")}
        elif CHANNEL == "advisory":
            token = os.environ.get("SECURITY_ADVISORY_TOKEN")
            if not token:
                raise SystemExit("::error::SECURITY_CHANNEL=advisory needs the SECURITY_ADVISORY_TOKEN secret")
            listed = gh(["api", "--paginate", f"repos/{REPO}/security-advisories", "--jq", ".[].description"],
                        token=token)
            known = set(FP_MARKER.findall(listed))
        else:
            raise SystemExit(f"::error::Unknown SECURITY_CHANNEL '{CHANNEL}' (expected issue or advisory)")

        for meta, finding in findings:
            if delivered >= MAX_SECURITY:
                print(f"::warning::{len(findings) - delivered} security finding(s) over the cap of {MAX_SECURITY} "
                      "were not delivered; they are in the run's encrypted artifacts")
                break
            fingerprint = f"{meta['unit']}/{slug(finding.get('key', ''))}"
            if fingerprint in known:
                continue
            body = body_for(finding, meta, fingerprint)
            if CHANNEL == "issue":
                gh(["issue", "create", "--repo", REPO, "--title", f"[Security] {finding['title']}", "--body", body,
                    "--label", "Area/Security", "--label", "agent/generated", "--label", "module/http"])
            else:
                gh(["api", "-X", "POST", f"repos/{REPO}/security-advisories", "--input", "-"],
                   token=os.environ["SECURITY_ADVISORY_TOKEN"],
                   payload={"summary": finding["title"], "description": body, "severity": finding["severity"],
                            "cwe_ids": finding.get("cwe_ids") or None,
                            "vulnerabilities": [{"package": {"ecosystem": "other", "name": "ballerina/http"}}]})
            known.add(fingerprint)
            delivered += 1

    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write(f"found={len(findings)}\ndelivered={delivered}\n")
    print(f"Security findings: {len(findings)} found, {delivered} delivered via '{CHANNEL or 'none'}'"
          + (" (dry run)" if DRY_RUN else ""))


if __name__ == "__main__":
    main()
