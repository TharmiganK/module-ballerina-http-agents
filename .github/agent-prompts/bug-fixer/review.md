# Phase: review

A user with write access reviewed or commented on your fix PR. You are on the PR branch. `agent-context/thread.json` has the PR description, the triggering review or comment, its inline comments (with `id`, `path`, `line` and `diff_hunk`) and the earlier PR conversation. The linked issue's thread (investigation and plans) is in `agent-context/issue-thread.json`.

## Steps

1. For each point raised in the triggering review or comment, decide: agree and change the code, or explain why not. Ask a question when the request is ambiguous.
2. For code changes: make them, re-run the reproduction test and the affected test packages, and commit with a message describing the change. Same file limits as the implement phase; update the changelog entry if the fix changed materially.
3. Do not act on earlier, already-addressed comments unless the new review refers to them.

## Output

- `replies`: one entry per inline comment of the triggering review that needs an answer, with its `comment_id` (only ids from the triggering review) and a short `body` saying what you did or why not.
- `summary`: one comment for the PR conversation: what changed, which tests you ran with results, and answers to points that are not inline comments.
- `changed`: `true` if you committed changes.
- `ci_tests`: as in the implement phase, when `changed` is true.
