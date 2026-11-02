# AI agents for `module-ballerina-http`

GitHub Actions agents built on `anthropics/claude-code-action@v1`. Each agent proposes with a read-only token and a deterministic publish job performs every GitHub write. Results from the PoC are in the [PoC report](poc-report.md).

## Agents

| Agent | What it does | How a maintainer triggers it | Output | Workflow | Design |
|---|---|---|---|---|---|
| Issue analyser | Classifies an issue; reproduces a bug and posts a verified fix plan; writes an analysis and proposal for an improvement or feature; answers a question; splits a mixed issue into sub-issues; discusses its plan or proposal | Label `agent/investigate` on an issue; `/agent <message>` comment on the issue | One issue comment per run (versioned `Plan vN` for bugs), a state label, a `Type/*` label if none is set, sub-issues for a split | `.github/workflows/agent-issue-analyser.yml` | [issue-agents.md](issue-agents.md) |
| Bug fixer | Implements an approved plan and opens the fix PR; addresses review feedback on its PRs | Label `agent/approved` on a `agent/plan-ready` issue; `/agent` comment or review on the agent PR; label `agent/auto-fix` on the PR for automatic rounds | A PR on `agent/issue-<n>` with the reproduction as a regression test; review replies, resolved threads and pushes | `.github/workflows/agent-bug-fixer.yml` (with `agent-auto-fix.yml`) | [issue-agents.md](issue-agents.md) |
| QA agent | Reviews a PR for behaviour, spec compliance and test coverage, with verified reproductions for bug claims | Automatic when a same-repository PR is opened and when the bug fixer opens a PR; `/qa` comment on a PR (also for fork PRs) | One PR review with inline findings | `.github/workflows/agent-qa.yml` | [qa-agent.md](qa-agent.md) |
| Defect scanner | Weekly scan of rotating scope units for bugs, spec problems and security issues; find-similar search for other occurrences of a known defect | Runs weekly (or manual dispatch); label `agent/find-similar` on an issue or PR | Verified, deduplicated issues; security findings as draft advisories; a run report on the `agent-state` branch | `.github/workflows/agent-defect-scanner.yml`, `.github/workflows/agent-find-similar.yml` | [defect-scanner.md](defect-scanner.md) |
| Gap scanner | Monthly comparison of rotating scope units with established HTTP libraries in other languages and the RFCs, for missing capabilities and usability gaps | Runs monthly (or manual dispatch); label `agent/find-similar` on an improvement or feature issue | At most two `Type/Improvement` / `Type/NewFeature` issues per run with evidence, demand and a proposal; a run report on the `agent-state` branch | `.github/workflows/agent-gap-scanner.yml` | [gap-scanner.md](gap-scanner.md) |

The issue analyser and the bug fixer share one label state machine, the prompt preamble `.github/agent-prompts/issue-common.md` and the reusable workflow `.github/workflows/agent-issue-run.yml`.

## Labels and commands

Maintainer triggers:

- `agent/investigate`: on an issue, start or restart the issue analyser.
- `agent/approved`: on an `agent/plan-ready` issue, have the bug fixer implement the latest plan; on an `agent/close-suggested` issue, close it with the reason the issue analyser suggested.
- `agent/auto-fix`: on an agent PR, let the bug fixer address review feedback once reviewers have been quiet for a while.
- `agent/find-similar`: on an issue or PR, search for the same problem elsewhere: the defect scanner for a bug, the gap scanner for an improvement or feature request.
- `/agent <message>`: first word of an issue comment (issue analyser discusses its plan or proposal) or of an agent PR comment or review body (bug fixer addresses the feedback).
- `/qa`: first word of a PR comment, request a QA review.

State labels, one per issue, set by the agents: `agent/investigating`, `agent/plan-ready`, `agent/needs-info`, `agent/analysed`, `agent/close-suggested`, `agent/split`, `agent/implementing`, `agent/pr-open`, `agent/fixed`, `agent/failed`. `agent/generated` marks issues and PRs that an agent created. `agent/simple` marks a small, low-risk fix: estimated by the issue analyser on the issue, then measured on the PR (at most 2 files and 30 lines outside tests, no spec change). `agent-lifecycle.yml` (no agent) keeps these labels right when a PR is merged, closed or reopened, when an issue is closed or reopened, and closes a split parent once all its sub-issues are closed.

## How they connect

A maintainer adds `agent/investigate` to an issue. The issue analyser classifies it: a bug gets a reproduction and a plan (`agent/plan-ready`), an improvement or feature gets a proposal and a question an answer (`agent/analysed`), and a mixed issue is split into sub-issues that are each analysed. The maintainer refines the plan with `/agent` comments, then adds `agent/approved`; the bug fixer implements the plan and opens a PR, which gets CI and an automatic QA agent review. The bug fixer addresses QA and maintainer feedback through `/agent` (or `agent/auto-fix`), and a maintainer merges; the issue then carries `agent/fixed`. When an issue should not be worked on (duplicate, not a bug, out of scope, invalid), the issue analyser suggests closing it and a maintainer confirms with `agent/approved`. The defect scanner files verified issues that enter the same flow through `agent/investigate`, and once a bug is fixed, `agent/find-similar` on its issue or PR asks the defect scanner to look for the same mistake elsewhere. The gap scanner files improvement and feature issues for capabilities the module lacks compared with other libraries; they enter the same flow. The two scanners pass what they notice outside their own remit to each other automatically: a suspected bug noticed by the gap scanner becomes a defect scanner run that tries to reproduce it, and a missing capability noticed by the defect scanner becomes a gap scanner run.
