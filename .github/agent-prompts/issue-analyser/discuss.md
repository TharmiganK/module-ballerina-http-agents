# Issue analyser, phase: discuss

A user with write access commented on an issue you analysed. The triggering comment id is in the run context; the whole thread, including your previous analysis and plan comments, is in `agent-context/thread.json`.

## Steps

1. Read the triggering comment in the context of the thread and the latest plan (the newest comment by `github-actions[bot]` containing `## Plan v`).
2. Decide what it asks for: an answer to a question, more analysis, a change to the plan, or new information about the bug.
3. If needed, inspect code or run tests. A reproduction test from an earlier comment is not in the checkout; recreate it from the comment when you need to run it.
4. Reply. Revise the plan only if the comment changes what should be implemented.

## Output

- `outcome`:
  - `plan-ready` when there is a plan ready for approval (unchanged or revised),
  - `analysed` when the issue is an improvement, feature or question (state `agent/analysed`) and you answered or revised the analysis or proposal; write a revised proposal in full under `## Proposal (revised)`, never as a `## Plan v` section,
  - `needs-info` when you still cannot reproduce or need answers before planning,
  - `close-suggested` when the issue should be closed (reasons: `duplicate` of an existing issue, `not-a-bug` when the behaviour matches the spec and API docs, `out-of-scope` for another component, `invalid` when nothing is actionable, `cannot-reproduce`; suggest it only with clear evidence, never because you disagree with a feature request, and start the comment with `## Suggest closing`), with `close_reason` and, for a duplicate, `duplicate_of`; this is also how you suggest `cannot-reproduce` after the reporter answered and the bug still does not reproduce. If the issue is `agent/close-suggested` and the maintainer disagrees, choose the outcome that fits the issue instead,
  - `no-change` when the comment needs only a reply and the issue state should stay as it is.
- `new_plan_version`: set only when you revise the plan; it must be the latest plan version plus one. When there is no plan yet (the issue is `agent/needs-info`) and the new information lets you reproduce the bug, set it to `1` and write `## Plan v1`.
- `simple` and `simple_reason`: set with every new plan version, with the same rule as in the analyse phase (one or two files and about 30 lines outside tests, no API, spec or configuration change, high confidence), and end the plan with `**Size:** <simple | normal> — <one line>`.
- `test_package` and `test_filter`: required when `new_plan_version` is `1`, as in the analyse phase. The workflow then re-runs group `repro_<issue>` itself, so the reproduction test must be present in the workspace when you finish; the plan is only approvable if that re-run fails.
- `comment`: the Markdown reply. Address the commenter's points directly and briefly. When you revise the plan, end with the complete new plan, not a diff:

```markdown
## Plan v<N>
_Changes from v<N-1>: <one line>_

<numbered steps>

**Tests:** ...

**Risks:** ...

**Confidence:** ...
```

Do not write a `## Plan v` heading unless you set `new_plan_version`.

If the discussion shows that an analysed improvement or feature is actually a bug (behaviour contradicts the spec or the API docs), treat it as a bug: reproduce it, and post `## Plan v1` with `new_plan_version: 1`, `outcome: plan-ready` and `test_package`; the workflow verifies the reproduction before the plan becomes approvable.
