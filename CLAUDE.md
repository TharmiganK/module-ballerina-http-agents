# Ballerina HTTP module (`ballerina/http`)

Ballerina standard library `http` package: a Ballerina API layer backed by a Java/Netty native layer. Read `docs/architecture.md` before tracing a bug across layers. The behavioural contract is `docs/spec/spec.md` (~4000 lines; grep its `## N.` headings rather than reading it whole).

## Repository map

| Path | Gradle project | Contents |
|---|---|---|
| `ballerina/` | `:http-ballerina` | Public Ballerina API (`*.bal`). File prefixes group features: `http_client*`, `http_service*`, `resiliency_*`, `caching_*`, `cookie_*`, `auth_*`, `http_interceptors.bal`, `http_errors.bal`. No tests live here. |
| `native/` | `:http-native` | Java interop (`io.ballerina.stdlib.http.api`), Netty transport (`...http.transport`), URI template matching (`...http.uri`). Java unit tests under `native/src/test`. |
| `compiler-plugin/` | `:http-compiler-plugin` | Compile-time validation of services/resources/interceptors, code actions, completions, static code analysis rules, OpenAPI generation. |
| `compiler-plugin-tests/` | `:http-compiler-plugin-tests` | TestNG tests; Ballerina sources under `src/test/resources/ballerina_sources/`. |
| `ballerina-tests/<pkg>/` | `:http-ballerina-tests` | Ballerina integration tests, one Ballerina package per feature area (below). `http-test-common` is a shared helper package. |
| `integration-tests/` | `:http-integration-tests` | Sample-based end-to-end tests. Rarely needed. |
| `test-utils/` | `:http-test-utils` | Java helpers used by Ballerina tests. |
| `docs/spec/spec.md`, `docs/proposals/` | | Specification and design proposals. |

Ballerina test packages by feature area:

| Package | Covers |
|---|---|
| `http-client-tests` | Client actions and resource methods, client data binding, status code response binding, host header, 100-continue, connection pool/eviction |
| `http-service-tests` | Listener init/lifecycle, service configuration, native request/response/connection functions, resource return types |
| `http-dispatching-tests` | Resource dispatching, base paths, URI templates, path/query/header/payload parameter binding, produces/consumes, constraint validation |
| `http-interceptor-tests` | Request/response/error interceptors, request context |
| `http-resiliency-tests` | Retry, circuit breaker, load balancer, failover |
| `http-security-tests` | Listener/client auth (basic, LDAP, JWT, OAuth2), SSL/TLS, mutual SSL, SNI, host name verification |
| `http2-tests` | HTTP/2 variants of client, dispatching and SSL tests; server push, prior knowledge, HTTP/1.1 fallback |
| `http-advanced-tests` | Caching, compression, cookies, CORS, HATEOAS links, multipart, SSE, relaxed data binding, service contracts, status code errors, streaming, trailers |
| `http-misc-tests` | Headers, payload access, request/response limits, redirects, keep-alive, pipelining, idle timeout, HTTP/SOCKS proxies, OPTIONS, introspection, passthrough |

## Building and testing

Prerequisites: JDK 25, Docker (only for LDAP/SOCKS tests), and `packageUser`/`packagePAT` env vars (GitHub PAT with `read:packages`) to resolve dependencies from GitHub Packages. No Ballerina installation is needed (see below).

### The build-local Ballerina distribution

The Ballerina Gradle plugin unpacks the `jballerina-tools` distribution for `ballerinaLangVersion` (`gradle.properties`), plus the stdlib dependencies, into `target/ballerina-runtime`. When `:http-ballerina:build` passes, the plugin copies the freshly built `http` bala into `target/ballerina-runtime/repo/bala`, so that distribution resolves `ballerina/http` to the code in this checkout. All Ballerina tests run on it.

Use `target/ballerina-runtime/bin/bal` (never a globally installed `bal`, which would pull the released `http` from Central) to run quick samples against the current code. Write the sample outside the repo, then:

```sh
.github/scripts/run-tests.sh build      # (re)build after changing ballerina/, native/ or compiler-plugin/; clears the compiled http cache
target/ballerina-runtime/bin/bal run /path/to/sample.bal
```

Module-level listeners (`service ... on new http:Listener(...)`) only start after `main` returns, so a sample whose `main` calls its own service fails with a connection error. In a sample, start the listener in `main` (`check l.attach(svc, "/path"); check l.'start();` and `check l.immediateStop();` at the end), or use a `bal test` test instead.

`./gradlew clean` deletes `target/`, so the next build downloads the distribution again.

**Always use `.github/scripts/run-tests.sh` instead of raw Gradle test commands.** The full suite takes a long time, and the raw Gradle graph runs far more than you ask for (see gotchas).

```sh
.github/scripts/run-tests.sh build                                   # build all modules, no tests
.github/scripts/run-tests.sh bal http-client-tests                   # one Ballerina test package
.github/scripts/run-tests.sh bal http-client-tests repro_1234        # one package, one test group
.github/scripts/run-tests.sh bal http-client-tests,http2-tests g1,g2 # several packages/groups
.github/scripts/run-tests.sh native 'io.ballerina.stdlib.http.uri.*' # native Java tests (filter optional)
.github/scripts/run-tests.sh compiler-plugin CompilerPluginTest      # compiler plugin tests
```

`DRY_RUN=1` prints the Gradle task graph without running anything; `GRADLE_ARGS="..."` passes extra Gradle args. Ballerina test reports are written to `ballerina-tests/<pkg>/target/report/`.

After changing anything under `ballerina/`, `native/` or `compiler-plugin/`, the `bal` mode rebuilds the package before testing, so no separate build step is needed.

GraalVM native-image tests: add `GRADLE_ARGS=-PbalGraalVMTest` to a `bal` run. The plugin then runs `bal test --graalvm` and turns off code coverage. It needs a GraalVM JDK as `JAVA_HOME`/`GRAALVM_HOME` and is much slower, so use it only for native-image compatibility issues (reflection/resource configs live in `native/src/main/resources/META-INF/native-image`). `-PbalParallelTest` runs `bal test --parallel`.

### Gotchas

- `:http-ballerina:build` is `finalizedBy :http-ballerina-tests:build`, and each Java module's `build` runs its tests. A plain `./gradlew :http-ballerina-tests:test -PbalTests=x` therefore also runs the full native and compiler-plugin suites. The script excludes those tasks.
- `commitTomlFiles` tasks in `ballerina/` and `ballerina-tests/` run `git commit` on regenerated `Ballerina.toml`/`Dependencies.toml` files. The script excludes them and restores any TOML file the build rewrote. Never commit version-only changes to these files.
- Java test classes in `native` and `compiler-plugin-tests` run from `src/test/resources/testng.xml`. A new test class must be added there or it never runs.
- `ballerinaTest` starts LDAP (used by `http-security-tests`) and SOCKS (used by `http-misc-tests`) Docker containers. The script only starts them for those packages.
- `bal` compiles the `http` bala into `target/ballerina-runtime/repo/cache/ballerina/http/` on first use and keeps reusing it while the version is unchanged, so after a rebuild it would run stale code. `run-tests.sh` deletes that cache before every run except `native`; delete it yourself before `target/ballerina-runtime/bin/bal run` after changing `ballerina/` or `native/`.
- `settings.gradle` publishes a public Gradle build scan on every build. The script passes `--no-scan`; do the same for any raw Gradle command.
- This repo is a private mirror (`TharmiganK/module-ballerina-http-agents`) whose `upstream` remote is the public `ballerina-platform/module-ballerina-http`. Always pass `--repo TharmiganK/module-ballerina-http-agents` to `gh` commands that create or modify issues, PRs, labels or comments.

## Writing tests

- Put a Ballerina test in the package for its feature area (table above), in an existing `tests/*.bal` file on the same topic or a new `tests/<topic>_test.bal`.
- Tests start real listeners. Every listener port is declared as a constant in that package's `tests/test_service_ports.bal`; add a new constant there with a port number not used anywhere in `ballerina-tests/` (`grep -rn "= <port>;" ballerina-tests/*/tests/test_service_ports.bal`).
- Use `@test:Config {groups: ["<group>"]}` so the test can run alone. Many existing tests have no groups.
- Reproduction tests for an issue use the group `repro_<issue-number>` and stay in the fix PR as the regression test.
- New files need the WSO2 Apache 2.0 license header used by neighbouring files, with the current year.
- Bugs in compiler-plugin validation are tested in `compiler-plugin-tests` with a Ballerina source project under `src/test/resources/ballerina_sources/` and diagnostics asserted in Java.

## Change conventions

- Add user-visible changes to `changelog.md` under an `## [Unreleased]` section at the top (create it if missing), in the `Added`/`Changed`/`Fixed` subsections, linking the issue.
- Behaviour changes to the public API must update `docs/spec/spec.md` (and its `_Updated_` date).
- Java changes must pass checkstyle and spotbugs (both run as part of `build`); native-image compatibility matters (`native/src/main/resources/META-INF/native-image`).
- The PR template (`.github/pull_request_template.md`) checklist applies to every PR.
