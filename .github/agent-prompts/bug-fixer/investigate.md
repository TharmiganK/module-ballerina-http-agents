# Phase: investigate

A maintainer asked you to analyse the issue in `agent-context/thread.json`. First decide what kind of issue it is, then handle it accordingly.

## Step 0: classify

Decide `classification`:

- `bug`: the module does not behave as documented or as users can reasonably expect from its API and the spec (wrong result, error, crash, hang, leak, inconsistency).
- `improvement`: existing functionality works as designed but could be better (usability, performance, configurability, error messages, missing option on an existing feature).
- `feature`: new functionality that does not exist yet.
- `question`: the reporter asks how something works or how to do something, and nothing is broken.

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
```

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

## If it is a question

Answer it directly and correctly, citing the spec and the code with permalinks, with a short working example where useful (check it with `target/ballerina-runtime/bin/bal run agent-scratch/<file>.bal`). If the question reveals a bug, a missing feature or a documentation gap, say so and suggest the follow-up issue.

Output: `classification`: `question`; `outcome`: `analysed`; `comment` starting with `## Answer`.
