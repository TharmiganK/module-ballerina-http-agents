# Find-similar run 3 for issue:20

- **Date:** 2026-11-02 03:49 UTC
- **Commit:** `056427b920c6`
- **Units:** `gap-similar-issue20-retry-after-retry-503-redirect`, `gap-similar-issue20-retry-after-cb-failover-lb`, `gap-similar-issue20-retry-after-server-side-and-sse` (3 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41384868152

## Issues
- Filed (gap-similar-issue20-retry-after-retry-503-redirect, improvement): [HTTP client retry ignores Retry-After on 503 Service Unavailable](https://github.com/TharmiganK/module-ballerina-http-agents/issues/39)

## Unit `gap-similar-issue20-retry-after-retry-503-redirect`

- **Status:** completed
- **Selected because:** similar to issue:20
- **Claude:** 16 turns, 1.8 min

### Coverage

### Find-similar: seed #20 (429 + `Retry-After` in the retry client), unit: the rest of the retry client and the redirect client

Checked at commit 056427b. `Retry-After` does not appear anywhere in `ballerina/*.bal` or `native/src/main/java`.

| Area / topic | Verdict |
|---|---|
| Retry client, `503` + `Retry-After` (the hint at L321/L332 `statusCodes.indexOf(...)`) | **Gap, filed as a finding** (`retry-honour-retry-after-503`). The seed's proposal says "other status codes are unchanged, including 503" and leaves it as open question 2, so its proposal does not cover this. Sample `agent-scratch/retry503.bal`: the backend returns 503 with `Retry-After: 3`, and the client retried after **0.14 s** (status=200, backendCalls=2, elapsed 0.55 s). No duplicate in known-issues, this repo, or upstream (searched `Retry-After`, `retry 503`, `retry after header`; the only hits are upstream #9418 (429, the seed's source) and this repo's #20). |
| Retry client, `413` + `Retry-After` (urllib3 `RETRY_AFTER_STATUS_CODES`, and RFC 9110 §15.5.14 SHOULD for temporary 413) | Folded into the 503 finding's proposal ("any retried status that carries `Retry-After`"). Not filed separately because the need is narrow. |
| Retry client, `HttpFuture`/`submit` results (the `getResponse` branch, L329-L332) | Not a separate gap. The seed's proposal already covers both the `Response` and the `HttpFuture` branch for 429, and the 503 finding has the same scope. |
| Cap on the server-requested delay (`maxWaitInterval`, `getWaitTime` L370) | Covered by the seed's proposal: a `Retry-After` larger than `maxWaitInterval` returns the response. The 503 finding reuses that rule. |
| HTTP-date vs delay-seconds parsing | Covered by the seed's proposed `getRetryAfterDelay` (int, falling back to RFC 1123 via `utcFromString`). It can be reused as is. |
| Redirect client, `Retry-After` on 3xx (RFC 9110 §10.2.3: the minimum time to wait before the redirected request) | **Not filed.** `checkRedirectEligibility`/`redirect` (`redirect_http_client.bal` L335-L385) follow the redirect at once. But none of the reference libraries delay redirects on `Retry-After`: urllib3 honours it only for 413/429/503, and OkHttp, Go `net/http`, go-retryablehttp and Polly follow redirects immediately. It is not established elsewhere, and RFC 9110 has no MUST/SHOULD for it. |
| Circuit breaker / failover / load balance, and the service side / SSE `retry` | Out of this unit (handled by the sibling units `gap-similar-issue20-retry-after-cb-failover-lb` and `...-server-side-and-sse`). |
| Excluded per scope | #20 (seed), #34, #35, #37, #38 were not re-examined. |

Nothing to pass to the defect scanner from this unit.

## Unit `gap-similar-issue20-retry-after-cb-failover-lb`

- **Status:** completed
- **Selected because:** similar to issue:20
- **Claude:** 18 turns, 1.4 min

### Coverage

## gap-similar-issue20-retry-after-cb-failover-lb (find-similar, seed #20)

**Result: no findings.** In each area the Retry-After pattern does appear in the code: nothing reads the header, and every timing decision comes from client config. However, none of these occurrences meets the bar of "established in at least two reference libraries or expected by an RFC". RFC 9110 §10.2.3 and RFC 6585 §4 only say a client *may* use `Retry-After` before a follow-up request. The seed (#20) and its retry-client proposal already cover that.

### Areas checked

| Area | Code | Verdict |
|---|---|---|
| Circuit breaker open period from `Retry-After` on 429/503 | `ballerina/resiliency_http_circuit_breaker.bal` L454-461 (`handleOpenCircuit`, `timeRemaining = resetTime - timeDif`), L463-475 (failure check uses only `statusCodes`), L670-683 (OPEN→HALF_OPEN only when `elapsedTime > resetTime`) | **Pattern present, not filed (not established elsewhere).** Resilience4j `waitIntervalFunctionInOpenState` and Polly v8 `BreakDurationGenerator` work out the break duration from attempt or failure counts, not from the response. The Polly docs show only `args.FailureCount` and give no `Retry-After` example. Envoy outlier detection ejects hosts for a fixed `base_ejection_time`. None of them takes the open time from a server header. |
| Circuit breaker telling the caller how long to wait | `UpstreamServiceUnavailableError` puts the remaining seconds only in the message string (L457-460) | Not filed. Only Polly has this (`BrokenCircuitException.RetryAfter`); Resilience4j `CallNotPermittedException` does not. One library is below the bar, and demand is low. |
| Failover delay from `Retry-After` | `ballerina/resiliency_failover_client.bal` L546/567 (`failoverCodes` check), L601 `runtime:sleep(failoverInterval)`, defaults L675 | **Not applicable.** Failover moves on to a *different* endpoint, so the failing server's `Retry-After` says nothing about when to call the next one. Each call starts again from `succeededEndpointIndex`, so after a 503 from endpoint 0 and a success on endpoint 1, later calls go to endpoint 1 first. The endpoint that sent 503 is only tried again when the healthy one fails. No library delays failover by the failed host's `Retry-After`. |
| Load-balancer quarantine of an endpoint that sent 429/503 + `Retry-After` | `ballerina/resiliency_load_balance_client.bal` L415-473; `LoadBalancerRule.getNextClient` (`resiliency_http_load_balancer_rule.bal`) receives only the client array | **Not filed for Retry-After.** Spring Cloud LoadBalancer uses health checks and Envoy outlier detection uses consecutive-5xx counts with a fixed ejection time; neither reads `Retry-After`. The closest available workaround: `LoadBalanceClientConfiguration.circuitBreaker` is copied to every target (L505-527), so each target gets its own circuit breaker. Once a target's breaker trips on `statusCodes: [429, 503]`, it returns `UpstreamServiceUnavailableError` and the LB fails over to the next target. That is per-endpoint quarantine for `resetTime`. |
| Rate-limit header awareness (`RateLimit`/`RateLimit-Policy`, draft-ietf-httpapi-ratelimit-headers) in LB/CB | none | Not filed. The headers are still an Internet-Draft, no reference library's load balancer reads them, and a similar upstream request (ballerina-library#3987 "Rate limiting feature for the `http:Client`?") was closed. |
| gRPC `grpc-retry-pushback-ms`, Envoy `rate_limited_retry_back_off` | — | Both apply to *retry*, so they belong to the seed (#20) and the sibling unit `gap-similar-issue20-retry-after-retry-503-redirect`. Extending #20 to 503 is its open question 2. |

Searches: `known-issues.json` (circuit/failover/load balance/retry/429/503 titles), and the GitHub search API for `load balance failover status code` and `circuit breaker retry-after` in ballerina-platform/ballerina-library and `Retry-After` in this repo. Only #20, #34, #37 and #38 came up, all retry-client issues (out of scope or excluded). There is nothing in `docs/proposals/`. No samples were run, because every verdict follows from reading the code. `Retry-After` appears nowhere in `ballerina/` or `native/src/main/java`.

### Separate gap for a normal (catalogue) gap scan of the resiliency unit, outside this pattern
`LoadBalanceClient` with `failover: true` fails over **only on `ClientError`** (L457-466). Any `Response` is returned straight away (L453-454), including 502/503/504/429, and `LoadBalanceClientConfiguration` has no equivalent of `FailoverClientConfiguration.failoverCodes`. Spec §2.4.1.7 is silent on this. Spring Cloud LoadBalancer (`retryable-status-codes` + `max-retries-on-next-service-instance`) and Envoy (`retry_on: retriable-status-codes` + `previous_hosts` host predicate) both retry on another instance for status codes. The per-target circuit breaker workaround above only kicks in after the circuit trips. This is a separate design assumption (status codes, not timing hints), so it is not filed here. Upstream ballerina-library#524 (closed, "pluggable LB/FO algorithms") is related but different.

### For the defect scanner
- `handleOpenCircuit` (circuit breaker L454-461) truncates the remaining time with `<int>`. `getEffectiveErrorTime` falls back to `time:utcNow()` when there is no error or forced-open time (L585-589, `//TODO:What to send?`), so the reported "suspended for N seconds" can be wrong.
- LB `performLoadBalanceAction` builds `loadBalancerInRequest` with `createFailoverRequest` but always sends the original `request` (L452).

## Unit `gap-similar-issue20-retry-after-server-side-and-sse`

- **Status:** completed
- **Selected because:** similar to issue:20
- **Claude:** 14 turns, 1.5 min

### Coverage

### Find-similar run for seed #20 (Retry-After): service side and SSE client

**Nothing filed.** Every area I checked already supports this, has a one-line workaround, or the maintainers rejected the idea.

| Area / topic | Verdict | Evidence |
|---|---|---|
| Service sends `Retry-After` on a 429/503 status code response (`http:TooManyRequests`, `http:ServiceUnavailable`) | **Present with a one-line workaround** | `ballerina/http_status_code_types.bal` L1012, L1052: `*CommonResponse` already has `headers`, so `return <http:TooManyRequests>{headers: {"Retry-After": "120"}}` works (sample below). A typed `retryAfter` field would only save one string. Spring (`ResponseEntity.status(429).header("Retry-After", …)`) also sets it as a plain header. ASP.NET Core sets `Response.Headers.RetryAfter` as a typed header but also takes a string. Not a gap worth filing. |
| Service sends `Retry-After` through status code errors (`httpscerr:TooManyRequestsError` / `ServiceUnavailableError`) | **Present** | The error detail takes `headers`. `http_status_error_utils.bal` L44-46 copies them to the response (sample below). |
| Listener-generated 503/429 (shutdown, overload) | **Not applicable** | The native layer never generates a 503 or 429 (`SERVICE_UNAVAILABLE` appears only in the `UpstreamServiceUnavailableError` type name), so there is nothing that would need `Retry-After`. |
| Typed `Retry-After` getter on `http:Response` (client side) | **Covered by the seed's proposal** | `res.getHeader("retry-after")` works today. The seed proposes an internal `getRetryAfterDelay(Response)` helper that parses delay-seconds and HTTP-dates. If maintainers make it public, it covers the manual workaround. I did not file it separately. |
| SSE client reconnects using the `retry` field and `Last-Event-ID` (browser EventSource, WHATWG) | **Gap, but rejected upstream** | `bytes_to_sse_stream_generator.bal` L145 parses `retry` into `SseEvent.'retry`, and the client never reconnects. In the SSE proposal ballerina-platform/ballerina-library#6687 (closed), maintainers decided: "we won't be supporting the SSE retry mechanism using the last event ID and last retry values … not an 80% use case". Following the rules, I dropped it. OkHttp EventSource and httpx-sse don't reconnect automatically either, so the module matches them. Related open issue: ballerina-library#9341, which is about how the `retry` field is parsed (accepts negatives and `+5`). That belongs to the defect scanner and is already reported. |
| Rate-limit headers on server responses (`RateLimit-*` IETF draft) | **Not applicable** | The draft is not an RFC, and these headers can be set through `headers` the same way. Client-side rate limiting is upstream ballerina-library#3987, which is a different topic. |

**Duplicate searches:** `known-issues.json`; GitHub search for "SSE reconnect", "Last-Event-ID" and "Retry-After" in ballerina-library; "sse retry" in this repository. Matches: #20 (the seed), #1, #8 and ballerina-library #9418, #6687, #9341. None asks for the service-side behaviour, and #6687 rejected SSE reconnection.

**Sample:** `agent-scratch/retry_after_service.bal`. It returns `http:TooManyRequests{headers: {"Retry-After": "120"}}` and `httpscerr:ServiceUnavailableError("down", headers = {"Retry-After": "30"})`. Output: `/rec 429 Retry-After=120`, `/err 503 Retry-After=30`. Both headers reach the client.

**For the defect scanner (low priority):** returning a status code error deliberately, here a 503 with headers, also logs `level=ERROR … "unhandled error returned from the service"`. That may be intended, but it is noisy for an expected rate-limit or unavailable response.

**For the seed's proposal:** whether 503 + `Retry-After` should also be honoured is the seed's open question 2, and it is handled by the sibling unit for retry, 503 and redirects. Nothing in this unit adds to it.
