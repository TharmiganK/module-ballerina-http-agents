#!/usr/bin/env bash
# Deterministic state changes after agent work leaves the agents' hands: agent PRs merged, closed or reopened, issues
# closed or reopened, a maintainer approving a close suggestion, and closing a split parent once all its sub-issues
# are closed. Runs no agent.
#
# Usage: lifecycle.sh <pr-closed|pr-reopened|issue-closed|issue-reopened|approve-close> <number>
# Env: REPO, GH_TOKEN, RUN_URL; MERGED (pr-closed), ACTOR (approve-close).
set -euo pipefail

MODE="${1:?usage: lifecycle.sh <mode> <number>}"
NUMBER="${2:?usage: lifecycle.sh <mode> <number>}"
: "${REPO:?}" "${RUN_URL:?}"
BOT=github-actions[bot]
# Labels for work in flight or waiting on a maintainer; they mean nothing once the issue is closed.
TRANSIENT=(agent/investigate agent/investigating agent/approved agent/implementing agent/plan-ready agent/needs-info agent/close-suggested agent/failed)

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }
labels_of() { gh api "repos/$REPO/issues/$1" --jq '[.labels[].name]'; }
has() { jq -e --arg l "$2" 'index($l)' <<< "$1" > /dev/null; }
add_label() { gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null; }
remove_labels() {
  local n="$1"; shift
  for l in "$@"; do gh api -X DELETE "repos/$REPO/issues/$n/labels/$(urlencode "$l")" > /dev/null 2>&1 || true; done
}
comment() {
  printf '%s\n\n---\n<sub>Posted by the agent lifecycle workflow · [workflow run](%s)</sub>\n' "$2" "$RUN_URL" > lifecycle-comment.md
  gh api "repos/$REPO/issues/$1/comments" -F body=@lifecycle-comment.md > /dev/null
}
close_issue() {
  # state_reason duplicate is newer than not_planned; fall back if the API rejects it.
  gh api -X PATCH "repos/$REPO/issues/$1" -f state=closed -f state_reason="$2" > /dev/null \
    || gh api -X PATCH "repos/$REPO/issues/$1" -f state=closed -f state_reason=not_planned > /dev/null
}

# Closes a split parent (marked in the sub-issue body) once every sub-issue is closed, with a summary of outcomes.
# Closes made here use GITHUB_TOKEN and trigger no workflow, so callers that close an issue call this directly.
check_parent() {
  local parent subs open summary
  parent=$(gh api "repos/$REPO/issues/$1" --jq '.body // "" | capture("<!-- bug-fixer:split-from=(?<n>[0-9]+) -->").n // empty')
  [[ -n "$parent" ]] || return 0
  [[ "$(gh api "repos/$REPO/issues/$parent" --jq .state)" == open ]] || return 0
  subs=$(gh api --paginate "repos/$REPO/issues/$parent/sub_issues" | jq -s 'add // []')
  open=$(jq '[.[] | select(.state == "open")] | length' <<< "$subs")
  if (( open > 0 )); then
    echo "#$parent still has $open open sub-issue(s)"
    return 0
  fi
  summary=$(jq -r '.[] | "- #\(.number): " + (
      if ([.labels[].name] | index("agent/fixed")) then "fixed"
      elif .state_reason == "not_planned" then "closed as not planned"
      elif .state_reason == "duplicate" then "closed as a duplicate"
      else "closed as completed" end)' <<< "$subs")
  comment "$parent" "All sub-issues of this issue are closed, so it is closed too.

$summary"
  close_issue "$parent" completed
  echo "Closed split parent #$parent"
}

case "$MODE" in
  pr-closed)
    ref=$(gh pr view "$NUMBER" --repo "$REPO" --json headRefName --jq .headRefName)
    [[ "$ref" =~ ^agent/issue-([0-9]+)$ ]] || { echo "::notice::#$NUMBER is not an agent PR"; exit 0; }
    issue="${BASH_REMATCH[1]}"
    remove_labels "$NUMBER" agent/auto-fix
    labels=$(labels_of "$issue")
    if [[ "${MERGED:-false}" == true ]]; then
      remove_labels "$issue" agent/pr-open "${TRANSIENT[@]}"
      add_label "$issue" agent/fixed
      gh api -X DELETE "repos/$REPO/git/refs/heads/$(urlencode "$ref")" > /dev/null 2>&1 \
        || echo "::warning::Could not delete branch $ref"
      # Normally "Fixes #<issue>" closes the issue and the issue-closed run checks the parent. If it did not, close it
      # here; that close uses GITHUB_TOKEN and starts no run, so check the parent here too.
      if [[ "$(gh api "repos/$REPO/issues/$issue" --jq .state)" == open ]]; then
        comment "$issue" "Fixed by #$NUMBER."
        close_issue "$issue" completed
        check_parent "$issue"
      fi
    elif has "$labels" agent/pr-open; then
      # The branch is kept so the PR can be reopened; the next implementation replaces it.
      remove_labels "$issue" agent/pr-open
      add_label "$issue" agent/plan-ready
      comment "$issue" "Fix PR #$NUMBER was closed without merging, so the plan is waiting for a decision again. Comment \`/agent <what to change>\` to revise the plan, add \`agent/approved\` to implement it again, or close this issue."
    fi
    ;;

  pr-reopened)
    ref=$(gh pr view "$NUMBER" --repo "$REPO" --json headRefName --jq .headRefName)
    [[ "$ref" =~ ^agent/issue-([0-9]+)$ ]] || exit 0
    issue="${BASH_REMATCH[1]}"
    if has "$(labels_of "$issue")" agent/plan-ready; then
      remove_labels "$issue" agent/plan-ready
      add_label "$issue" agent/pr-open
    fi
    ;;

  issue-closed)
    labels=$(labels_of "$NUMBER")
    # A merged agent PR closes its issue; the pr-closed run owns that transition.
    if ! has "$labels" agent/pr-open; then
      remove_labels "$NUMBER" "${TRANSIENT[@]}"
    fi
    check_parent "$NUMBER"
    ;;

  issue-reopened)
    remove_labels "$NUMBER" agent/fixed
    ;;

  approve-close)
    has "$(labels_of "$NUMBER")" agent/close-suggested || { echo "::notice::#$NUMBER has no close suggestion"; exit 0; }
    marker=$(gh api --paginate "repos/$REPO/issues/$NUMBER/comments" \
      --jq ".[] | select(.user.login == \"$BOT\") | .body" \
      | grep -oE '<!-- bug-fixer:close reason=[a-z-]+ of=[^ ]* -->' | tail -n 1 || true)
    [[ -n "$marker" ]] || { echo "::error::No close suggestion marker on #$NUMBER"; exit 1; }
    reason=$(sed -E 's/.*reason=([a-z-]+).*/\1/' <<< "$marker")
    dup=$(sed -E 's/.* of=([^ ]*) -->/\1/' <<< "$marker")
    case "$reason" in
      duplicate)        resolution=Resolution/Duplicate;        state_reason=duplicate ;;
      not-a-bug)        resolution=Resolution/NotABug;          state_reason=not_planned ;;
      cannot-reproduce) resolution=Resolution/CannotReproduce;  state_reason=not_planned ;;
      out-of-scope|invalid) resolution=Reason/Invalid;          state_reason=not_planned ;;
      *) echo "::error::Unknown close reason $reason"; exit 1 ;;
    esac
    remove_labels "$NUMBER" "${TRANSIENT[@]}"
    add_label "$NUMBER" "$resolution"
    text="Closed as ${reason//-/ }${dup:+ of $dup}, as the issue analyser suggested and ${ACTOR:-a maintainer} approved."
    [[ "$reason" == duplicate && "$dup" == \#* ]] && text+=$'\n\nDuplicate of '"$dup"
    comment "$NUMBER" "$text"
    close_issue "$NUMBER" "$state_reason"
    check_parent "$NUMBER"
    ;;

  *)
    echo "::error::Unknown mode $MODE"; exit 1 ;;
esac
