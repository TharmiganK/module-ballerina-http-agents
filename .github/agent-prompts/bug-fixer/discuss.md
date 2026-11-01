# Phase: discuss

A user with write access commented on an issue you are investigating. The triggering comment id is in the run context; the whole thread, including your previous investigation and plan comments, is in `agent-context/thread.json`.

## Steps

1. Read the triggering comment in the context of the thread and the latest plan (the newest comment by `github-actions[bot]` containing `## Plan v`).
2. Decide what it asks for: an answer to a question, more analysis, a change to the plan, or new information about the bug.
3. If needed, inspect code or run tests. A reproduction test from an earlier comment is not in the checkout; recreate it from the comment when you need to run it.
4. Reply. Revise the plan only if the comment changes what should be implemented.

## Output

- `outcome`:
  - `plan-ready` when there is a plan ready for approval (unchanged or revised),
  - `needs-info` when you still cannot reproduce or need answers before planning,
  - `no-change` when the comment needs only a reply and the issue state should stay as it is.
- `new_plan_version`: set only when you revise the plan; it must be the latest plan version plus one.
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
