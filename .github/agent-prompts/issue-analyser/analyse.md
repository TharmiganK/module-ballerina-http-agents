# Issue analyser, phase: analyse

A maintainer asked you to analyse the issue in `agent-context/thread.json`. First decide what kind of issue it is, then handle it accordingly.

## Step 0: look for duplicates

Before anything else, check whether the issue is already reported. `agent-context/issues.json` lists this repository's recent issues (open and closed; title, state, labels, the start of the body). Also search upstream with `gh api "search/issues?q=repo:ballerina-platform/ballerina-library+label:module/http+<keywords>"` (two or three keyword sets that describe the symptom, not the reporter's wording). Open the likely candidates with `gh issue view`.

- Same problem with the same cause, or the same request, in an existing issue: suggest closing as a `duplicate` (see "If it should be closed") without reproducing it. Keep the older issue unless this one is clearly better described; then say so and still name the older one in `duplicate_of`. If the earlier issue has a fix PR or plan, mention it.
- An earlier issue was fixed and closed, and this one reports the same behaviour again: this is a possible regression, not a duplicate. Handle it as a bug and link the earlier issue.
- Related but different (same area, different cause or request): continue, and link it in your comment.

## Step 1: classify

Decide `classification`:

- `bug`: the module does not behave as documented or as users can reasonably expect from its API and the spec (wrong result, error, crash, hang, leak, inconsistency).
- `improvement`: existing functionality works as designed but could be better (usability, performance, configurability, error messages, missing option on an existing feature).
- `feature`: new functionality that does not exist yet.
- `question`: the reporter asks how something works or how to do something, and nothing is broken.

- `mixed`: the issue asks for two or more independent things that would be fixed, decided or released separately, for example a bug plus an unrelated feature request, or two unrelated bugs. See "If it covers several things" below.

An issue that was split from another issue (it starts with _Split from #…_) is never `mixed`. Do not call an issue `mixed` just because the reporter suggests how to fix it, mentions a workaround, or the fix naturally touches a second area: one change that resolves the report is one issue.

If the issue already has a `Type/*` label set by a maintainer (`labels` in the context), follow it unless it is clearly wrong; if you disagree, keep their classification and explain your view in a short `> [!NOTE]` at the top of the comment. When behaviour contradicts the spec or the API docs, it is a `bug` even if the reporter calls it a feature request. When in doubt between `bug` and `improvement`, try to reproduce: a failing test against documented behaviour makes it a bug.

## If it is a bug

1. Understand the report: the API involved, the expected behaviour (check `docs/spec/spec.md` when the expectation is unclear), and the actual behaviour.
2. Write a reproduction test following the reproduction-as-test rule, with group `repro_<issue>`. Run it. If it passes, the bug may depend on details you missed: adjust once or twice based on the report, then stop.
3. Trace the code flow for the failing scenario from the public Ballerina API through the Ballerina layer into the native Java layer (and the transport when relevant), using `docs/architecture.md` as the map. Cite each hop as a permalink.
4. Identify the root cause: the exact place where the behaviour diverges from the expectation, and why.
5. Propose a fix plan.

Output:

- `classification`: `bug`.
- `outcome`: `plan-ready` if the reproduction fails for the reported reason and you have a root cause and plan; otherwise `needs-info`.
- `test_package`: the directory name of the Ballerina test package holding the reproduction (for example `http-client-tests`), or `native` / `compiler-plugin` for a Java reproduction.
- `test_filter`: for a Java reproduction only, the fully qualified test class name.

After you finish, the workflow re-runs group `repro_<issue>` in `test_package` itself. Leave the reproduction test and its port constant in place: do not delete or revert them. The plan is only published as approvable if that re-run fails; otherwise the report is posted as unverified.

- `comment`: the Markdown comment to post on the issue, with these sections:

```markdown
## Investigation

**Verdict:** <Reproduced | Not reproduced> — <one sentence>

### Reproduction
<file path, group, and the command>
<details><summary>Test code</summary>

<the full test code you added, including the port constant>
</details>
<details><summary>Output</summary>

<the relevant failing output>
</details>

### Code flow
<numbered hops from the public API to the failure point, each with a permalink and one line of explanation>

### Root cause
<what is wrong and why>

## Plan v1
<numbered steps: files and functions to change, and how>

**Tests:** <the reproduction test becomes the regression test; other tests to add; test packages and groups to run>

**Risks:** <behaviour changes, compatibility, spec or changelog impact>

**Confidence:** <high | medium | low> — <why>

**Size:** <simple | normal> — <one line>
```

- `simple`: `true` only when all of these hold: the fix touches one or two files outside tests, about 30 changed lines or fewer outside tests and the changelog, no public API, spec or configuration change and no behaviour change beyond the bug itself, and your confidence is high. `simple_reason`: one line on why. Otherwise `false`. The workflow labels the issue `agent/simple` and checks the real change size again when the PR is opened.

For `needs-info`, replace the Code flow, Root cause and Plan sections with `### What I tried` and `### Information needed` (specific questions), and do not include a plan.

## If it is an improvement or a feature

Do not write code or tests in the repository; samples under `agent-scratch/` are fine to check current behaviour. Analyse:

1. What the reporter needs (the use case), separately from the solution they suggested.
2. How the module behaves today: the relevant API, spec sections and implementation, with permalinks; whether a workaround exists.
3. Prior art: related or duplicate issues and proposals here and upstream (`docs/proposals/`, `ballerina-platform/ballerina-library` issues).
4. A proposal that fits the module's design: the public API (Ballerina signatures or configuration records), behaviour on both client and service side and on HTTP/1.1 and HTTP/2 where relevant, where it would be implemented (Ballerina or native layer), compatibility, spec and changelog impact, and the tests it would need.
5. Alternatives considered, and open questions for maintainers.

Output: `classification`: `improvement` or `feature`; `outcome`: `analysed`; `comment`:

```markdown
## Analysis

**Classification:** <Improvement | New feature> — <one sentence>

### Use case
### Current behaviour
<with permalinks; workaround if any>
### Related work
<issues, proposals, upstream; or "None found">

## Proposal
### API
<signatures or configuration, in a ballerina code block>
### Behaviour
### Implementation
<layers and files involved, rough size>
### Compatibility and spec impact
### Tests

**Alternatives considered:** …

**Open questions:** …
```

Do not write a `## Plan v` heading for these: implementation of proposals is decided by maintainers.

## If it covers several things

Do not investigate or reproduce anything in this run, and do not write code or tests. Split the issue instead; the workflow opens one sub-issue per part, links each to this issue and starts a separate investigation on each, so bugs get a verified reproduction and plan, and improvements and features get an analysis and proposal.

Output: `classification`: `mixed`; `outcome`: `split`; `parts`: 2 to 5 entries, each with:

- `classification`: `bug`, `improvement` or `feature`.
- `title`: a specific issue title for that part alone.
- `body`: a self-contained issue description for that part: the reporter's words, code samples, versions and environment that concern it (quote them, do not paraphrase code), and what is expected. A reader must not need the parent issue to understand it. Do not add a link to the parent; the workflow adds it.

`comment`: a short note for the parent issue:

```markdown
## Split

This issue asks for <n> separate things, so I split it into sub-issues that can be investigated and closed independently:

| Part | Type | Why separate |
|---|---|---|
| <title> | Bug / Improvement / New feature | <one line> |
```

Do not list issue numbers; the workflow adds them.

## If it should be closed

Suggest closing only when the evidence is clear; you never close issues, a maintainer approves or rejects your suggestion. Use any classification above, `outcome`: `close-suggested`, and `close_reason`:

- `duplicate`: another issue already covers the same problem or request (open or closed, here or upstream). Set `duplicate_of` to `#<n>` or `owner/repo#<n>` and say what the two have in common. Same symptom with a different cause is not a duplicate.
- `not-a-bug`: the behaviour matches the spec and API docs. Quote the section and show the current behaviour (a sample run or test). If the docs are unclear or users keep hitting it, it is a documentation improvement instead, not a close.
- `out-of-scope`: it belongs to another component (the Ballerina language or runtime, another stdlib module, a tool). Name where it should go.
- `invalid`: there is nothing actionable (no description, spam, a support request with no question about this module).
- `cannot-reproduce` is for the discuss phase only, after the reporter answered your `needs-info` questions and the bug still does not reproduce.

Never suggest closing an improvement or feature because you disagree with it; analyse it and put your concerns under open questions. `comment`: start with `## Suggest closing`, then the reason and the evidence with permalinks. The workflow adds the instructions for maintainers.

## If it is a question

Answer it directly and correctly, citing the spec and the code with permalinks, with a short working example where useful (check it with `target/ballerina-runtime/bin/bal run agent-scratch/<file>.bal`). If the question reveals a bug, a missing feature or a documentation gap, say so and suggest the follow-up issue.

Output: `classification`: `question`; `outcome`: `analysed`; `comment` starting with `## Answer`.
