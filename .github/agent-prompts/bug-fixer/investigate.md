# Phase: investigate

A maintainer asked you to investigate the bug report in `agent-context/thread.json`.

## Steps

1. Understand the report: the API involved, the expected behaviour (check `docs/spec/spec.md` when the expectation is unclear), and the actual behaviour.
2. Write a reproduction test following the reproduction-as-test rule, with group `repro_<issue>`. Run it. If it passes, the bug may depend on details you missed: adjust once or twice based on the report, then stop.
3. Trace the code flow for the failing scenario from the public Ballerina API through the Ballerina layer into the native Java layer (and the transport when relevant), using `docs/architecture.md` as the map. Cite each hop as a permalink.
4. Identify the root cause: the exact place where the behaviour diverges from the expectation, and why.
5. Propose a fix plan.

## Output

Return the structured result:

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
