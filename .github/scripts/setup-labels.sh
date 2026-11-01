#!/usr/bin/env bash
# Creates or updates the issue/PR labels used by maintainers and the AI agents.
# Idempotent: safe to re-run. Usage: setup-labels.sh [owner/repo] [--delete-defaults]
set -euo pipefail

REPO="${1:-TharmiganK/module-ballerina-http-agents}"
DELETE_DEFAULTS="${2:-}"

label() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force
}

# Triage labels (mirrors ballerina-platform/ballerina-library naming)
label "Type/Bug"         "b60205" "Something does not work as expected"
label "Type/Improvement" "1d76db" "Improvement to existing functionality"
label "Type/NewFeature"  "1d76db" "New functionality"
label "Type/Task"        "1d76db" "Task"
label "Type/Question"    "1d76db" "Question or unclear expected behaviour"
label "Type/Docs"        "1d76db" "Documentation"

label "Priority/Highest" "b60205" ""
label "Priority/High"    "ff9900" ""
label "Priority/Normal"  "ff9900" ""
label "Priority/Low"     "ff9900" ""

label "Area/CompilerPlugin" "006b75" "Compiler plugin, code actions, static code analysis"
label "Area/Security"       "186872" "Auth, SSL/TLS and other security features"
label "Area/GraalVM"        "186872" "Native image compatibility"
label "Area/Docs"           "186872" "API docs and module docs"
label "Area/Spec"           "186872" "Specification (docs/spec/spec.md); combine with a Type/* label"
label "module/http"         "0e8a16" ""

# Agent lifecycle labels
AGENT="5319e7"
label "agent/investigate"   "$AGENT" "Maintainer: ask the bug fixer agent to investigate this issue"
label "agent/approved"      "$AGENT" "Maintainer: approve the agent's current plan for implementation"
label "agent/investigating" "$AGENT" "Agent: investigation in progress"
label "agent/needs-info"    "$AGENT" "Agent: could not reproduce or needs more details"
label "agent/plan-ready"    "$AGENT" "Agent: root cause and fix plan posted, awaiting approval"
label "agent/analysed"      "$AGENT" "Agent: improvement, feature or question analysed; proposal or answer posted"
label "agent/split"         "$AGENT" "Agent: issue covered several things and was split into linked sub-issues"
label "agent/implementing"  "$AGENT" "Agent: implementing the approved plan"
label "agent/pr-open"       "$AGENT" "Agent: fix PR opened"
label "agent/failed"        "$AGENT" "Agent: run failed, see the workflow logs"
label "agent/generated"     "$AGENT" "Created by an AI agent"
label "agent/auto-fix"      "$AGENT" "Bug fixer addresses review feedback on this agent PR automatically after reviewers go quiet"
label "agent/find-similar"  "$AGENT" "Search the module for defects similar to this issue or PR (consumed when the search starts)"
label "agent/qa-skip"       "$AGENT" "Do not run the QA agent automatically on this PR"
label "agent/qa-trusted"    "$AGENT" "Maintainer reviewed build-logic changes in this fork PR; /qa may run it"

if [[ "$DELETE_DEFAULTS" == "--delete-defaults" ]]; then
  for l in bug documentation duplicate enhancement "good first issue" "help wanted" invalid question wontfix accessibility; do
    gh label delete "$l" --repo "$REPO" --yes 2>/dev/null || true
  done
fi
