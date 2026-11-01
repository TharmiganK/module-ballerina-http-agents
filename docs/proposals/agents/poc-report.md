# PoC Report: Agentic GitHub Workflows for `module-ballerina-http`

_Owners_: @TharmiganK  
_Date_: 2026/11/01 (updated the same day after follow-up changes)  
_Repository_: [TharmiganK/module-ballerina-http-agents](https://github.com/TharmiganK/module-ballerina-http-agents) (public mirror of `ballerina-platform/module-ballerina-http`)

## Summary

Three agents were built on `anthropics/claude-code-action@v1` with a Claude Teams subscription token and validated end to end on real issues and PRs in the mirror:

- **[Bug fixer](bug-fixer-agent.md)**: investigates a labelled bug, reproduces it as a test, traces the root cause, proposes a versioned plan, implements the approved plan as a PR and handles review feedback.
- **[PR QA agent](qa-agent.md)**: reviews PRs for behaviour, spec compliance and test coverage, with verified reproductions for bug claims.
- **[Weekly analyser](weekly-analyser.md)**: analyses four scope units of the module in parallel each week and files verified bugs, spec issues and questions, with security findings delivered privately.

The agents' own output was consistently correct and useful: every root cause was right, every filed bug was reproduced by the workflow itself, and review findings were specific and actionable. The failures during validation were all in the workflow plumbing around the agents (permissions, a shell pipeline bug, branch/workflow-file interaction, deduplication scope), each found by a real run and fixed. The cost per agent run was $0.4–2.1 at list-price equivalents, consumed from the Teams subscription.

Recommendation: proceed to an upstream proposal for the bug fixer and the QA agent, and run the weekly analyser in the mirror for one full four-week cycle first to measure triage load and precision.

## What was built

| Component | Location |
|---|---|
| Agent knowledge | `CLAUDE.md`, `docs/architecture.md`, `.claude/settings.json` |
| Targeted test runner | `.github/scripts/run-tests.sh` (excludes unrelated suites and auto-commit tasks, clears the compiled `http` cache, `--no-scan`) |
| Issue templates and labels | `.github/ISSUE_TEMPLATE/`, `.github/scripts/setup-labels.sh` |
| Bug fixer | `.github/workflows/agent-bug-fixer.yml`, `.github/agent-prompts/bug-fixer/`, `.github/scripts/agent/{build-context.sh,publish.sh,verify-repro.sh}` |
| QA agent | `.github/workflows/agent-qa.yml`, `.github/agent-prompts/qa/`, `.github/scripts/agent/{qa-publish.py,verify-findings.py}` |
| Weekly analyser | `.github/workflows/agent-weekly-analyser.yml`, `.github/agent-prompts/analyser/`, `.github/scripts/agent/analyser-*.py`, `security-transfer.sh` |
| PR CI | `.github/workflows/agent-pr-ci.yml`, `.github/actions/setup-build/` |

Design principles shared by all agents:

- **Propose, then publish.** Claude runs with a read-only `GITHUB_TOKEN` and returns schema-validated JSON; a separate deterministic job validates it and performs every GitHub write, enforcing caps and path restrictions in code.
- **Reproduction as evidence.** Bug claims need a test that the workflow re-runs itself after the agent finishes; unverified claims are downgraded to questions or dropped.
- **On-demand, human-gated.** The bug fixer engages only through maintainer labels and `/bug-fixer` commands; it never merges, and each issue carries a single `agent/*` state label.
- **Untrusted input.** Issue and PR text from users without write access is marked untrusted; nothing from events is interpolated into shell steps.

## Validation runs

### Bug fixer

| Case | Phase | Outcome | Agent job | Claude |
|---|---|---|---|---|
| [#1](https://github.com/TharmiganK/module-ballerina-http-agents/issues/1) SSE multi-line `data` (from ballerina-library#9270, root-cause hint removed) | investigate | Correct root cause (`bytes_to_sse_stream_generator.bal:153`), reproduction verified, Plan v1 | 7 min | 21 turns, $0.61 |
| #1 | discuss | Corrected the maintainer's wrong hypothesis with evidence, added a test, posted Plan v2 | 6 min | 24 turns, $0.69 |
| #1 | implement | First run correctly returned **blocked** (found the stale compiled-cache bug in our build setup); after the fix, opened [PR #2](https://github.com/TharmiganK/module-ballerina-http-agents/pull/2) | 6 min | 23 turns, $0.52 |
| [#4](https://github.com/TharmiganK/module-ballerina-http-agents/issues/4) form-urlencoded with `charset` (from ballerina-library#7292) | investigate | Correct root cause, reproduction verified, plan with a behaviour-change risk and a narrower alternative | 3 min | 29 turns, $0.80 |
| #4 | implement | Opened [PR #9](https://github.com/TharmiganK/module-ballerina-http-agents/pull/9) (third attempt; the first two failed in the publish step, see below) | 10 min | 37 turns, $0.70 |
| PR #9 | review | Replied in both review threads, added a `Changed` changelog entry and five tests, proved six of them fail without the fix, CI green | 11 min | 25 turns, $0.76 |

### QA agent

| PR | Outcome | Agent job | Claude |
|---|---|---|---|
| [#2](https://github.com/TharmiganK/module-ballerina-http-agents/pull/2) (bug fixer PR) | One valid missing-test finding (CRLF line endings) | 5 min | 24 turns, $0.60 |
| [#3](https://github.com/TharmiganK/module-ballerina-http-agents/pull/3) (seeded: default `maxHeaderSize` raised without spec update) | Caught it as "Spec not updated" with the stale spec section, a missing upper-bound test (checked by sample), and a sound question on client/listener asymmetry | 2 min | 10 turns, $0.39 |
| [#9](https://github.com/TharmiganK/module-ballerina-http-agents/pull/9) (bug fixer PR) | Found that the new charset tests also pass without the fix, a missing status-code binding test, and the `string` binding behaviour change; all three were then addressed by the bug fixer | 63 min wall, 3.5 min of steps | 15 turns, $0.56 |

CodeRabbit is also installed on the repository and reviewed the same PRs, which gives a baseline for comparison (not evaluated in this report).

### Weekly analyser

| Run | Units | Outcome | Claude |
|---|---|---|---|
| Dry run | `sse-streaming` | Rediscovered #1 and dropped it as a duplicate; dropped five more candidates already tracked upstream (it searched upstream on its own) | 28 turns, $1.19 |
| Real run | `sse-streaming` | Filed [#5](https://github.com/TharmiganK/module-ballerina-http-agents/issues/5), [#6](https://github.com/TharmiganK/module-ballerina-http-agents/issues/6), [#7](https://github.com/TharmiganK/module-ballerina-http-agents/issues/7) (bugs, all reproduced) and [#8](https://github.com/TharmiganK/module-ballerina-http-agents/issues/8) (spec). #6 and #8 are new; #5 duplicates ballerina-library#9269 and #7 is fixed by open PR module-ballerina-http#2752, which led to the upstream dedup fix | 53 turns, $1.61 |
| Parallel dry run | `listener`, `service-dispatching`, `service-parameter-binding`, `service-response` | 12 findings across four units in 9 minutes wall time (6 would be filed under the then cap of 6; the cap is now 32), each unit with upstream searches recorded | 41–59 turns and $1.41–2.14 per unit |

## Problems found and fixed

All of these were found by real runs; none came from the agents' reasoning.

| Problem | Effect | Fix |
|---|---|---|
| Targeted Gradle runs pulled in all suites; `commitTomlFiles` auto-committed | Slow and unsafe test runs | `run-tests.sh` excludes those tasks |
| `bal` reuses a compiled `http` jar while the version is unchanged | Before/after testing ran stale code; the bug fixer correctly blocked | `run-tests.sh` clears `target/ballerina-runtime/repo/cache/ballerina/http` |
| `contents: read` missing on publish jobs | Checkout failed in the private repository | Permissions added |
| "Allow GitHub Actions to create pull requests" disabled | PR creation refused after a successful push | Repository setting changed; leftover agent branches are now replaced automatically |
| `git diff \| grep -q` under `pipefail` | Valid patches with `repro_<n>` tests rejected (SIGPIPE) | Diff captured before matching |
| `master` changed workflow files during an implement run | `GITHUB_TOKEN` push rejected as a workflow update | Patches are applied on the current `master` |
| Dedup only against this repository | Two analyser issues duplicated upstream reports | `UPSTREAM_ISSUE_REPOS` / `UPSTREAM_CODE_REPO` and mandatory upstream searches |
| Discuss phase could not create the first plan; reproduction claims not verified | Gaps in the evidence rule | `new_plan_version: 1` allowed; `verify-repro.sh` / `verify-findings.py` re-run reproductions |
| Cosmetic: table rendering, escaped newlines, Claude Code attribution line | Noisy posts | Fixed in the publish scripts |

## Changes after the initial validation

Maintainer feedback on the validated agents led to these changes, each reflected in the design documents:

| Change | Why | Status |
|---|---|---|
| Bug fixer engages only on demand: labels for investigate and implement, a `/bug-fixer` command (first word of an issue comment, PR comment or review body) for discussion and review handling | Every maintainer comment previously started a run | Implemented |
| A single `agent/*` state label per issue; `agent/investigate` and `agent/approved` are triggers consumed when the run starts | Issues accumulated several agent labels | Implemented; issues #1 and #4 cleaned up |
| The bug fixer answers and resolves the QA agent's review threads (never third-party bot threads); replies carry `resolve` | On PR #9 the QA findings were fixed in code but their threads stayed open | Implemented |
| `agent/auto-fix` on an agent PR: after reviewers are quiet for 10 minutes (each new comment restarts the wait), one bug fixer round addresses all open maintainer and QA threads; at most 3 automatic rounds | Hands-off handling of review bursts in continuous PR work | Implemented; first test on PR #9 in progress |
| `agent/find-similar` on an issue or PR: a scoper agent derives the defect pattern and 1–3 scope units, and the analyser hunts for other occurrences with verified reproductions | Find the same mistake elsewhere once one instance is known | Implemented; first test with PR #9 as the seed in progress |
| Weekly analyser runs 4 scope units in parallel with a per-run issue cap (`ANALYSER_MAX_ISSUES`, set to 32) | One unit per week meant a four-month cycle and findings over the cap were lost | Implemented; parallel dry run validated |
| `agent/investigate` analyses any issue: it classifies it as a bug (reproduction and plan), an improvement or feature (analysis and proposal, `agent/analysed`) or a question (answer), and adds the matching `Type/*` label when none is set | Unlabelled issues needed triage before the bug fixer could be used | Implemented; validated on #20 (classified as an improvement with a proposal) |
| An issue that mixes independent bugs, improvements or features is split into linked sub-issues (`agent/split`), and each sub-issue is investigated on its own | Mixed issues cannot be planned or closed as one unit | Implemented; validation pending |
| Bug fixer review rounds post all thread replies and the summary as one review; escaped `\n` in agent text is unescaped; find-similar comments name areas instead of scope unit ids and link the run report | PR #9 showed literal `\n` in a summary, one empty "reviewed" timeline entry per reply, and a vague report path | Implemented |
| The repository is public; security findings are encrypted between jobs and delivered as draft security advisories | Free runner minutes and the same security channel as upstream | Implemented; advisory delivery not yet exercised |

Two workflow-trigger problems surfaced while adding these and were fixed: GitHub runs `pull_request`-type workflows from the PR's test-merge commit, which can predate a new workflow (label triggers now use `pull_request_target`, which never checks out PR code), and workflow-level concurrency let unrelated events cancel the auto-fix wait (moved to job level). `pull_request_review` has no `_target` variant and also runs from the test-merge commit, which GitHub does not refresh when the base branch moves: on PR #9 a `/bug-fixer` review ran workflow code 11 commits old. Review events now only relay to a `workflow_dispatch` run (bug fixer: `pr` and `review_id`; auto-fix: `pr`), which always uses the default branch's workflow.

## Cost and time

- **Claude usage**: $0.4–0.8 per bug fixer or QA run, $1.2–2.1 per analyser unit, at list-price equivalents, consumed from the Teams subscription. A weekly analyser run with four units is about $6–7; a typical bug from investigation to merged-ready PR (investigate, one discussion, implement, one review round) is about $3.
- **Wall time**: 3–11 minutes per bug fixer or QA run; about 10 minutes for a four-unit analyser run in parallel.
- **Actions minutes**: free on the now-public repository for standard runners. Runner minutes were not totalled while the repository was private; the agent jobs above plus the gate, publish and CI jobs are the main consumers.
- Measured costs are far below the design estimates (45–90 minutes per analyser run), mainly because targeted test runs are fast once the build cache is warm.

## Open items

- **Security advisory delivery** is implemented (encrypted hand-off between jobs, draft advisory per finding) but untested end to end: the real analyser runs produced no security findings. Validate with one seeded vulnerability or the next real finding.
- **Auto-fix and find-similar** were implemented after the initial validation; their first runs on PR #9 were in progress when this report was updated.
- **QA job wall time anomaly** on PR #9: 63 minutes of job time against 3.5 minutes of step time; to be investigated if it recurs.
- **Bot-authored PR runs** show `action_required` for `pull_request` workflows; harmless (no minutes used), but noisy in the Actions list.
- **Cross-unit dedup** in the analyser relies on unit boundaries; the same defect described differently by two units is not caught.
- **`verify-repro.sh` and `verify-findings.py`** should be merged.
- **Issues #5 and #7** should be closed as duplicates of the upstream reports; **PR #3** (seeded) should be closed; **PRs #2 and #9** are ready for human review.

## Recommendations for upstream

1. **Authentication**: an organisation API key or workload identity federation instead of a personal subscription token. That also makes GitHub Agentic Workflows (`gh-aw`) an option, with built-in safe outputs and a network firewall; compare it against this design before choosing.
2. **Cross-repository operation**: issues live in `ballerina-platform/ballerina-library` while code lives in `module-ballerina-http`. Use a GitHub App token, issued only to the publish jobs, for cross-repository writes; agent jobs keep read-only tokens.
3. **Security**: switch `SECURITY_CHANNEL` to `advisory` (draft repository security advisories), keep the encrypted transfer, and keep `show_full_output` and `display_report` off.
4. **Rollout order**: bug fixer first (on demand, lowest risk), QA agent next (automatic on maintainer PRs, `/qa` for forks with the `agent/qa-trusted` guard), weekly analyser last after a full cycle in the mirror shows acceptable precision and triage load.
5. **Measure** for the first month upstream: maintainer-judged precision of filed issues and review comments, time from label to PR, number of human interventions per bug, and Claude usage per week.
