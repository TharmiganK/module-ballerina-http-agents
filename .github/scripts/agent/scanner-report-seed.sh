#!/usr/bin/env bash
# Posts the find-similar summary comment on the seed issue or PR: what was filed, dropped candidates, and a link to the
# run report on the agent-state branch.
#
# Env: REPO, GH_TOKEN, RUN_URL, SEED (issue:<n>|pr:<n>), DRY_RUN, RUN_NUMBER, AGENT_RESULT, SCANNER (defect or gap).
# Reads publish/publish-report.json.
set -euo pipefail

[[ "$SEED" =~ ^(issue|pr):([0-9]+)$ ]] || { echo "::error::Invalid seed $SEED"; exit 1; }
number="${BASH_REMATCH[2]}"
if [[ "${SCANNER:-defect}" == gap ]]; then
  heading="Similar gaps"; filed="Filed:"; none="No similar gaps were found."
  state_dir=gap-scanner; name="gap scanner"
else
  heading="Similar defects"; filed="Filed, each verified with a reproduction test:"; none="No similar defects were confirmed."
  state_dir=defect-scanner; name="defect scanner"
fi
report=publish/publish-report.json
[[ -f "$report" ]] || { mkdir -p publish; echo '{"filed": [], "would_file": [], "dropped": []}' > "$report"; }
{
  echo "## $heading"
  echo
  if [[ "$AGENT_RESULT" != success ]]; then
    echo "> [!WARNING]"
    echo "> The search did not finish in every area, so the result below is partial. See the workflow run, then add \`agent/find-similar\` again to retry."
    echo
  fi
  if [[ "$(jq '.filed | length' "$report")" != 0 ]]; then
    echo "$filed"
    jq -r '.filed[] | "- \(.url) (\(.category))"' "$report"
  elif [[ "$(jq '.would_file | length' "$report")" != 0 ]]; then
    echo "Would file (dry run):"
    jq -r '.would_file[] | "- \(.title) (\(.category))"' "$report"
  else
    echo "$none"
  fi
  if [[ "$(jq '.dropped | length' "$report")" != 0 ]]; then
    echo
    echo "<details><summary>Dropped candidates</summary>"
    echo
    jq -r '.dropped[] | "- \(.title): \(.reason)"' "$report"
    echo
    echo "</details>"
  fi
  echo
  report_url=$(gh api "repos/$REPO/contents/$state_dir/reports?ref=agent-state" \
    --jq ".[] | select(.name | endswith(\"-similar-${SEED/:/-}-run${RUN_NUMBER}.md\")) | .html_url" 2> /dev/null || true)
  if [[ -n "$report_url" ]]; then
    echo "[What was examined]($report_url)"
  fi
  echo
  echo "---"
  echo "<sub>Posted by the $name (find similar) · [workflow run]($RUN_URL)</sub>"
} > comment.md
gh api "repos/$REPO/issues/$number/comments" -F body=@comment.md > /dev/null
