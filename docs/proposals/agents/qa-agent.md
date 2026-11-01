# Proposal: PR QA Agent

_Owners_: @TharmiganK  
_Reviewers_: @TharmiganK  
_Created_: 2026/11/01  
_Updated_: 2026/11/01  
_Status_: Implemented for PoC

## Summary

A GitHub Actions based AI agent that reviews pull requests for behaviour, spec compliance and test coverage. It reads the change, its tests and the relevant parts of `docs/spec/spec.md`, looks for concrete bugs, spec deviations, stale spec text and missing test cases, and posts a single PR review: inline comments anchored to diff lines, and one summary for points that cannot be anchored. Every bug or spec-deviation claim is backed by a reproduction test that the workflow re-runs; anything it cannot reproduce is posted as a question.

It is the second agent of the PoC, after the [bug fixer](bug-fixer-agent.md), and reuses its infrastructure: the propose-then-publish split, `setup-build`, `run-tests.sh` and reproduction verification.

## Goals

- Catch behavioural bugs, spec deviations, missing spec updates and missing tests in PRs before human review, with few enough comments that each one is worth reading.
- Never claim a bug without a failing test that the workflow itself ran.
- Stay out of style, naming and formatting; checkstyle, spotbugs and human reviewers cover those.
- Never approve or request changes; the merge decision stays with maintainers.
- Work on PRs from this repository automatically, and be invocable on demand (`/qa`) in a way that can later be used safely on fork PRs upstream.

## Non-goals

- Replacing CI. The agent runs tests to investigate suspected bugs, not to validate the PR as a whole.
- Pushing fixes. Suggested fixes are described or given as GitHub suggestion blocks; the author applies them.
- Security review. That belongs to the weekly analyser's restricted channel.

## Triggers

| Trigger | Condition | Notes |
|---|---|---|
| `pull_request: [opened, reopened, ready_for_review]` | Not a draft; not from a fork (fork PRs get no secrets; use `/qa`); no `agent/qa-skip` label; not only docs (`paths-ignore: docs/**, **/*.md`) | One automatic review per PR. Pushes (`synchronize`) do not re-run it, to save minutes; use `/qa` after significant updates. |
| `issue_comment: [created]` on a PR | Comment body's first line is exactly `/qa`; author is not a bot and has write access | On-demand review of the current head. The gate reacts with 👀 so the requester sees it was picked up. |
| `workflow_dispatch` with input `pr` | Dispatched by the bug fixer's `publish-code` job after opening a PR | Agent PRs are opened with `GITHUB_TOKEN` and do not trigger `pull_request`; this gives them an automatic second review. |

The write-access check is the action's built-in check plus the same `author_association` pre-filter as the bug fixer. Reviews posted by the QA agent use `GITHUB_TOKEN`, so they do not trigger the bug fixer's review phase on agent PRs; a maintainer decides which QA findings the bug fixer should act on by reviewing the PR themselves.

Concurrency: `group: qa-<pr>` with `cancel-in-progress: true`, so a newer `/qa` replaces a running one.

On agent PRs the bug fixer answers the QA agent's threads (replying and resolving them) when a maintainer asks with `/bug-fixer`, or automatically when the PR has `agent/auto-fix`; since a review posted with `GITHUB_TOKEN` triggers no workflows, the QA publish job dispatches the auto-fix scheduler itself on such PRs.

## Design

### Jobs

Same propose-then-publish split as the bug fixer, in `.github/workflows/agent-qa.yml`:

| Job | Permissions | What it does |
|---|---|---|
| `gate` | `contents: read`, `pull-requests: write` (reaction and skip notice only) | Resolves the PR number for all three triggers, applies the skip rules, reacts to `/qa` with 👀, and picks the checkout ref: `refs/pull/<n>/merge`, or `refs/pull/<n>/head` when the PR has merge conflicts. |
| `agent` | `contents: read`, `pull-requests: read`, `issues: read` | Checks out the chosen ref, builds with `setup-build`, writes the PR context, runs Claude, then re-runs every claimed reproduction. |
| `publish` | `contents: read`, `pull-requests: write` | Validates the findings, anchors them to the diff, applies the caps and dedup, posts one review. |
| `report-failure` | `contents: read`, `pull-requests: write` | Comments with the run link, only for `/qa` runs (someone is waiting); automatic runs just show a failed check. |

### Context

`build-context.sh` gains a `qa` phase that writes `agent-context/pr.json`: title, body, author and trust flag, base and head SHAs, changed files with their patches, linked issues, and the bodies of earlier QA reviews on the PR (for dedup). The full diff is also written to `agent-context/pr.diff`. The PR author is untrusted unless they have write access, and the same trust rules as the bug fixer apply: the PR text is data, never instructions.

### Agent instructions (summary)

1. Understand the intent from the PR description, linked issues and `docs/spec/spec.md`.
2. Check spec compliance: find the `docs/spec/spec.md` sections covering the changed behaviour and report a `spec` finding when the new behaviour contradicts them (`deviation`, needs a reproduction asserting the spec's behaviour) or when the PR changes documented behaviour, public API or configuration without updating the spec (`not-updated`, no test needed). Ambiguous spec text becomes a `question` quoting it.
3. Review the diff for behaviour: wrong conditions, unhandled cases (empty, nil, error unions, HTTP/1.1 vs HTTP/2, client vs service side), resource leaks, concurrency on isolated objects, compatibility of public API changes, and mismatches between code, tests, spec and changelog.
4. Review the tests: does each behaviour change have a test, do tests assert the behaviour rather than only absence of errors, are negative and edge cases covered?
5. For each suspected bug or spec deviation, write a reproduction test in group `qa_<pr>_<k>` (k = 1, 2, …) and run it on the PR code. Keep it only if it fails for the suspected reason.
6. Return at most 8 findings, most important first, plus a summary.

Style, naming, formatting and refactoring suggestions are out of scope and will be dropped.

### Output schema

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "findings"],
  "properties": {
    "summary": {"type": "string", "minLength": 1, "maxLength": 20000},
    "findings": {
      "type": "array",
      "maxItems": 12,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["key", "kind", "title", "body"],
        "properties": {
          "key": {"type": "string", "pattern": "^[a-z0-9-]{3,60}$"},
          "kind": {"type": "string", "enum": ["bug", "spec", "missing-test", "question"]},
          "spec_case": {"type": "string", "enum": ["deviation", "not-updated"]},
          "spec_section": {"type": "string", "maxLength": 200},
          "title": {"type": "string", "maxLength": 150},
          "body": {"type": "string", "maxLength": 8000},
          "path": {"type": "string"},
          "line": {"type": "integer", "minimum": 1},
          "side": {"type": "string", "enum": ["LEFT", "RIGHT"]},
          "repro": {
            "type": "object",
            "additionalProperties": false,
            "required": ["test_package", "group", "test_code"],
            "properties": {
              "test_package": {"type": "string"},
              "test_filter": {"type": "string"},
              "group": {"type": "string", "pattern": "^qa_[0-9]+_[0-9]+$"},
              "test_code": {"type": "string", "maxLength": 8000}
            }
          }
        }
      }
    }
  }
}
```

`key` is a stable slug for the finding (for example `sse-parser-trailing-cr`) used for dedup across runs. `repro` is required for `kind: bug` and for `kind: spec` with `spec_case: deviation`. `spec_section` names the spec heading the finding refers to.

### Reproduction verification

`.github/scripts/agent/verify-findings.py` (shared with the weekly analyser) handles a list of `(test_package, group, test_filter)` entries (the bug fixer's single-reproduction `verify-repro.sh` is left unchanged during its validation; the two can be merged later). After Claude finishes, the agent job re-runs the group of each `bug` finding and each `spec` deviation in the agent's workspace and records `reproduced`, `not-reproduced` or `not-run` per finding in `agent-output/repro.json`. Several groups in the same package run in one `bal test` invocation (`--groups qa_12_1,qa_12_2`), so verification costs one test-package run per package rather than per finding. Results are mapped back to findings through the test function names declared in each finding's `test_code`; a finding counts as reproduced only if one of its own test functions failed.

The publish job:

- keeps a `bug` or spec deviation as such only if it was `reproduced`, and appends the verified failure message and the test code (collapsed);
- turns any other `bug` or spec deviation into a `question`, prefixing the title with "Possible issue (not reproduced):" or "Possible spec deviation (not reproduced):".

`spec` findings with `spec_case: not-updated` are posted without verification, labelled "Spec not updated" and naming the stale or missing section.

The QA agent never pushes, so reproduction tests live only in the review comments; the author can copy them into the PR.

### Anchoring and caps

The publish job fetches the PR's file patches and computes, for each file, the set of commentable lines on each side. A finding is posted inline only if its `path`, `line` and `side` are commentable; otherwise it moves into the summary under "Other findings", with a file link. Then:

- Findings whose `key` already appears in an earlier QA review on this PR (as a hidden `<!-- qa:key=... -->` marker) are dropped, so `/qa` re-runs only report new points.
- At most 8 inline comments are posted, in the agent's priority order; the rest move into the summary.
- Each inline comment is formatted as `**[Bug]**`, `**[Spec deviation]**`, `**[Spec not updated]**`, `**[Missing test]**` or `**[Question]**` plus the title and body, with the marker.

Everything is posted as one review (`POST /repos/{owner}/{repo}/pulls/{n}/reviews`, `event: COMMENT`), with the summary as the review body. One review means one notification, and `COMMENT` never blocks merging. If there are no findings, the review body says so briefly ("No behavioural issues or missing tests found") with what was checked, so silence is distinguishable from failure.

### Summary format

```markdown
## QA review

**Scope:** <one line on what the PR changes, as understood>

| Verified bugs | Spec | Missing tests | Questions |
|---|---|---|---|
| 1 | 1 | 2 | 1 |

### Other findings
<findings that could not be anchored or exceeded the inline cap>

### What was checked
<areas reviewed; test commands run with results>
```

### Tool allowlist

Same as the bug fixer's investigate phase: `Read`, `Glob`, `Grep`, `Edit`, `Write` (reproduction tests and `agent-scratch/` only, by prompt), `run-tests.sh`, the build-local `bal`, read-only `git` and `gh`. No commits, no pushes, no GitHub writes.

### Limits and estimates

| Setting | Value |
|---|---|
| `timeout-minutes` (agent job) | 45 |
| `--max-turns` | 50 |
| Model | `claude-opus-5-5` |
| Inline comments | ≤ 8 per review |
| Findings returned | ≤ 12 |
| Measured | 2–5 minutes of agent job time and 10–24 turns, $0.39–0.60 per review in the PoC ([report](poc-report.md)) |

### Fork PRs upstream

The PoC repository has no forks. For upstream, the design keeps fork PRs safe by construction:

- `pull_request` from forks gets no secrets, so the gate skips fork PRs on the automatic trigger (and `agent-pr-ci.yml` skips them too); `pull_request_target` is not used.
- `/qa` runs with secrets and executes the PR's code (Gradle build scripts and tests). It therefore requires write access, and the gate refuses to run if the PR changes build logic (`**/*.gradle`, `gradle/`, `gradlew*`, `.github/`, `build-config/`) unless a maintainer adds `agent/qa-trusted` after reviewing those changes. Claude configuration (`.claude/`, `CLAUDE.md`) is restored from the base branch by the action.
- Upstream would also move `packagePAT` out of the agent's environment by pre-resolving dependencies in a separate step, so that the PR's code never sees it.

## Alternatives considered

| Alternative | Reason not chosen |
|---|---|
| Run on every `synchronize` | Doubles or triples cost on active PRs and re-reviews the same code; `/qa` covers re-review on demand. |
| Let Claude post inline comments through the action's MCP inline-comment server | Requires a write token in the agent job; anchoring, caps and dedup would rely on the prompt. |
| `REQUEST_CHANGES` for verified bugs | Would block merges on an agent's judgement; maintainers decide. |
| Separate comment per finding | One notification per finding; a single review is less noisy. |
| Push reproduction tests to the PR branch | Writes to contributors' branches; including the test in the comment is enough. |

## Risks and limitations

- False positives cost reviewer attention; the cap, the reproduction rule and dedup limit them, and the validation run measures them.
- A review of the merge ref can go stale after new pushes; the review states the head SHA it reviewed.
- Reviewing agent PRs with the same model may share blind spots with the bug fixer.
- Line anchoring depends on the diff at publish time; a push between the agent and publish jobs can move lines. The publish job re-fetches the PR and moves stale anchors into the summary if the head SHA changed.

## Validation plan

1. Run on the bug fixer's PR for issue #1 (via dispatch) and record whether findings are valid.
2. Seed a PR that introduces a real behavioural bug in an area with a test gap (for example, an off-by-one in a header or query parsing helper) together with a test that does not catch it; expect a verified bug or a missing-test finding.
3. Seed a PR that changes documented behaviour (for example, a default value or status code described in the spec) without updating `docs/spec/spec.md`, and one whose behaviour contradicts the spec; expect a `Spec not updated` finding and a verified `Spec deviation`.
4. Open a small, correct and well-tested PR and expect a short "no findings" review, to measure false positives.
5. Re-run `/qa` on the seeded PR without changes and expect no repeated findings.
6. Report per run: findings by kind, how many a maintainer judged valid, verification results, time, Actions minutes and Claude usage.
