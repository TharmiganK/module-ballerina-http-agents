# Gap scanner

## Problem

The defect scanner checks the implementation against the spec, so it finds bugs and spec mistakes. It cannot find capabilities that neither the spec nor the code has: the spec only describes what exists, so a missing capability shows up only when the module is compared with something outside it. Issues such as "the retry client ignores `Retry-After`" (#20) or "no per-request deadline, and cancelling a call does not abort it" (#31) are found today only when a user hits them and reports them, usually after building a workaround.

## What it does

Once a month, the gap scanner takes two scope units from the defect scanner's catalogue (`.github/agent-prompts/defect-scanner/scopes.json`) and compares each with a fixed reference set for that unit (`.github/agent-prompts/gap-scanner/references.json`): mature HTTP libraries in other languages (for example Go `net/http`, OkHttp, Java `HttpClient`, Python `httpx`, .NET `HttpClient`, Resilience4j, Polly, Spring, ASP.NET Core) and the RFCs that apply. It files the strongest gaps as `Type/Improvement` or `Type/NewFeature` issues with an analysis and a proposal. The reference set is written down so that runs are repeatable and reviewable, and does not depend on what the model happens to recall.

A finding is kept only when the agent shows that:

- the capability is absent or unreasonably hard here, with spec and code permalinks and, for runtime behaviour, a sample showing the current behaviour or the best workaround;
- at least two reference libraries offer it, or an RFC expects it, with the concrete API named in each (the agent may read their official documentation and the RFCs; `WebFetch` is limited to an allow-list of documentation sites);
- it fits the module's design, and no issue here or upstream already asks for it or rejected it.

Each finding gets a `demand` score from 0 to 10 based on upstream issues and reactions, how commonly the capability is used elsewhere, and the RFC requirement level. The workflow files at most `GAP_MAX_ISSUES` (default 2) per run, highest demand first, and records every examined topic and its verdict (present, workaround, gap filed, already reported) in the run report.

## Design

- Workflow: `.github/workflows/agent-gap-scanner.yml` (monthly, or manual dispatch with `scope` and `dry_run`).
- Prompt and schema: `.github/agent-prompts/gap-scanner/{prompt.md,schema.json,references.json}`.
- Scripts: the defect scanner's `scanner-plan.py`, `scanner-publish.py` and `scanner-state.py`, with `SCANNER=gap`, `STATE_NAME=gap-scanner` and `REFERENCES`. Rotation and run reports live under `gap-scanner/` on the `agent-state` branch; fingerprints use the `scanner:fp=gap-<unit>/<key>` marker so the same gap is never filed twice.
- Same safety model as the other agents: the agent job is read-only and cannot file anything; it may only run samples under `agent-scratch/`; the publish job files issues deterministically. There are no reproduction tests and no security findings.
- Variables: `GAP_UNITS_PER_RUN` (default 2), `GAP_MAX_ISSUES` (default 2).

Filed issues enter the normal flow: a maintainer can add `agent/investigate` to have the issue analyser refine the proposal, or close the issue.

## Find-similar for gaps

`agent/find-similar` (`.github/workflows/agent-find-similar.yml`) also works on improvement and feature issues. The scoper agent first decides whether the seed is a `defect` or a `gap` (from the `Type/*` label and the issue analyser's classification, checked against the substance). For a gap it describes the missing capability and the design assumption behind it, and generates up to three sibling areas where users would expect the same capability (other clients or resiliency strategies, the other side of a client/service feature, other protocols), each with its own reference libraries and RFCs. The gap scanner is then dispatched with those units (`custom_scopes`, `seed`) and its prompt's find-similar section: the seed and whatever its proposal already covers are never filed again, each other occurrence must pass the usual bar, and issues link the seed. A summary comment on the seed lists what was filed (`scanner-report-seed.sh`, shared with the defect scanner). Find-similar runs never advance the monthly rotation.

For example, with #20 (the retry client ignores `Retry-After`) as the seed, the scanner checks the failover and circuit breaker clients, redirects on 503, and whether services can send `Retry-After` conveniently.

## Why a separate agent

Defect findings are verified by a failing test and have few false positives. Gap findings are judgement calls about what users need. Keeping them in a separate workflow with a lower cap and a slower cadence keeps the defect scanner's output precise, and lets maintainers tune or switch off the gap scanner on its own.

## Limits

- It finds gaps that have a counterpart in other libraries or the RFCs. Usability problems specific to Ballerina (for example data-binding ergonomics) still need user reports.
- The reference set biases what is examined; it should be reviewed when maintainers find that useful gaps are missed or that a reference does not fit.
