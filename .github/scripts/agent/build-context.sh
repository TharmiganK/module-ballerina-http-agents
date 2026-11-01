#!/usr/bin/env bash
# Writes the issue/PR thread the agent works from into agent-context/, tagging each entry as trusted
# (author has write access) or untrusted. For the implement phase it also resolves the approved plan.
#
# Env: REPO, PHASE (investigate|discuss|implement|review|qa), NUMBER, and for review MODE=auto or REVIEW_ID or COMMENT_ID.
set -euo pipefail

: "${REPO:?}" "${PHASE:?}" "${NUMBER:?}"
OUT=agent-context
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

# In personal repositories every collaborator has write access; in organisations MEMBER may not, and the
# action's own write-permission check remains authoritative for who can trigger a run.
TRUSTED='def trusted: (.author_association // "NONE") | IN("OWNER", "MEMBER", "COLLABORATOR");'

paginate() { gh api --paginate "$1" --jq '.[]' | jq -s '.'; }

issue_thread() {
  local n="$1"
  local issue comments
  issue=$(gh api "repos/$REPO/issues/$n")
  comments=$(paginate "repos/$REPO/issues/$n/comments")
  jq -n --argjson issue "$issue" --argjson comments "$comments" "$TRUSTED"'
    {
      number: $issue.number,
      title: $issue.title,
      author: $issue.user.login,
      trusted: ($issue | trusted),
      labels: [$issue.labels[].name],
      body: ($issue.body // ""),
      comments: [$comments[] | {
        id, author: .user.login, author_type: .user.type, trusted: trusted, created_at, body
      }]
    }'
}

case "$PHASE" in
  investigate|discuss)
    issue_thread "$NUMBER" > "$OUT/thread.json"
    ;;

  implement)
    issue_thread "$NUMBER" > "$OUT/thread.json"
    approved_at=$(gh api --paginate "repos/$REPO/issues/$NUMBER/events" \
      --jq '.[] | select(.event == "labeled" and .label.name == "agent/approved") | .created_at' | tail -n 1)
    if [[ -z "$approved_at" ]]; then
      echo "::error::No agent/approved label event found on #$NUMBER"
      exit 1
    fi
    jq -r --arg at "$approved_at" '
      [.comments[] | select(.author == "github-actions[bot]"
                            and (.body | test("<!-- bug-fixer:plan v=[0-9]+ -->"))
                            and .created_at <= $at)]
      | last | .body // empty' "$OUT/thread.json" > "$OUT/approved-plan.md"
    if [[ ! -s "$OUT/approved-plan.md" ]]; then
      echo "::error::No agent plan comment posted before the approval at $approved_at"
      exit 1
    fi
    ;;

  review)
    pr=$(gh api "repos/$REPO/pulls/$NUMBER")
    conversation=$(paginate "repos/$REPO/issues/$NUMBER/comments")
    all_review_comments=$(paginate "repos/$REPO/pulls/$NUMBER/comments")
    threads=$(python3 "$HERE/pr-threads.py" "$REPO" "$NUMBER")
    if [[ "${MODE:-}" == auto ]]; then
      trigger='{"kind": "auto", "body": "", "comments": []}'
    elif [[ -n "${REVIEW_ID:-}" ]]; then
      review=$(gh api "repos/$REPO/pulls/$NUMBER/reviews/$REVIEW_ID")
      review_comments=$(paginate "repos/$REPO/pulls/$NUMBER/reviews/$REVIEW_ID/comments")
      trigger=$(jq -n --argjson r "$review" --argjson c "$review_comments" "$TRUSTED"'
        {kind: "review", id: $r.id, author: $r.user.login, trusted: ($r | trusted), state: $r.state,
         body: ($r.body // ""),
         comments: [$c[] | {id, path, line, original_line, in_reply_to_id, diff_hunk, body}]}')
    else
      comment=$(gh api "repos/$REPO/issues/comments/${COMMENT_ID:?}")
      trigger=$(jq -n --argjson c "$comment" "$TRUSTED"'
        {kind: "comment", id: $c.id, author: $c.user.login, trusted: ($c | trusted), body: ($c.body // ""), comments: []}')
    fi
    jq -n --argjson pr "$pr" --argjson trigger "$trigger" --argjson conv "$conversation" \
          --argjson rc "$all_review_comments" --argjson threads "$threads" "$TRUSTED"'
      {
        number: $pr.number, title: $pr.title, head: $pr.head.ref, body: ($pr.body // ""),
        trigger: $trigger,
        open_threads: [$threads[] | select(.resolved | not)
                       | {thread_id, source, actionable, outdated, path, line,
                          comments: [.comments[] | {id, author, created_at, body}]}],
        conversation: [$conv[] | {id, author: .user.login, trusted: trusted, created_at, body}],
        all_review_comments: [$rc[] | {id, author: .user.login, trusted: trusted, path, line, in_reply_to_id, created_at, body}]
      }' > "$OUT/thread.json"
    issue_number=$(jq -r '.head | capture("^agent/issue-(?<n>[0-9]+)$").n // empty' "$OUT/thread.json")
    if [[ -n "$issue_number" ]]; then
      issue_thread "$issue_number" > "$OUT/issue-thread.json"
    fi
    ;;

  qa)
    pr=$(gh api "repos/$REPO/pulls/$NUMBER")
    files=$(paginate "repos/$REPO/pulls/$NUMBER/files")
    previous=$(gh api --paginate "repos/$REPO/pulls/$NUMBER/reviews" \
      --jq '.[] | select(.user.login == "github-actions[bot]" and (.body | test("<!-- qa:review -->")))' | jq -s '.')
    previous_comments=$(paginate "repos/$REPO/pulls/$NUMBER/comments" \
      | jq '[.[] | select(.user.login == "github-actions[bot]" and (.body | test("<!-- qa:key=")))]')
    linked=$(jq -r '.body // "" | [scan("(?i)(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?) #([0-9]+)")[0]] | unique | .[]' <<< "$pr")
    jq -n --argjson pr "$pr" --argjson files "$files" --argjson prev "$previous" --argjson prevc "$previous_comments" "$TRUSTED"'
      {
        number: $pr.number, title: $pr.title, author: $pr.user.login, trusted: ($pr | trusted),
        body: ($pr.body // ""), base_sha: $pr.base.sha, head_sha: $pr.head.sha, head_ref: $pr.head.ref,
        files: [$files[] | {filename, status, additions, deletions}],
        previous_qa_reviews: [$prev[] | {submitted_at, commit_id, body}],
        previous_qa_inline_comments: [$prevc[] | {path, line, body}]
      }' > "$OUT/pr.json"
    gh pr diff "$NUMBER" --repo "$REPO" > "$OUT/pr.diff"
    for n in $linked; do
      issue_thread "$n" > "$OUT/issue-$n.json" || true
    done
    ;;

  *)
    echo "::error::Unknown phase $PHASE"
    exit 1
    ;;
esac

echo "Context written to $OUT/:"
ls -l "$OUT"
