# Phase: implement

A maintainer approved a plan. The approved plan comment (with the investigation it belongs to) is in `agent-context/approved-plan.md`; the full thread is in `agent-context/thread.json`. You are on a fresh branch from `master`.

## Steps

1. Recreate the reproduction test described in the approved plan (group `repro_<issue>`) and run it on the unmodified code. It must fail for the reported reason. Record the command and the failing output. If it does not fail, stop and return `blocked`.
2. Commit the test alone: `git add <files>` and `git commit -m "Add reproduction test for #<issue>"`.
3. Implement the fix as the plan describes. If the plan turns out to be wrong or needs a material change (different approach, different files, public API change not in the plan), stop and return `blocked` with the reason instead of improvising. Small adjustments within the plan's intent are fine; mention them in the PR body.
4. Re-run the reproduction test. It must pass.
5. Run the full test package(s) affected by the change (and `native` / `compiler-plugin` tests if you changed those modules). If tests unrelated to your change fail, decide from the failure whether your change could cause it; report unrelated failures in the PR body and do not change unrelated tests.
6. Add an entry to `changelog.md` under `## [Unreleased]` → `### Fixed` (create the headings at the top if missing) linking the issue. Update `docs/spec/spec.md` only if the plan says the behaviour contract changes.
7. Commit the fix: `git add <files>` and `git commit -m "<summary> (#<issue>)"`. Do not commit files under `agent-scratch/`, `agent-context/` or `agent-output/`, and do not commit TOML version changes.

## Output

- `status`: `done` or `blocked`.
- `blocked_reason` (for `blocked`): what you found and what the plan should change. This is posted on the issue.
- `pr_title` (for `done`): `Fix <short description>`.
- `pr_body` (for `done`), Markdown:

```markdown
## Purpose
<one paragraph: the bug and the fix; `Fixes #<issue>` is added automatically>

## Code flow and root cause
<condensed from the investigation, with permalinks>

## Fix
<what changed and why this approach; deviations from the approved plan>

## Test evidence
| Test | Before fix | After fix |
|---|---|---|
| `repro_<issue>` in `<package>` | fails: <message> | passes |

<commands run and summarized results for each test package>

## Checklist
- [x] Linked to an issue
- [x|  ] Updated the changelog
- [x] Added tests
- [x|  ] Updated the spec
- [ ] Checked native-image compatibility
- [ ] Checked the impact on OpenAPI generation
```

- `ci_tests` (for `done`): what CI should run, as entries `<package>[:<groups>]`, `native[:<filter>]` or `compiler-plugin[:<filter>]`. Usually the affected test package without groups.
