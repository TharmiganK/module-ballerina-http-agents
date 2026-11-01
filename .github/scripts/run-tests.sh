#!/usr/bin/env bash
# Runs a targeted subset of tests without dragging in the full suites.
#
#   run-tests.sh build                              build all modules, no tests
#   run-tests.sh bal <pkg>[,<pkg>...] [<groups>]    Ballerina tests in ballerina-tests/<pkg>
#   run-tests.sh native [<class/method filter>]     Java tests in native (TestNG suite)
#   run-tests.sh compiler-plugin [<filter>]         Java tests in compiler-plugin-tests
#
# Extra Gradle args can be passed via GRADLE_ARGS. Set DRY_RUN=1 to print the task graph only.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# `:http-ballerina:build` is finalizedBy `:http-ballerina-tests:build`, and the Java modules'
# `build` runs their tests, so every targeted run must cut those edges explicitly.
SKIP_JAVA_TESTS=(-x :http-native:test -x :http-compiler-plugin:test -x :http-test-utils:test -x :http-ballerina:test)
# These tasks run `git commit` on regenerated Ballerina.toml/Dependencies.toml files.
SKIP_AUTO_COMMIT=(-x :http-ballerina:commitTomlFiles -x :http-ballerina-tests:commitTomlFiles)
SKIP_BAL_TESTS=(-x :http-ballerina-tests:test -x :http-ballerina-tests:ballerinaTest -x :http-ballerina-tests:build)

mode="${1:-}"
shift || true
args=()

case "$mode" in
  build)
    args=(build -x test "${SKIP_AUTO_COMMIT[@]}" "${SKIP_BAL_TESTS[@]}")
    ;;
  bal)
    pkgs="${1:?usage: run-tests.sh bal <pkg>[,<pkg>...] [<groups>]}"
    groups="${2:-}"
    args=(:http-ballerina-tests:test "-PbalTests=$pkgs" "${SKIP_JAVA_TESTS[@]}" "${SKIP_AUTO_COMMIT[@]}")
    if [[ -n "$groups" ]]; then args+=("-Pgroups=$groups"); fi
    # LDAP is only used by http-security-tests and the SOCKS proxy only by http-misc-tests.
    [[ ",$pkgs," == *",http-security-tests,"* ]] || args+=(-x :http-ballerina-tests:startLdapServer)
    [[ ",$pkgs," == *",http-misc-tests,"* ]] || args+=(-x :http-ballerina-tests:startSocksServer)
    ;;
  native)
    args=(:http-native:test)
    if [[ -n "${1:-}" ]]; then args+=(--tests "$1"); fi
    ;;
  compiler-plugin)
    args=(:http-compiler-plugin-tests:test "${SKIP_JAVA_TESTS[@]}" "${SKIP_AUTO_COMMIT[@]}" "${SKIP_BAL_TESTS[@]}")
    if [[ -n "${1:-}" ]]; then args+=(--tests "$1"); fi
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

if [[ "${DRY_RUN:-}" == "1" ]]; then args+=(--dry-run); fi
read -r -a extra <<< "${GRADLE_ARGS:-}"

# bal compiles the http bala into this cache on first use and reuses it while the version is unchanged, so a
# rebuilt bala would otherwise be ignored and tests would run against stale code.
if [[ "$mode" != native ]]; then rm -rf target/ballerina-runtime/repo/cache/ballerina/http; fi

# The build rewrites version placeholders in these files; restore any that were clean before the run.
toml_files=$(git ls-files '*Ballerina.toml' '*Dependencies.toml' '*CompilerPlugin.toml')
# shellcheck disable=SC2086
dirty_before=$(git diff --name-only -- $toml_files)

status=0
# settings.gradle publishes a public build scan on every build; this repo is private.
./gradlew --no-scan "${args[@]}" ${extra[@]+"${extra[@]}"} || status=$?

# shellcheck disable=SC2086
for f in $(git diff --name-only -- $toml_files); do
  grep -qxF "$f" <<< "$dirty_before" || git checkout -q -- "$f"
done

exit "$status"
