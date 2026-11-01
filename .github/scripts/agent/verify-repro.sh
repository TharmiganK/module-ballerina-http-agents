#!/usr/bin/env bash
# Re-runs the agent's reproduction test (group repro_<issue>) in the agent's workspace and records whether it
# actually ran and failed, so a bug claim never rests on the agent's own report of the output.
#
# Env: ISSUE. Reads agent-output/result.json (test_package, test_filter); writes agent-output/repro.json with
# status reproduced | not-reproduced | not-run.
set -uo pipefail

: "${ISSUE:?}"
RESULT=agent-output/result.json
OUT=agent-output/repro.json
LOG=agent-output/repro.log
GROUP="repro_${ISSUE}"

record() {
  jq -n --arg status "$1" --arg reason "$2" --arg command "${command:-}" \
        --argjson total "${total:-0}" --argjson failed "${failed:-0}" --arg message "${message:-}" \
        '{status: $status, reason: $reason, command: $command, total: $total, failed: $failed, message: $message}' > "$OUT"
  cat "$OUT"
  exit 0
}

pkg=$(jq -r '.test_package // empty' "$RESULT")
filter=$(jq -r '.test_filter // empty' "$RESULT")
[[ -n "$pkg" ]] || record not-run "The agent did not report test_package"

case "$pkg" in
  native|compiler-plugin)
    [[ "$filter" =~ ^[A-Za-z0-9_.*]+$ ]] || record not-run "A Java reproduction needs a test_filter (test class name)"
    results_dir=$([[ "$pkg" == native ]] && echo native/build/test-results/test || echo compiler-plugin-tests/build/test-results/test)
    rm -rf "$results_dir"
    command=".github/scripts/run-tests.sh $pkg $filter"
    .github/scripts/run-tests.sh "$pkg" "$filter" > "$LOG" 2>&1
    shopt -s nullglob
    xmls=("$results_dir"/*.xml)
    (( ${#xmls[@]} > 0 )) || record not-run "No test results were produced (compilation failure or no matching tests); see repro.log"
    total=$(cat "${xmls[@]}" | grep -oE '<testsuite [^>]*' | grep -oE ' tests="[0-9]+"' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    failed=$(cat "${xmls[@]}" | grep -oE '<testsuite [^>]*' | grep -oE ' (failures|errors)="[0-9]+"' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    message=$(cat "${xmls[@]}" | grep -oE '<failure message="[^"]{0,500}' | head -n 1 | sed 's/<failure message="//')
    ;;
  *)
    [[ "$pkg" =~ ^[a-z0-9-]+$ && -d "ballerina-tests/$pkg" ]] || record not-run "Unknown test package: $pkg"
    grep -rqE "\b$GROUP\b" "ballerina-tests/$pkg/tests" || record not-run "No test in group $GROUP under ballerina-tests/$pkg/tests"
    report="ballerina-tests/$pkg/target/report/test_results.json"
    rm -rf "ballerina-tests/$pkg/target/report"
    command=".github/scripts/run-tests.sh bal $pkg $GROUP"
    .github/scripts/run-tests.sh bal "$pkg" "$GROUP" > "$LOG" 2>&1
    [[ -f "$report" ]] || record not-run "No test report was produced (compilation failure?); see repro.log"
    total=$(jq '.totalTests // 0' "$report")
    failed=$(jq '.failed // 0' "$report")
    message=$(jq -r '[.. | objects | select(.status? == "FAILURE") | .failureMessage // empty][0] // "" | .[0:500]' "$report")
    ;;
esac

(( total > 0 )) || record not-run "No test in group $GROUP ran"
(( failed > 0 )) || record not-reproduced "All $total test(s) in the reproduction passed"
record reproduced "$failed of $total test(s) failed"
