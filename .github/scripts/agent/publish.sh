#!/usr/bin/env bash
# Deterministic publish step for the issue agents (issue analyser, bug fixer): validates the agent's structured output and patch,
# enforces the caps, then writes to GitHub. The agent itself never holds a write token.
#
# Usage: publish.sh <analyse|discuss|implement|review|fail>
# Env: REPO, AGENT (issue-analyser|bug-fixer), NUMBER, RUN_URL, GH_TOKEN; agent-output/{result.json,meta.json,changes.patch} from the agent job.
# For fail: FAILED_PHASE.
set -euo pipefail

MODE="${1:?usage: publish.sh <phase|fail>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
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

# Agent text must not forge the markers the workflow relies on. Text that arrives with escaped newlines and no real
# ones (a double-encoded JSON string) is unescaped.
strip_markers() {
  perl -0pe 's/\\n/\n/g unless /\n(?!\z)/; s/<!--\s*(bug-fixer|ci-tests):.*?-->//gs; s/^.*Generated with \[Claude Code\].*\n?//gm'
}

AGENT_NAME=$([[ "${AGENT:-}" == bug-fixer ]] && echo "bug fixer" || echo "issue analyser")
footer() { printf '\n\n---\n<sub>Posted by the %s · [workflow run](%s)</sub>\n' "$AGENT_NAME" "$RUN_URL"; }

post_issue_comment() {
  gh api "repos/$REPO/issues/$1/comments" -F body=@"$2" > /dev/null
}

# Opens one sub-issue per part of a mixed issue, links it to the parent and starts an investigation on each.
split_issue() {
  local count i part title kind type_label child child_id existing
  local -a carry children args
  gh api "repos/$REPO/issues/$NUMBER" > parent.json
  ! jq -e '.body // "" | test("<!-- bug-fixer:split-from=")' parent.json > /dev/null \
    || die "#$NUMBER was split from another issue and cannot be split again"
  count=$(jq '.parts | length' "$RESULT")
  (( count >= 2 && count <= 5 )) || die "A split needs 2 to 5 parts, got $count"
  field .comment | strip_markers | perl -0pe 's/\s+\z//' > comment.md
  [[ -s comment.md ]] || die "Empty comment"
  mapfile -t carry < <(jq -r '.labels[].name | select((startswith("Type/") or startswith("agent/")) | not)' parent.json)
  existing=$(gh api --paginate "repos/$REPO/issues/$NUMBER/sub_issues" --jq '.[].title' 2> /dev/null || true)
  children=()
  printf '\n\n**Sub-issues**\n\n' >> comment.md
  for (( i = 0; i < count; i++ )); do
    part=$(jq -c ".parts[$i]" "$RESULT")
    title=$(jq -r .title <<< "$part")
    kind=$(jq -r .classification <<< "$part")
    case "$kind" in
      bug) type_label=Type/Bug ;; improvement) type_label=Type/Improvement ;; feature) type_label=Type/NewFeature ;;
      *) die "Invalid part classification: $kind" ;;
    esac
    if grep -qxF "$title" <<< "$existing"; then
      echo "::notice::Sub-issue '$title' already exists"
      continue
    fi
    {
      printf '_Split from #%s by the issue analyser._\n\n' "$NUMBER"
      jq -r .body <<< "$part" | strip_markers
      printf '\n<!-- bug-fixer:split-from=%s -->\n' "$NUMBER"
    } > child.md
    args=(--repo "$REPO" --title "$title" --body-file child.md --label "$type_label" --label agent/investigate)
    for l in "${carry[@]+"${carry[@]}"}"; do args+=(--label "$l"); done
    child=$(gh issue create "${args[@]}")
    child=${child##*/}
    child_id=$(gh api "repos/$REPO/issues/$child" --jq .id)
    gh api "repos/$REPO/issues/$NUMBER/sub_issues" -F sub_issue_id="$child_id" > /dev/null \
      || echo "::warning::Could not link #$child as a sub-issue of #$NUMBER"
    children+=("$child")
    printf -- '- #%s (%s)\n' "$child" "${type_label#Type/}" >> comment.md
  done
  (( ${#children[@]} > 0 )) || die "Every part already exists as a sub-issue"
  printf '\nEach sub-issue is investigated on its own: bugs get a reproduction and a fix plan to approve, improvements and features get an analysis and a proposal.' >> comment.md
  footer >> comment.md
  post_issue_comment "$NUMBER" comment.md
  remove_labels agent/investigating agent/plan-ready agent/needs-info agent/analysed agent/failed
  add_labels agent/split
  # Labels added with GITHUB_TOKEN start no workflow, so each investigation is dispatched explicitly.
  for child in "${children[@]}"; do
    gh workflow run agent-issue-analyser.yml --repo "$REPO" -f issue="$child" \
      || echo "::warning::Could not start the investigation of #$child; add agent/investigate to it again"
  done
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
    # Not `git diff | grep -q`: grep exits at the first match, git diff gets SIGPIPE and pipefail fails the check.
    grep -qE "^\+.*repro_${ISSUE}\b" <<< "$(git diff "$base"..HEAD)" \
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
  analyse)
    require_result
    outcome=$(field .outcome)
    classification=$(field .classification)
    if [[ "$classification" == mixed || "$outcome" == split ]]; then
      [[ "$classification" == mixed && "$outcome" == split ]] || die "Only a mixed issue can be split, and it must end split"
      split_issue
      exit 0
    fi
    case "$classification" in
      bug)         [[ "$outcome" == plan-ready || "$outcome" == needs-info ]] || die "A bug must end plan-ready or needs-info, not $outcome" ;;
      improvement|feature|question)
                   [[ "$outcome" == analysed ]] || die "A $classification must end analysed, not $outcome" ;;
      *)           die "Invalid classification: $classification" ;;
    esac
    field .comment | strip_markers > comment.md
    [[ -s comment.md ]] || die "Empty comment"
    if [[ "$outcome" == analysed ]]; then
      ! grep -q '^## Plan v' comment.md || die "An $classification analysis must not contain a '## Plan v' section"
    elif [[ "$outcome" == plan-ready ]]; then
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
    remove_labels agent/investigating agent/plan-ready agent/needs-info agent/analysed agent/failed
    # The agent's classification becomes the Type label only when no maintainer has set one.
    if [[ -z "$(gh api "repos/$REPO/issues/$NUMBER" --jq '[.labels[].name | select(startswith("Type/"))] | first // empty')" ]]; then
      case "$classification" in
        bug) add_labels Type/Bug ;; improvement) add_labels Type/Improvement ;;
        feature) add_labels Type/NewFeature ;; question) add_labels Type/Question ;;
      esac
    fi
    add_labels "agent/$outcome"
    ;;

  discuss)
    require_result
    outcome=$(field .outcome)
    [[ "$outcome" =~ ^(plan-ready|needs-info|analysed|no-change)$ ]] || die "Invalid outcome: $outcome"
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
      remove_labels agent/plan-ready agent/needs-info agent/analysed agent/failed
      add_labels "agent/$outcome"
    fi
    ;;

  implement)
    require_result
    ISSUE="$NUMBER"
    status=$(field .status)
    if [[ "$status" == blocked ]]; then
      field .blocked_reason | strip_markers > reason.md
      grep -q '^## ' reason.md || { echo "## Implementation blocked"; echo; } > comment.md
      cat reason.md >> comment.md
      echo "The approved plan was not implemented. Comment \`/agent\` with guidance to revise the plan, then add \`agent/approved\` again." >> comment.md
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
    # The workflow owns agent/issue-<n>. A branch without an open PR is a leftover from a failed or abandoned
    # run and is replaced; one with an open PR is never touched here (the review phase updates it).
    existing=$(git ls-remote --heads origin "$branch" | cut -f1)
    if [[ -n "$existing" ]]; then
      open_prs=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq length)
      (( open_prs == 0 )) || die "An open PR already uses $branch"
      echo "::warning::Replacing leftover branch $branch (was $existing) that has no open PR"
    fi
    # Apply on the current master rather than the agent's base: a branch whose workflow files differ from master
    # (because master moved during the run) is rejected for GITHUB_TOKEN as a workflow change.
    git fetch --no-tags --depth=50 origin master
    tip=$(git rev-parse FETCH_HEAD)
    [[ "$tip" == "$base" ]] || echo "::notice::master moved from ${base:0:12} to ${tip:0:12} during the run; applying on top"
    git checkout -q -b "$branch" "$tip"
    apply_patch "$tip" true
    tests=$(ci_tests)
    {
      field .pr_body | strip_markers
      printf '\n\nFixes #%s\n' "$ISSUE"
      printf '\n<!-- ci-tests: %s -->' "$tests"
      footer
    } > pr-body.md
    if [[ -n "$existing" ]]; then
      git push -q --force-with-lease="refs/heads/$branch:$existing" origin "$branch"
    else
      git push -q origin "$branch"
    fi
    pr_url=$(gh pr create --repo "$REPO" --base master --head "$branch" --title "$title" \
      --body-file pr-body.md --label agent/generated)
    pr_number="${pr_url##*/}"
    dispatch_ci "$branch" "$pr_number"
    gh workflow run agent-qa.yml --repo "$REPO" -f pr="$pr_number" || echo "::warning::Could not dispatch the QA review"
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
    mode=$(jq -r '.mode // empty' "$META")
    ISSUE="${head_ref#agent/issue-}"
    jq -e '.summary | length > 0' "$RESULT" > /dev/null || die "Missing summary"

    # Replies may target the triggering review's comments and open threads started by a maintainer or the QA agent;
    # never third-party threads.
    python3 "$HERE/pr-threads.py" "$REPO" "$NUMBER" > threads.json
    allowed_ids=$(jq -r '.[] | select(.resolved | not) | select(.source == "maintainer" or .source == "qa")
                         | .comments[].id' threads.json)
    if [[ -n "$review_id" ]]; then
      allowed_ids+=$'\n'$(gh api --paginate "repos/$REPO/pulls/$NUMBER/reviews/$review_id/comments" --jq '.[].id')
    fi
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      grep -qx "$id" <<< "$allowed_ids" \
        || die "Reply targets comment $id, which is neither in the triggering review nor in an open maintainer or QA thread"
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

    # All thread replies and the summary go out as one review, so the PR timeline shows a single entry for the round.
    # The footer is only on the summary; replies carry a hidden marker so pr-threads.py knows who answered last.
    gql() { gh api graphql "$@"; }
    pr_node=$(gh pr view "$NUMBER" --repo "$REPO" --json id --jq .id)
    review_node=$(gql -f query='mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }' \
      -f pr="$pr_node" --jq .data.addPullRequestReview.pullRequestReview.id)
    discard_review() {
      gql -f query='mutation($r: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $r}) { clientMutationId } }' \
        -f r="$review_node" > /dev/null || true
    }
    trap discard_review ERR
    to_resolve=()
    while IFS= read -r reply; do
      id=$(jq -r '.comment_id' <<< "$reply")
      thread=$(jq -r --argjson id "$id" '.[] | select(any(.comments[]; .id == $id)) | .thread_id' threads.json)
      [[ -n "$thread" ]] || { discard_review; die "No review thread contains comment $id"; }
      body="$(jq -r '.body' <<< "$reply" | strip_markers)"$'\n\n<!-- bug-fixer:reply -->'
      gql -f query='mutation($r: ID!, $t: ID!, $b: String!) {
          addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $b}) { comment { id } } }' \
        -f r="$review_node" -f t="$thread" -f b="$body" > /dev/null
      [[ "$(jq -r '.resolve' <<< "$reply")" == true ]] && to_resolve+=("$thread")
    done < <(jq -c '.replies[]' "$RESULT")
    field .summary | strip_markers > comment.md
    [[ "$mode" == auto ]] && printf '\n\n<!-- bug-fixer:auto-round -->' >> comment.md
    footer >> comment.md
    gql -f query='mutation($r: ID!, $b: String!) {
        submitPullRequestReview(input: {pullRequestReviewId: $r, event: COMMENT, body: $b}) { pullRequestReview { id } } }' \
      -f r="$review_node" -f b="$(cat comment.md)" > /dev/null
    trap - ERR
    for thread in "${to_resolve[@]+"${to_resolve[@]}"}"; do
      gql -f query='mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }' \
        -f t="$thread" > /dev/null || echo "::warning::Could not resolve review thread $thread"
    done

    # With agent/auto-fix, look again after this round: feedback may have arrived while the agent was working.
    if [[ "$(gh pr view "$NUMBER" --repo "$REPO" --json labels --jq '[.labels[].name] | index("agent/auto-fix")')" != null ]]; then
      gh workflow run agent-auto-fix.yml --repo "$REPO" -f pr="$NUMBER" || echo "::warning::Could not schedule the auto-fix check"
    fi
    ;;

  fail)
    phase="${FAILED_PHASE:-unknown}"
    printf 'The %s failed during the **%s** phase. See the workflow run for details.' "$AGENT_NAME" "$phase" > comment.md
    case "$phase" in
      analyse)        printf ' Add `agent/investigate` to retry.' >> comment.md ;;
      implement)      printf ' Add `agent/approved` to retry the approved plan, or `agent/investigate` to start over.' >> comment.md ;;
      discuss|review) printf ' Comment `/agent` to retry.' >> comment.md ;;
    esac
    footer >> comment.md
    post_issue_comment "$NUMBER" comment.md
    # Analyse and implement replace their in-progress label with agent/failed; a failed discuss or review keeps
    # the issue's current state label, so the issue always has a single agent/* label.
    if [[ "$phase" == analyse || "$phase" == implement ]]; then
      remove_labels agent/investigate agent/investigating agent/approved agent/implementing agent/plan-ready
      add_labels agent/failed
    fi
    ;;

  *)
    die "Unknown mode $MODE"
    ;;
esac
