# Proposal: Weekly Analyser Agent

_Owners_: @TharmiganK  
_Reviewers_: @TharmiganK  
_Created_: 2026/11/01  
_Updated_: 2026/11/01  
_Status_: Implemented for PoC

## Summary

A scheduled AI agent that analyses one slice of the module each week for bugs, internal inconsistencies, specification problems, spec/implementation deviations and security vulnerabilities. It files a small number of verified, deduplicated issues, routes security findings to a private channel, and records what it covered so that the whole module is analysed over successive weeks.

It is the third agent of the PoC, after the [bug fixer](bug-fixer-agent.md) and the [PR QA agent](qa-agent.md), and reuses their infrastructure: the read-only agent job and deterministic publish job, `setup-build`, `run-tests.sh`, and workflow-side reproduction verification.

## Goals

- Find real defects that nobody has reported yet, at a rate of a few per week, with evidence a maintainer can act on directly.
- Never file a bug without a reproduction test that the workflow re-ran.
- Separate the outcomes cleanly: a bug in the code, a problem in the spec, or a question about which of the two is right.
- Keep security findings out of public issues, logs and artifacts.
- Cover the whole module over time without re-analysing the same code every week.
- Never file the same finding twice, including findings that were reported and closed.

## Non-goals

- Fixing anything. Filed bugs can be handed to the bug fixer by a maintainer adding `agent/investigate`.
- Style, refactoring or performance work without a demonstrable defect.
- Analysing dependencies (Netty, stdlib modules) beyond how this module uses them.

## Triggers

| Trigger | Notes |
|---|---|
| `schedule: cron '0 1 * * 1'` | Weekly, Monday 01:00 UTC, outside working hours in Sri Lanka. |
| `workflow_dispatch` with optional inputs `scope` (a scope unit id) and `dry_run` (boolean) | Manual runs for validation; `dry_run` produces the report and verification results without filing anything. |

Both are only startable by users with write access, so no actor check is needed beyond GitHub's.

## Scope rotation

### Scope units

The module is too large for one run, so it is divided into scope units in `.github/agent-prompts/analyser/scopes.json`. Each unit bundles the spec sections, Ballerina files, native packages and test packages for one feature area, so that the agent can compare spec, implementation and tests for the same behaviour in one run:

| Unit | Spec sections | Ballerina layer | Native layer | Tests |
|---|---|---|---|---|
| `listener` | 2.1 | `http_service_endpoint.bal`, `http_default_listener.bal` | `api/service/endpoint`, `transport/contractimpl/listener` | `http-service-tests` |
| `service-dispatching` | 2.2, 3, 4.1, 4.2 | `http_annotation.bal` | `api/HttpDispatcher`, `ResourceDispatcher`, `uri/` | `http-dispatching-tests` |
| `service-parameter-binding` | 2.3 (parameters), 4.3–4.5, 5 | `http_annotation.bal`, `http_types.bal` | `api/service/signature/` | `http-dispatching-tests` |
| `service-response` | 2.3 (return types), 6 | `http_connection.bal`, `http_response.bal`, `http_status_code_types.bal` | `api/nativeimpl/connection/` | `http-misc-tests`, `http-service-tests` |
| `client-core` | 2.4 (client actions) | `http_client_endpoint.bal`, `http_client.bal`, `http_client_config.bal` | `api/client/actions/`, `transport/contractimpl/sender/` | `http-client-tests` |
| `client-data-binding` | 2.4 (data binding, status code binding) | `http_client_payload_builder.bal`, `http_status_code_client*.bal` | `api/client/` | `http-client-tests` |
| `client-resiliency` | 2.4 (resiliency) | `resiliency_*.bal`, `redirect_http_client.bal` | — | `http-resiliency-tests` |
| `caching-cookies` | 2.4 (caching, cookies), 4.6 | `caching_*.bal`, `cookie_*.bal` | `api/client/caching/` | `http-advanced-tests` |
| `headers-payload` | 7 | `http_headers.bal`, `http_request.bal`, `http_commons.bal` | `api/nativeimpl/` (headers, request, response) | `http-misc-tests` |
| `interceptors-errors` | 8 | `http_interceptors.bal`, `http_errors.bal`, `http_status_error_utils.bal`, `http_request_context.bal` | `api/*Interceptor*` | `http-interceptor-tests` |
| `auth` | 9.1 | `auth_*.bal` | — | `http-security-tests` |
| `ssl` | 9.2 | `http_client_config.bal` (SSL), `http_service_endpoint.bal` (SSL) | `transport/contractimpl/common/ssl`, `certificatevalidation/` | `http-security-tests` |
| `http2` | 10.1 | — | `transport/**/http2/` | `http2-tests` |
| `sse-streaming` | 2.3 / 2.4 (SSE, streaming), 6.1 | `*sse*.bal`, `http_back_pressure.bal` | streaming parts of `transport/message/` | `http-advanced-tests` |
| `compiler-plugin` | 2.2–2.3 (compile-time rules), 11 | — | `compiler-plugin/` | `compiler-plugin-tests` |
| `logging-config` | trace and access log sections | `http_log_manager.bal` | `api/logging/` | `http-misc-tests` |

The exact paths are maintained in `scopes.json`; this table is the initial cut. With 16 units and one unit per week, a full cycle takes about four months.

### Selection

The plan job picks one unit per run, unless `scope` is given:

1. Units never analysed come first, in table order.
2. Otherwise, the unit with the highest score `weeks since last analysis + 4 × (files in the unit changed on master since its last analysis > 0)`, so recently changed code is re-analysed sooner. Ties go to the least recently analysed unit.

### State

State lives in `analyser/state.json` on an orphan branch `agent-state`, which nothing else uses. It records, per unit, the last analysis date, the `master` SHA analysed, and the run URL; and per run, a report file `analyser/reports/<yyyy>-W<ww>-<unit>.md`.

The Actions cache was rejected because entries unused for 7 days are evicted, which is exactly the weekly cadence; repository variables were rejected because writing them needs an admin-scoped token. A branch is durable, auditable (git history), and writable with `GITHUB_TOKEN`.

## Classification rules

| Category | When | Evidence required | Labels |
|---|---|---|---|
| **Bug** | The implementation is wrong regardless of the spec (crash, hang, leak, wrong result, internal inconsistency such as client and service, or HTTP/1.1 and HTTP/2, treating the same input differently), or it contradicts a clear, unambiguous statement in the spec. | A reproduction test in group `analyser_<run>_<k>` that the workflow re-ran and that failed for the claimed reason. | `Type/Bug`, `module/http`, `agent/generated` |
| **Spec issue** | `docs/spec/spec.md` is ambiguous, contradictory, incomplete (behaviour the implementation has but the spec does not describe) or out of date, while the implementation's behaviour is clear and plausible. | Quotes of the spec text with links, and the implementation reference; a test showing actual behaviour when the issue is about behaviour. | `Type/Improvement`, `Area/Spec`, `module/http`, `agent/generated` |
| **Question** | Spec and implementation disagree, and it is not clear which one is intended (both are plausible, or changing either would break users). | A test asserting the spec's behaviour that the workflow re-ran and that failed, plus the spec quote. Without the failing test, the disagreement is not established and the finding is dropped. | `Type/Question`, `Area/Spec`, `module/http`, `agent/generated` |
| **Security** | A vulnerability: anything an attacker can use to break confidentiality, integrity or availability (for example request smuggling, header injection, path traversal, unbounded resource use from untrusted input, TLS validation gaps, auth bypass). | A reproduction where safely possible; otherwise a precise code-level argument. | Never filed publicly; see [Security findings](#security-findings). |

Tie-breakers: a suspected bug that does not reproduce is dropped, not filed as a question (questions require the failing spec test too); if the spec is clear and the implementation contradicts it with user-visible impact, it is a bug, not a question. Every finding states which rule it was classified under.

## Design

### Jobs

`.github/workflows/agent-weekly-analyser.yml`:

| Job | Permissions | What it does |
|---|---|---|
| `plan` | `contents: read`, `issues: read` | Reads the state branch, selects the unit, gathers existing issues for dedup. |
| `agent` | `contents: read`, `issues: read` | Builds, runs Claude on the unit with a read-only token, then re-runs every reproduction. Uploads public findings as an artifact, and security findings only through the private path. |
| `publish-issues` | `contents: read`, `issues: write` | Validates, verifies, dedups and caps public findings, files issues. Skipped on `dry_run`. |
| `publish-security` | `contents: read`, `issues: write` (issue channel) plus `SECURITY_TRANSFER_PRIVATE_KEY` and `SECURITY_ADVISORY_TOKEN` (advisory channel) | Decrypts and delivers security findings privately; in a dry run it only counts them. |
| `update-state` | `contents: write` | Commits the state and the run report to `agent-state` and writes the report to the step summary. Runs after the publish jobs whenever `plan` succeeded, including dry runs and failed agent runs; the unit is only marked as analysed after a successful non-dry run. |

### Context

The plan job writes:

- `agent-context/scope.json`: the selected unit with its spec sections, file lists and test packages, the `master` SHA of the previous analysis of this unit and the files changed since.
- `agent-context/known-issues.json`: title, number, state, labels and the first 500 characters of the body for all issues in this repository labelled `module/http` or `agent/generated`, open and closed, plus the upstream trackers in the repository variable `UPSTREAM_ISSUE_REPOS` (`owner/repo:label` entries; for this mirror `ballerina-platform/ballerina-library:module/http`). The prompt also requires searching those trackers and open PRs in `UPSTREAM_CODE_REPO` for every candidate. The first real run filed two bugs that upstream already tracked (one with a fix PR in review) because only this repository's issues were checked.

### Agent instructions (summary)

1. Read the unit's spec sections, then its implementation across layers, then its tests, using `docs/architecture.md`.
2. Look for the categories above, prioritising user-visible behaviour on untested paths, client/service and HTTP/1.1/HTTP/2 inconsistencies, error handling, and limits on untrusted input.
3. Check every candidate against `known-issues.json` and drop it if an existing issue (open or closed) covers it.
4. For bugs and questions, write and run reproduction tests (group `analyser_<run>_<k>`, new ports), keeping them only if they fail for the claimed reason.
5. Return at most 8 public findings and at most 3 security findings, most important first, plus a coverage summary of what was examined.

Allowed tools are the same as the QA agent's: read and edit tools, `run-tests.sh`, the build-local `bal`, read-only `git` and `gh`. No GitHub writes.

### Output schema

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["coverage", "findings", "security"],
  "properties": {
    "coverage": {"type": "string", "maxLength": 20000},
    "findings": {
      "type": "array",
      "maxItems": 8,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["key", "category", "title", "body", "rule"],
        "properties": {
          "key": {"type": "string", "maxLength": 60},
          "category": {"type": "string", "enum": ["bug", "spec", "question"]},
          "title": {"type": "string", "maxLength": 120},
          "body": {"type": "string", "maxLength": 30000},
          "rule": {"type": "string", "maxLength": 500},
          "related_issues": {"type": "array", "items": {"type": "integer"}},
          "repro": {
            "type": "object",
            "additionalProperties": false,
            "required": ["test_package", "group", "test_code"],
            "properties": {
              "test_package": {"type": "string"},
              "test_filter": {"type": "string"},
              "group": {"type": "string"},
              "test_code": {"type": "string", "maxLength": 10000}
            }
          }
        }
      }
    },
    "security": {
      "type": "array",
      "maxItems": 3,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["key", "title", "severity", "body"],
        "properties": {
          "key": {"type": "string", "maxLength": 60},
          "title": {"type": "string", "maxLength": 120},
          "severity": {"type": "string", "enum": ["critical", "high", "medium", "low"]},
          "body": {"type": "string", "maxLength": 30000},
          "repro": {"type": "object"}
        }
      }
    }
  }
}
```

### Verification, dedup and caps

- **Verification.** `verify-findings.py`, shared with the QA agent, handles bug and question findings here and re-runs all reproduction groups, one `bal test` per package. Bugs and questions that do not reproduce are dropped and listed in the run report with the reason.
- **Dedup.** Each filed issue carries a hidden fingerprint `<!-- analyser:fp=<unit>/<key> -->`. Before filing, the publish job reads the bodies of all `agent/generated` issues, open and closed, and skips findings whose fingerprint is already there; this catches findings the agent re-discovers under the same key. The agent's own semantic check against `known-issues.json` catches findings reported by people.
- **Caps.** At most 4 public issues per run, in the agent's priority order, with verified bugs first; the rest are listed in the run report so they are not lost. At most 3 security findings per run.

### Issue format

```markdown
<summary paragraph>

**Classification:** <Bug | Spec issue | Question> — <the rule that applied>

### Details
<what the spec says (quoted, linked), what the implementation does (linked at the analysed SHA)>

### Reproduction
> [!NOTE]
> **Verified by the workflow:** `<command>` → <n> of <m> test(s) failed.
<failure message>
<details><summary>Test code</summary> ... </details>

### Suggested resolution
<for bugs: where the fix likely goes; for spec issues: proposed spec text; for questions: the options and their impact>

---
Found by the weekly analyser in scope `<unit>` at `<sha>` · [run](<url>)
<!-- analyser:fp=<unit>/<key> -->
```

### Run report

Every run, including dry runs and runs with no findings, writes a report to the state branch and to the run's step summary: the unit, the analysed SHA, the agent's coverage summary, filed issues, findings dropped (duplicate, not reproduced, over the cap) with reasons, the number of security findings delivered (count only), time and Claude usage. This is how maintainers see what was checked when nothing was filed.

### Security findings

Security findings never appear in issues, PR comments, step summaries or the run report (which shows only a count). In this private PoC repository, Actions logs and artifacts are only visible to collaborators; upstream they would be public, so the design keeps security content out of logs regardless: the agent returns it in structured output only, the collect step writes it to a separate file that is never printed, and the artifact containing it is either encrypted or not uploaded, depending on the delivery option.

Delivery options (decision needed before implementation):

| Option | How | Works upstream (public repo) | Setup | Notes |
|---|---|---|---|---|
| **A. Draft repository security advisory** | `publish-security` creates a draft advisory per finding with `POST /repos/{owner}/{repo}/security-advisories`; only admins and invited collaborators see drafts. | Yes; this is GitHub's intended private channel for vulnerabilities. | A fine-grained PAT or GitHub App token with "Repository security advisories: write", stored as a secret available only to `publish-security`. `GITHUB_TOKEN` cannot create advisories. | Findings stay in GitHub, with private discussion, CVE request and private fork for the fix. Recommended. |
| **B. Email** | `publish-security` sends an email via an SMTP action (pinned to a commit SHA) to a configured address. | Yes. | SMTP host, user and password secrets; a recipient address. | Matches the original intent; content leaves GitHub; relies on a third-party action and an SMTP account. |
| **C. Restricted-label issue** | File a normal issue labelled `Area/Security` in this private repository. | No: issues in a public repository are public. | None. | Simplest for the PoC, but must be replaced before going upstream. |
| **D. Encrypted artifact** | Encrypt the findings with a maintainer's public key (`age`) and upload them as an artifact; post nothing. | Yes. | One public key in the repository or a variable. | No notification by itself; someone must download and decrypt. Useful as a fallback alongside A or B. |

Decision: **A** for upstream. Draft advisories are not available in private repositories (the advisories API returns 404 for this private mirror while it works for the public upstream repository), so the channel is switchable through the repository variable `SECURITY_CHANNEL`:

- `advisory`: draft repository security advisory per finding, created with the `SECURITY_ADVISORY_TOKEN` secret (a fine-grained PAT or App token with "Repository security advisories: write"), used only by `publish-security`; dedup by a fingerprint in the advisory description.
- `issue`: an issue labelled `Area/Security` (plus `module/http`, `agent/generated`), titled `[Security] ...`, with a note to move it to a security advisory before the finding or the repository becomes public. Used in this private PoC repository; `analyser-security.py` refuses this channel if the repository is public, since `Area/Security` is a public label upstream. None of the Security tab's features work here: draft advisories and private vulnerability reporting are public-repository features, and code scanning alerts on private repositories need GitHub Advanced Security.

Transfer between jobs: the agent job splits the structured output into the public `analyser-output` artifact (without `security`) and an `analyser-security` artifact (3-day retention). `security-transfer.sh` encrypts the findings with a random per-run AES-256 key wrapped with the RSA public key in the repository variable `SECURITY_TRANSFER_PUBLIC_KEY` (OAEP, SHA-256), so the agent job needs no secret; only `publish-security` holds the private key (`SECURITY_TRANSFER_PRIVATE_KEY` secret) and decrypts. Without a public key, plaintext transfer is allowed only in a private repository; in a public repository the job deletes the plaintext and fails. Neither the logs, the step summary nor the run report contain security content beyond counts.

## Limits and estimates

| Setting | Value |
|---|---|
| `timeout-minutes` (agent job) | 120 |
| `--max-turns` | 150 |
| Model | `claude-opus-5-5` |
| Public issues per run | ≤ 4 |
| Security findings per run | ≤ 3 |
| Estimated Actions minutes | 45–90 per week (build 4, analysis 20–50, verification 5–20) |
| Estimated Claude usage | 60–150 turns, 3–8M mostly cached input tokens per run; the largest of the three agents |

## Alternatives considered

| Alternative | Reason not chosen |
|---|---|
| Analyse the whole module every run | Does not fit in a run's turn and context budget; shallow results. |
| Rotate spec sections, Ballerina files and native packages independently | Defects show up where spec, implementation and tests meet; a unit that bundles all three for one feature lets the agent compare them. |
| Actions cache or repository variables for state | Cache entries are evicted after 7 days unused; variables need an admin-scoped token. |
| File unverified suspected bugs as questions | The brief requires reproduction for bugs; unverified questions would add noise. They are listed in the run report instead. |
| Security findings in public issues with vague titles | Still disclosure on a public repository. |

## Risks and limitations

- Semantic dedup against human-written issues depends on the agent; a duplicate may slip through. The fingerprint only prevents the analyser from repeating itself.
- One unit per week means a defect in a rarely changed unit may wait up to four months; changed code is prioritised to offset this.
- Security findings without a safe reproduction rely on the agent's reasoning and need careful human triage.
- Long runs can hit the turn or time limit before finishing; the coverage summary and run report make partial coverage visible, and the unit is not marked as analysed unless the agent job completed.

## Validation plan

1. `dry_run` on `sse-streaming` while the issue #1 fix is not yet merged: expect it to rediscover the multi-line `data` bug and drop it as a duplicate of issue #1, and possibly to find related upstream SSE bugs (for example ballerina-platform/ballerina-library#9269, CRLF-terminated events) that are not in this repository. This tests both detection and dedup.
2. `dry_run` on a unit with known upstream bugs in `ballerina-platform/ballerina-library` that are not in this repository (for example `client-core`), and compare findings with those issues.
3. One real scheduled run, filing issues, then a second run on the same unit to confirm nothing is refiled.
4. Report per run: findings by category, how many a maintainer judged valid, dropped findings by reason, time, Actions minutes and Claude usage.
