#!/usr/bin/env bash
# Deterministic publish step for the bug fixer agent: validates the agent's structured output and patch,
# enforces the caps, then writes to GitHub. The agent itself never holds a write token.
#
# Usage: publish.sh <investigate|discuss|implement|review|fail>
# Env: REPO, NUMBER, RUN_URL, GH_TOKEN; agent-output/{result.json,meta.json,changes.patch} from the agent job.
# For fail: FAILED_PHASE.
set -euo pipefail

MODE="${1:?usage: publish.sh <phase|fail>}"
: "${REPO:?}" "${NUMBER:?}" "${RUN_URL:?}"
RESULT=agent-output/result.json
META=agent-output/meta.json
PATCH=agent-output/changes.patch
REPRO=agent-output/repro.json
BOT=github-actions[bot]
MAX_FILES=25
MAX_LINES=1500
FORBIDDEN='^(\.github/|\.claude/|CLAUDE\.md$|docs/proposals/|gradle/|gradle\.properties$|settings\.gradle$|(.*/)?build\.gradle$|gradlew)'

die() { echo "::error::$*"; exit 1; }
field() { jq -r "$1 // empty" "$RESULT"; }
urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

add_labels() {
  local args=()
  for l in "$@"; do args+=(-f "labels[]=$l"); done
  gh api "repos/$REPO/issues/$NUMBER/labels" "${args[@]}" > /dev/null
}

remove_labels() {
  for l in "$@"; do
    gh api -X DELETE "repos/$REPO/issues/$NUMBER/labels/$(urlencode "$l")" > /dev/null 2>&1 || true
  done
}

# Agent text must not forge the markers the workflow relies on.
strip_markers() { perl -0pe 's/<!--\s*(bug-fixer|ci-tests):.*?-->//gs'; }

footer() { printf '\n\n---\n<sub>Posted by the bug fixer agent · [workflow run](%s)</sub>\n' "$RUN_URL"; }

post_issue_comment() {
  gh api "repos/$REPO/issues/$1/comments" -F body=@"$2" > /dev/null
}

latest_plan_version() {
  gh api --paginate "repos/$REPO/issues/$NUMBER/comments" \
    --jq ".[] | select(.user.login == \"$BOT\") | .body" \
    | grep -oE '<!-- bug-fixer:plan v=[0-9]+ -->' | grep -oE '[0-9]+' | sort -n | tail -n 1 || true
}

require_result() {
  [[ -s "$RESULT" ]] || die "Agent produced no structured output"
  jq -e 'type == "object"' "$RESULT" > /dev/null || die "Structured output is not a JSON object"
}

# Validates ci_tests entries; prints the accepted ones space-separated.
ci_tests() {
  local accepted=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^([a-z0-9-]+)(:[A-Za-z0-9_.*,]+)?$ ]] || die "Invalid ci_tests entry: $entry"
    local pkg="${BASH_REMATCH[1]}"
    if [[ "$pkg" != native && "$pkg" != compiler-plugin && ! -d "ballerina-tests/$pkg" ]]; then
      die "Unknown test package in ci_tests: $pkg"
    fi
    accepted+=("$entry")
  done < <(jq -r '.ci_tests // [] | .[]' "$RESULT")
  echo "${accepted[*]:-}"
}

# Applies the agent patch on top of $1 and validates the resulting diff.
apply_patch() {
  local base="$1" require_repro="$2"
  [[ -s "$PATCH" ]] || die "Agent reported changes but produced no patch"
  git config user.name "$BOT"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git am --3way --keep-non-patch < "$PATCH" || die "Agent patch does not apply"

  local files lines bad
  files=$(git diff --name-only "$base"..HEAD)
  [[ -n "$files" ]] || die "Agent patch is empty"
  bad=$(grep -E "$FORBIDDEN" <<< "$files" || true)
  [[ -z "$bad" ]] || die "Agent patch modifies protected paths: $(tr '\n' ' ' <<< "$bad")"
  (( $(wc -l <<< "$files") <= MAX_FILES )) || die "Agent patch changes more than $MAX_FILES files"
  lines=$(git diff --numstat "$base"..HEAD | awk '{s += $1 + $2} END {print s + 0}')
  (( lines <= MAX_LINES )) || die "Agent patch changes $lines lines (max $MAX_LINES)"
  if [[ "$require_repro" == true ]]; then
    git diff "$base"..HEAD | grep -qE "^\+.*repro_${ISSUE}\b" \
      || die "Agent patch does not add a test in group repro_${ISSUE}"
  fi
  echo "Patch OK: $(wc -l <<< "$files") files, $lines lines"
}

# A first plan is only published when the workflow's own re-run of repro_<issue> failed (verify-repro.sh).
# Returns 0 and appends the verification note, or returns 1 after rewriting comment.md as an unverified,
# unapprovable report.
verify_repro() {
  local status reason command total failed message
  if [[ -s "$REPRO" ]]; then
    status=$(jq -r .status "$REPRO") reason=$(jq -r .reason "$REPRO") command=$(jq -r .command "$REPRO")
    total=$(jq -r .total "$REPRO") failed=$(jq -r .failed "$REPRO") message=$(jq -r .message "$REPRO")
  else
    status=not-run reason="The verification step produced no result"
  fi
  if [[ "$status" == reproduced ]]; then
    {
      printf '\n\n> [!NOTE]\n> **Reproduction verified by the workflow:** `%s` → %s of %s test(s) failed.\n' "$command" "$failed" "$total"
      [[ -n "$message" ]] && printf '>\n> ````text\n%s\n> ````\n' "$(sed 's/^/> /' <<< "$message")"
    } >> comment.md
    return 0
  fi
  local original
  original=$(sed -E 's/^(#+) *Plan v([0-9]+)/\1 Proposed plan (unverified) v\2/' comment.md)
  {
    echo "## Investigation (unverified)"
    echo
    printf 'The agent reported a reproduction, but the workflow could not confirm it: **%s** (%s).' "$reason" "${command:-no command}"
    echo " This issue is not treated as a confirmed bug and the plan below cannot be approved."
    echo "A maintainer can comment with more details or guidance for another attempt."
    echo
    echo "<details><summary>Agent report</summary>"
    echo
    echo "$original"
    echo
    echo "</details>"
  } > comment.md
  return 1
}

dispatch_ci() {
  gh workflow run agent-pr-ci.yml --repo "$REPO" --ref "$1" -f pr="$2"
}

case "$MODE" in
  investigate)
    require_result
    outcome=$(field .outcome)
    [[ "$outcome" == plan-ready || "$outcome" == needs-info ]] || die "Invalid outcome: $outcome"
    field .comment | strip_markers > comment.md
    [[ -s comment.md ]] || die "Empty comment"
    if [[ "$outcome" == plan-ready ]]; then
      grep -q '^## Plan v1' comment.md || die "plan-ready output has no '## Plan v1' section"
      if verify_repro; then
        printf '\n<!-- bug-fixer:plan v=1 -->' >> comment.md
      else
        outcome=needs-info
      fi
    elif grep -q '^## Plan v' comment.md; then
      die "needs-info output must not contain a plan"
    fi
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    remove_labels agent/investigating agent/plan-ready agent/needs-info agent/failed
    add_labels "agent/$outcome"
    ;;

  discuss)
    require_result
    outcome=$(field .outcome)
    [[ "$outcome" =~ ^(plan-ready|needs-info|no-change)$ ]] || die "Invalid outcome: $outcome"
    field .comment | strip_markers > comment.md
    [[ -s comment.md ]] || die "Empty comment"
    current=$(latest_plan_version)
    current=${current:-0}
    new=$(field .new_plan_version)
    if [[ -n "$new" ]]; then
      (( new == current + 1 )) || die "new_plan_version $new does not follow the latest plan v$current"
      grep -q "^## Plan v$new" comment.md || die "Revised plan has no '## Plan v$new' section"
      if (( new > 1 )) || verify_repro; then
        printf '\n<!-- bug-fixer:plan v=%s -->' "$new" >> comment.md
      else
        outcome=needs-info
      fi
    else
      ! grep -q '^## Plan v' comment.md || die "Comment contains a plan but new_plan_version is not set"
      [[ "$outcome" != plan-ready || "$current" -gt 0 ]] || die "plan-ready without any plan"
    fi
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    if [[ "$outcome" != no-change ]]; then
      remove_labels agent/plan-ready agent/needs-info agent/failed
      add_labels "agent/$outcome"
    fi
    ;;

  implement)
    require_result
    ISSUE="$NUMBER"
    status=$(field .status)
    if [[ "$status" == blocked ]]; then
      { echo "## Implementation blocked"; echo; field .blocked_reason | strip_markers; } > comment.md
      echo "The approved plan was not implemented. Comment to revise the plan, then add \`agent/approved\` again." >> comment.md
      footer >> comment.md
      post_issue_comment "$NUMBER" comment.md
      remove_labels agent/implementing agent/approved
      add_labels agent/plan-ready
      exit 0
    fi
    [[ "$status" == done ]] || die "Invalid status: $status"
    title=$(field .pr_title)
    [[ -n "$title" ]] || die "Missing pr_title"
    base=$(jq -r '.base_sha' "$META")
    branch="agent/issue-$ISSUE"
    if git ls-remote --exit-code --heads origin "$branch" > /dev/null; then
      die "Branch $branch already exists; delete it to re-run the implementation"
    fi
    git fetch --no-tags --depth=1 origin "$base"
    git checkout -q -b "$branch" "$base"
    apply_patch "$base" true
    tests=$(ci_tests)
    {
      field .pr_body | strip_markers
      printf '\n\nFixes #%s\n' "$ISSUE"
      printf '\n<!-- ci-tests: %s -->' "$tests"
      footer
    } > pr-body.md
    git push -q origin "$branch"
    pr_url=$(gh pr create --repo "$REPO" --base master --head "$branch" --title "$title" \
      --body-file pr-body.md --label agent/generated)
    pr_number="${pr_url##*/}"
    dispatch_ci "$branch" "$pr_number"
    printf 'Opened %s with the fix for the approved plan.' "$pr_url" > comment.md
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    remove_labels agent/implementing agent/failed
    add_labels agent/pr-open
    ;;

  review)
    require_result
    head_ref=$(jq -r '.head_ref' "$META")
    base=$(jq -r '.base_sha' "$META")
    review_id=$(jq -r '.review_id // empty' "$META")
    ISSUE="${head_ref#agent/issue-}"
    jq -e '.summary | length > 0' "$RESULT" > /dev/null || die "Missing summary"

    allowed_ids=""
    if [[ -n "$review_id" ]]; then
      allowed_ids=$(gh api --paginate "repos/$REPO/pulls/$NUMBER/reviews/$review_id/comments" --jq '.[].id')
    fi
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      grep -qx "$id" <<< "$allowed_ids" || die "Reply targets comment $id, which is not part of the triggering review"
    done < <(jq -r '.replies[].comment_id' "$RESULT")

    if [[ "$(field .changed)" == true ]]; then
      git fetch --no-tags origin "$head_ref"
      [[ "$(git rev-parse FETCH_HEAD)" == "$base" ]] || die "PR branch moved while the agent was running; re-request the review"
      git checkout -q -B "$head_ref" FETCH_HEAD
      apply_patch "$base" false
      git push -q origin "$head_ref"
      tests=$(ci_tests)
      if [[ -n "$tests" ]]; then
        gh pr view "$NUMBER" --repo "$REPO" --json body --jq .body \
          | perl -0pe 's/<!--\s*ci-tests:.*?-->//gs' > pr-body.md
        printf '<!-- ci-tests: %s -->' "$tests" >> pr-body.md
        gh pr edit "$NUMBER" --repo "$REPO" --body-file pr-body.md > /dev/null
      fi
      dispatch_ci "$head_ref" "$NUMBER"
    fi

    jq -c '.replies[]' "$RESULT" | while IFS= read -r reply; do
      id=$(jq -r '.comment_id' <<< "$reply")
      jq -r '.body' <<< "$reply" | strip_markers > reply.md
      footer >> reply.md
      gh api "repos/$REPO/pulls/$NUMBER/comments/$id/replies" -F body=@reply.md > /dev/null
    done
    field .summary | strip_markers > comment.md
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    ;;

  fail)
    phase="${FAILED_PHASE:-unknown}"
    printf 'The bug fixer agent failed during the **%s** phase. See the workflow run for details.' "$phase" > comment.md
    case "$phase" in
      investigate|implement)
        printf ' Re-add `agent/%s` to retry.' "$([[ $phase == investigate ]] && echo investigate || echo approved)" >> comment.md
        ;;
    esac
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    if [[ "$phase" != review ]]; then
      remove_labels agent/investigating agent/implementing
      [[ "$phase" == investigate ]] && remove_labels agent/investigate
      [[ "$phase" == implement ]] && remove_labels agent/approved
      add_labels agent/failed
    fi
    ;;

  *)
    die "Unknown mode $MODE"
    ;;
esac
