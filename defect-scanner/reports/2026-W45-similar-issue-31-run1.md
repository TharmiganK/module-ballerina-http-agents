# Find-similar run 1 for issue:31

- **Date:** 2026-11-02 02:54 UTC
- **Commit:** `166990d08c42`
- **Units:** `similar-issue31-client-timer-config-doc-vs-impl`, `similar-issue31-listener-timer-config-doc-vs-impl`, `similar-issue31-resiliency-timer-config-doc-vs-impl` (3 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41378362146

## Issues
- Filed (similar-issue31-client-timer-config-doc-vs-impl, bug): [Client poolConfig drops fractional seconds: sub-second eviction times break init or disable eviction](https://github.com/TharmiganK/module-ballerina-http-agents/issues/32)
- Filed (similar-issue31-listener-timer-config-doc-vs-impl, bug): [HTTP/2 listener with `timeout: 0` still times streams out after 300 seconds](https://github.com/TharmiganK/module-ballerina-http-agents/issues/33)
- Filed (similar-issue31-resiliency-timer-config-doc-vs-impl, bug): [Retry client sleeps one extra interval after the final failed attempt before returning the error](https://github.com/TharmiganK/module-ballerina-http-agents/issues/34)
- Filed (similar-issue31-resiliency-timer-config-doc-vs-impl, bug): [Retry client's maxWaitInterval does not cap the first retry wait](https://github.com/TharmiganK/module-ballerina-http-agents/issues/35)
- Filed (similar-issue31-client-timer-config-doc-vs-impl, spec): [secureSocket handshakeTimeout/sessionTimeout docs omit units and whole-second truncation](https://github.com/TharmiganK/module-ballerina-http-agents/issues/36)

## Security
- 0 found, 0 delivered privately

## Unit `similar-issue31-client-timer-config-doc-vs-impl`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 45 turns, 5.5 min

### Coverage

### Scope
Find-similar run for seed #31 (a timer field doc that does not match the native behaviour). Read: `ballerina/http_client_config.bal` (ClientSocketConfig, ClientSecureSocket), `ballerina/http_client_connection_pool.bal`, `HttpUtil.populatePoolingConfig` / `getListenerConfig` / the SSL config parsing, `SenderConfiguration.setConnectTimeOut`, `BootstrapConfiguration`/`PoolableTargetChannelFactory` (CONNECT_TIMEOUT_MILLIS), `PoolConfiguration`, `ConnectionManager.instantiateAndConfigureConfig`, the `Http2ConnectionManager` idle and stale eviction tasks, `Util.setSslHandshakeTimeOut`, and `SSLHandlerFactory` session timeouts. Spec: §2.4 client config (L1266-L1300) and §2.4.1.12. The spec lists `poolConfig`/`secureSocket` but never describes their fields.

### Places checked for the pattern
- `socketConfig.connectTimeOut`: converted correctly, `(int)(s*1000)` → `CONNECT_TIMEOUT_MILLIS`. Its phase coverage is already part 3 of #31. Not reported.
- `poolConfig.waitTime`: converted correctly (cast after multiply) to commons-pool `maxWait`. Its phase docs belong to #31 part 3. `waitTime <= 0` means block forever in commons-pool 1.x, which the docs don't say; not reported separately because it overlaps #31's waitTime doc work.
- `minEvictableIdleTime`, `timeBetweenEvictionRuns`: cast before multiply truncates to whole seconds. **Reported (finding 1)** and reproduced: `Non-positive period.` at client init, and no idle eviction at 0.5 s. A control run with `minEvictableIdleTime: 1` passed.
- `minIdleTimeInStaleState`/`timeBetweenStaleEviction` (client, HttpUtil L1393-L1403): the same cast bug, so -1 becomes -1000 and the stale task evicts in-flight streams. Dropped as a duplicate: #11 (listener) names these client lines in its suggested resolution. `timeBetweenStaleEviction: 0.5` also gives `Non-positive period.` (seen in a scratch run), which #11 also covers.
- `handshakeTimeout`/`sessionTimeout`: whole seconds via `BDecimal.intValue()`, with values <1 ignored. The docs give no units. **Reported as spec (finding 2).**
- `minEvictableIdleTime <= 0`: clamped to 0, so HTTP/1.1 never evicts idle connections while HTTP/2 evicts at every run, and the `== -1` branch in Http2ConnectionManager is dead. Mentioned inside finding 1 and not reproduced separately for HTTP/2.
- Http2ClientTimeoutHandler per-stream timer vs HTTP/1.1 idle timer, and the 100-continue wait: not examined in depth this run (the `timeout` field belongs to the seed and is excluded).

### Duplicate checks
known-issues.json (#10, #11, #15, #31; ballerina-library #8129, #7309, #8780, #1791 closed, all different). GitHub searches: `timeBetweenEvictionRuns`, `minEvictableIdleTime`, `\"Non-positive period\"`, `handshakeTimeout`, `PoolConfiguration decimal`, and `evict` in both trackers; open upstream PRs for `eviction`, `handshakeTimeout` and `timeBetweenEvictionRuns`. No match found.

### Runs
- `bal run agent-scratch/evict.bal`: both `timeBetweenEvictionRuns: 0.5` and `timeBetweenStaleEviction: 0.5` → `Non-positive period.`
- `run-tests.sh bal http-client-tests scanner_1_1`: both repro tests fail with the expected messages. With `minEvictableIdleTime: 1` the eviction test passes, and the file was then restored to 0.5.

Repro files: `ballerina-tests/http-client-tests/tests/client_pool_fractional_eviction_test.bal`, port constant `fractionalEvictionTestPort = 9879` in `test_service_ports.bal`.

## Unit `similar-issue31-listener-timer-config-doc-vs-impl`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 43 turns, 13.0 min

### Coverage

### Scope
Find-similar run for seed #31: timer fields documented with semantics the implementation does not have. Unit: the listener-side timers.

**Read:**
- Spec §2.1, §2.1.2, §2.1.4, §6.1 (L2234-2240) and §9.2.1.
- `ballerina/http_service_endpoint.bal`: `ListenerConfiguration`, `InferredListenerConfiguration`, `ListenerSecureSocket`.
- `ballerina/http_constants.bal`: `DEFAULT_LISTENER_TIMEOUT`, `DEFAULT_GRACEFULSTOP_TIMEOUT`.
- `HttpUtil.getListenerConfig`, the timeout parts, and `getLongValueOrDefault`.
- `ListenerConfiguration.java`, `DefaultHttpWsConnectorFactory`, `ServerConnectorBootstrap` (`unBindInterface`), `HttpServerChannelInitializer`, `BackPressureAwareIdleStateHandler`.
- `Http2SourceHandler`, `Http2ServerTimeoutHandler`, `Http2SourceConnectionHandlerBuilder`, `Http2WithPriorKnowledgeHandler`, `GracefulStop.java`, and `Util.setSslHandshakeTimeOut`.

**Ran:** `.github/scripts/run-tests.sh bal http2-tests scanner_1_1`. It failed as expected after 300.3 s with `Unexpected status 500, body: Stream timed out`.

### Places checked for the pattern
- **Listener `timeout = 0` on HTTP/1.1:** not affected. A `BackPressureAwareIdleStateHandler(0)` is a disabled Netty `IdleStateHandler`, and negative values are rejected in `HttpUtil` L1576.
- **Listener `timeout = 0` on HTTP/2:** affected. `Http2SourceHandler` L112 replaces it with 300 s. Reported as `http2-listener-zero-timeout-not-disabled`.
- **Listener timeout firing while a resource is slow (hint 2):** this contradicts the §6.1 sentence that inactivity caused by the application itself is excluded. That spec location (§6.1 around L2236-2238) is the seed's own excluded location, and the behaviour is already tracked upstream in ballerina-library#2906 (open) and #4102 (closed). Dropped.
- **`gracefulStopTimeout`:** units are correct (seconds × 1000 → `Thread.sleep(ms)`; the HTTP/2 `gracefulShutdownTimeoutMillis` uses the same value), and negative values are rejected. The full period is always slept even when there are no in-flight requests. That is consistent with the vague doc \"Grace period\" and is not a clear defect. The missing spec text for `gracefulStopTimeout` is already #15. Dropped.
- **`DEFAULT_LISTENER_TIMEOUT` (60) and `DEFAULT_GRACEFULSTOP_TIMEOUT` (0):** the doc comments and the record defaults match. Not affected.
- **HTTP/2 per-stream vs HTTP/1.1 per-connection `timeout`:** this difference is described in §6.1 for back-pressure. No reproducible defect beyond the 0 handling.
- **`minIdleTimeInStaleState` / `timeBetweenStaleEviction`:** read in `HttpUtil` L1613-1622, so not ignored on HTTP. Their being ignored on HTTPS is #10, and the `-1` misbehaviour is #11. Dropped as duplicates.
- **`secureSocket.handshakeTimeout` / `sessionTimeout`:** the values are truncated to whole seconds with `BDecimal.intValue()`, so `handshakeTimeout: 0.5` silently falls back to Netty's 10 s default. The docs give no unit. This is minor (sub-second handshake timeouts are uncommon) and was not reproduced, so it is not reported.
- **Sub-millisecond listener `timeout` values (for example 0.0004):** these truncate to 0, which disables the timer. A theoretical edge case, not reported.

### Duplicate checks
- `known-issues.json`: titles containing timeout, graceful, idle, stale or timer. Related but different: #10, #11, #15, #31, and ballerina-library #2906, #4102, #5112, #3277.
- GitHub search of TharmiganK/module-ballerina-http-agents (\"listener timeout 0 disable\") and of ballerina-platform/ballerina-library (\"http2 timeout\", \"timeout: 0\", `gracefulStopTimeout`): no report of HTTP/2 ignoring `timeout: 0`.
- Open PRs in ballerina-platform/module-ballerina-http (\"timeout\", \"idle timeout http2 server\"): none.

## Unit `similar-issue31-resiliency-timer-config-doc-vs-impl`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 28 turns, 3.2 min

### Coverage

### Scope
Find-similar run for seed #31 (a timer field's doc does not match what it actually does). Spec §2.4.1.4, §2.4.1.5, §2.4.1.7 and §2.4.1.8 contain only examples and say nothing about timing. Files read: `ballerina/resiliency_http_retry_client.bal`, `resiliency_http_circuit_breaker.bal`, `resiliency_failover_client.bal`, `resiliency_load_balance_client.bal`, `http_client_config.bal`, and how the circuit breaker is built in `http_client_endpoint.bal` (L593-L640). I also skimmed the existing retry tests in `http-resiliency-tests`.

### What I ran
Two new tests in `ballerina-tests/http-resiliency-tests/tests/retry_timer_test.bal`, on new ports 9791 and 9792. The run was `.github/scripts/run-tests.sh bal http-resiliency-tests scanner_1_1,scanner_1_2` and both tests failed as expected:
- scanner_1_1 took 4.15 s where about 2 s was expected.
- scanner_1_2 took 3.45 s where about 1 s was expected.

### Places checked for the pattern
- **Retry `interval` / `count` / `backOffFactor` / `maxWaitInterval`**
  - The loop sleeps once more after the last attempt fails with an error (finding 1).
  - `maxWaitInterval` does not cap the first wait (finding 2).
  - `count` behaves as the number of retries (count+1 attempts), which matches the doc.
  - `backOffFactor < 1` is accepted, so the interval shrinks; spec §2.4.1.4 and the tests even use 0.5. The doc says the factor \"increases the retry interval exponentially\". This is a minor doc wording problem and I did not report it on its own; finding 2 suggests documenting the formula.
  - `backOffFactor <= 0` is treated as 1 and `maxWaitInterval: 0` is treated as 60 s; neither is documented. Finding 2's resolution covers this.
- **Circuit breaker `resetTime`**: it is measured from the later of the last error and the last forced open (`getEffectiveErrorTime`), not from when the circuit tripped. A request that was already in flight and fails after the trip pushes the reset back. This differs from the doc only slightly, so I did not report it. The \"suspended for N seconds\" message truncates to an int, which is cosmetic.
- **Circuit breaker `timeWindow` / `bucketSize`**
  - `bucketSize: 0` causes a decimal divide-by-zero panic at client init instead of returning an error. Dropped as covered by open ballerina-library#340 (\"Validate Circuit Breaker Configuration when initializing\").
  - A `bucketSize` that does not divide `timeWindow` is accepted; the decimal-to-int conversion in `getCurrentBucketId` rounds instead of truncating, so bucket boundaries are skewed. I could not show an observable effect cheaply, so I did not report it.
  - The init error text says timeWindow must be \"greater than\" bucketSize, but equal values are accepted. Trivial.
- **Failover `interval`**: the client sleeps only between endpoints; `handleError` / `handleResponseWithErrorCode` return before the sleep once all endpoints have failed. This matches \"Failover delay interval\", so the failover path is not affected.
- **Load balancer**: no timer fields of its own (it only passes `timeout` through), so not affected.
- **Sleeping past the client `timeout`**: the retry and failover waits are separate from `timeout`, which is an idle timer per attempt (seed #31). Nothing in the docs or spec promises an overall deadline; that is the seed's feature request, so excluded.

### Duplicate checks
- Searched `known-issues.json` for retry, circuit, bucket, backoff, wait, failover and interval. Related but different issues: #20 / ballerina-library#9418 (Retry-After), ballerina-library#1601 (closed refactor of status-code validation), ballerina-library#8701 (resetting retry attempts) and ballerina-library#340 (circuit breaker config validation).
- GitHub searches:
  - `retry maxWaitInterval` and `retry interval sleep` in ballerina-library: nothing relevant.
  - `bucketSize` in ballerina-library: only ftp module issues.
  - `retry` in this repo: #20 and #31.
  - Open PRs in module-ballerina-http for `retry` and `circuit breaker`: none."
