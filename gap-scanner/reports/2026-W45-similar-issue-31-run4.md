# Find-similar run 4 for issue:31

- **Date:** 2026-11-02 05:07 UTC
- **Commit:** `056427b920c6`
- **Units:** `gap-similar-issue31-listener-request-phase-deadlines`, `gap-similar-issue31-resiliency-time-budgets`, `gap-similar-issue31-streaming-and-auxiliary-client-cancel` (3 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41391315576

## Issues
- Filed (gap-similar-issue31-listener-request-phase-deadlines, feature): [Let a resource find out that the client disconnected or reset the stream](https://github.com/TharmiganK/module-ballerina-http-agents/issues/65)
- Filed (gap-similar-issue31-resiliency-time-budgets, improvement): [Let the circuit breaker trip on slow calls (slow-call duration and rate thresholds)](https://github.com/TharmiganK/module-ballerina-http-agents/issues/66)

## Dropped findings
- (gap-similar-issue31-streaming-and-auxiliary-client-cancel) Closing a partially read response byte stream or SSE stream does not abort the exchange — over the cap of 2 issues per run
- (gap-similar-issue31-listener-request-phase-deadlines) Listener: bound the total time to receive a request body and to send a response — over the cap of 2 issues per run
- (gap-similar-issue31-listener-request-phase-deadlines) Per-resource execution timeout instead of one listener-wide idle timeout — over the cap of 2 issues per run

## Unit `gap-similar-issue31-listener-request-phase-deadlines`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 45 turns, 7.2 min

### Coverage

### Unit: listener request-phase deadlines (find-similar from #31)

I filed nothing, as instructed: three findings are returned for the filing step, ranked by demand.

| Area / topic | Verdict |
|---|---|
| **Header-read timeout** (Go `ReadHeaderTimeout`, Kestrel `RequestHeadersTimeout`, Node `headersTimeout`) | **Present, implicitly.** The idle handler sits after the HTTP codec (`Util.addIdleStateHandler`), so partial header bytes do not reset it. A header trickle of one fragment per second against `timeout: 2` was cut off after about 3 s (sample case 1). The spec does not say this; worth one sentence in §2.1. |
| **Whole-request read deadline / minimum body data rate** (Go `ReadTimeout`, Node `requestTimeout`, Kestrel `MinRequestBodyDataRate`) | **Gap, finding `listener-request-read-deadline`.** A body trickled one byte per second took 8 s under `timeout: 2` and was accepted (sample case 2). This matches spec L301. |
| **Response write deadline / minimum response data rate** (Go `WriteTimeout`, Kestrel `MinResponseDataRate`) | **Gap,** folded into the same finding. Only the idle timer applies, and §6.1 says an HTTP/1.1 slow reader is not distinguished from an active one. |
| **Per-route execution timeout** (Go `TimeoutHandler`, ASP.NET `[RequestTimeout]`, Spring async timeout) | **Gap, finding `resource-execution-timeout`.** Today the listener-wide idle `timeout` acts as one and answers 408 (sample case 4). |
| **Handler signalled on client disconnect or HTTP/2 RST_STREAM** (Go `Request.Context()`, ASP.NET `RequestAborted`, Node `req/res 'close'`) | **Gap, finding `listener-client-disconnect-signal`.** In sample case 3 the resource ran 5 s after the client closed, and only learned of it when `respond` failed. Related upstream: ballerina-library#2906 (open; asks for the strand to be interrupted after the listener timeout) and #4102 (closed). The finding asks for a narrower cooperative signal that also covers disconnects and resets. The filing step should check whether maintainers see it as a duplicate of #2906. |
| **Graceful shutdown with a drain deadline** (`gracefulStopTimeout`) | **Already reported as #50** in this repo ("Should `gracefulStop()` serve in-flight requests by default?"). The spec omission is #(spec 2.1 missing `gracefulStopTimeout`) in known-issues. Not re-filed. |
| HTTP/2 stream concurrency and stale timers (§2.1.4) | Not a deadline gap. `timeout: 0` behaviour on HTTP/2 is already reported (known-issues: \"HTTP/2 listener with `timeout: 0` still times streams out after 300 seconds\"). |
| Seed (#31): client per-call deadline and cancel | Excluded. The seed proposal does not extend to the listener. |

**Sample run:** `agent-scratch/slow_request.bal`. It starts a listener with `timeout: 2` and HTTP/1.1, and drives it with raw-TCP bash clients through `os:exec`. Cases:
1. Slow headers: closed at about 3 s.
2. Slow body: 201 after 8 s.
3. Client closes after 1 s: the resource ran all 6 s and `respond` failed.
4. Client waits: 408 at 2 s while the resource kept running.

`agent-scratch/exec_test.bal` only checks that `os:exec` works.

**For the defect scanner:**
- The listener answers `408 Request Timeout` when its idle timer fires during resource execution, after the request was fully received. RFC 9110 §15.5.9 defines 408 for a request that was not received in time. 503 or 504 would fit better. Upstream #4102 raised this question and was closed without discussion.
- Spec §2.1 does not state that the header phase is bounded by `timeout`, or that the timer runs during resource execution.

**Upstream searches** (ballerina-library): slowloris; header timeout listener; disconnect resource http; resource timeout annotation; client closed connection resource cancel. Nothing asks for a request-read deadline, a data rate or a per-resource timeout.

## Unit `gap-similar-issue31-resiliency-time-budgets`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 25 turns, 3.2 min

### Coverage

## Find-similar run for seed #31 (per-call deadline and cancel): resiliency time budgets

Spec read: §2.4.1.3–2.4.1.5, §2.4.1.7, §2.4.1.8. Code read: `RetryConfig`, `performRetryAction`, `CircuitBreakerConfig` and its health accounting, `FailoverClient.performFailoverAction`, `FailoverClientConfiguration`/`TargetService`, and the redirect and load-balance config plumbing.

| Area / topic | Verdict |
|---|---|
| Total time budget across retry attempts and sleeps | **Covered by the seed proposal** ("one deadline covers the whole call, including all retry attempts, retry sleeps and redirect hops"; the retry client must not sleep past the remaining budget). Not filed. |
| Total time across failover / load-balance endpoints (including `failoverInterval` sleeps) | **Covered by the seed** ("the deadline spans all endpoints tried"). The seed's implementation needs to bound `runtime:sleep(failoverInterval)` at `resiliency_failover_client.bal` L601 the same way as the retry sleep. Not filed. |
| Time bound across redirect hops (`FollowRedirects` has only `maxCount`) | **Covered by the seed** (redirects share the deadline). Not filed. |
| Abandoning a retry/failover loop mid-sleep (`runtime:sleep` in `resiliency_http_retry_client.bal` L352 and failover L601) | **Covered by the seed's `CancellationToken`/cancel.** Its implementation must check the token before each attempt and use an interruptible wait. Not filed. |
| Per-attempt timeout for retry (Envoy `per_try_timeout`, MS.Extensions.Http.Resilience `AttemptTimeout`, Resilience4j TimeLimiter inside Retry) | **Present with workaround, not filed.** The retry client decides on the response headers. Before the headers arrive the server is normally silent, so the client's idle `timeout` already bounds time to first byte for each attempt. The remaining gap (slow request-body writes, wanting a TTFB bound shorter than the body idle bound on the same client) is narrow. Once #31 lands, a `RetryConfig.perAttemptTimeout` would be a small extension of its native abort; mention it in #31's design discussion rather than as a separate issue. |
| Per-endpoint timeout in failover/LB (`TargetService` has only `url`, `secureSocket`) | **Not filed:** a single shared `timeout` per failover/LB client meets common needs, and differing per-target timeouts are a niche case. |
| Circuit breaker slow-call thresholds (Resilience4j `slowCallDurationThreshold`/`slowCallRateThreshold`, Sentinel slow-ratio rule) | **Gap, filed as finding `circuit-breaker-slow-call-threshold`.** Sample `agent-scratch/cb_slow_calls.bal`: 1.5 s responses never trip the circuit; the only workaround (`timeout = 1`) turns them into `IdleTimeoutError` failures. |
| Circuit breaker counting cancellations or deadline expiry | Excluded: already in the seed proposal (open question 2 there). |
| Retry budget / throttling (Envoy `retry_budget`, gRPC `retryThrottling`, AWS SDK retry quota) | Outside this time-budget pattern (it is cross-request accounting), so not filed here. Worth checking in the catalogue retry unit. No existing issue found. |
| Hedged requests (Polly hedging, gRPC `hedgingPolicy`, Envoy `hedge_on_per_try_timeout`) | Not filed: low demand, and it depends on per-attempt timeouts and cancel from #31. |
| Retry jitter | Already reported as #38. |
| `Retry-After` honouring | Already reported as #20 (429), plus the 503 variant in known-issues; excluded. |
| Non-idempotent retry/failover policy | Already reported (known-issues entry "Retry, failover and load balance clients re-send non-idempotent requests with no method policy"). |

Searches: `known-issues.json`. GitHub search in ballerina-platform/ballerina-library (`module/http`) for "slow circuit breaker", "circuit breaker timeout", "retry timeout attempt", "retry budget" and "per-try timeout", plus "circuit breaker" in this repo. The only related hits were upstream #375 (per-error-type thresholds, closed as low priority) and #9438/#31 (the seed). `docs/proposals/` has no resiliency or timeout proposal.

Samples run: `agent-scratch/cb_slow_calls.bal` (output in the finding).

### For the defect scanner
- `CircuitBreakerClient.submit` (`resiliency_http_circuit_breaker.bal` L315-L332) calls `getResponse` synchronously inside `submit` to update health, so `submit` through a circuit breaker is effectively blocking. It also consumes the response future before the caller's own `getResponse`. Check whether the caller's later `getResponse` still works and whether this is intended.
- `updateCircuitHealthFailure`/`updateCircuitHealthSuccess` (L489-L492, L506-L509) assign `lastUpdated` to a local copy (`lastUpdatedTime = lastUpdated`), so `Bucket.lastUpdatedTime` is never updated (there is a `//TODO:Get this verified` comment). Check whether bucket reset logic depends on it.
- `HALF_OPEN` handling (L421-L432) decides on `lastRequestSuccess` only when the next request arrives, and does not limit concurrent trial requests while half-open. Check whether multiple trials can pass through at once.
- Retry's extra sleep after the final attempt and the `maxWaitInterval` first-wait cap are already reported (known-issues).

## Unit `gap-similar-issue31-streaming-and-auxiliary-client-cancel`

- **Status:** completed
- **Selected because:** similar to issue:31
- **Claude:** 24 turns, 3.0 min

### Coverage

Find-similar run for seed #31 (no per-call deadline or cancel on the HTTP client), on streaming bodies, HTTP/2 futures and push promises, and auth handler internal clients.

| Area | Verdict |
|---|---|
| `getSseEventStream()` / SSE stream `close()` | **Gap, filed** as `response-stream-close-aborts-exchange`. `close()` does not abort the exchange. The sample shows the server still producing events at full rate 3 s after close, on HTTP/1.1 and HTTP/2. |
| `getByteStream()` `close()` on a partially read body | **Same gap, folded into that finding.** `ByteBufferInputStream.close()` only releases the current buffer. Measured with `getByteStream(8)` over HTTP/1.1. |
| `Response.close()`/discard for an unwanted body | Missing. Included in the same finding's proposal, not filed separately. |
| Deadline on body reads (timer outliving the `Response`) | Already in the seed proposal (#31): "the timer outlives the Response until the body is fully read". Not filed. |
| Cancel on `HttpFuture` from `submit()` | Already in the seed proposal (`client->cancel(HttpFuture)`). Not filed. |
| Rejecting/cancelling push promises | **Present.** `client->rejectPromise(PushPromise)` writes `RST_STREAM` for the promised stream (`DefaultHttpClientConnector.rejectPushResponse`, L128-L133). |
| SSE client heartbeat/idle bound | Present through the client `timeout` (inactivity timer) and §6.1 stall rules. Not filed. |
| SSE client auto-reconnect with `Last-Event-ID`/`retry` | Not part of the cancel/deadline pattern. Reconnect is not standard in OkHttp-sse or httpx-sse; browsers and undici `EventSource` do it. Not filed: weak demand and outside this pattern. A future SSE-specific unit could consider it. |
| OAuth2/JWT handler internal token clients: per-request timeout | Not applicable to this module. The token client lives in `ballerina/oauth2`. Upstream ballerina-library#8121 asked for a request timeout and was closed as completed, with global `globalConnectTimeout`/`globalReqTimeout` configurables in the oauth2 module. A per-call deadline on the token call would belong in oauth2. |
| Status-code client, failover and load-balance clients | Per-call options would need threading through them. That is already covered in the seed's implementation notes, so not filed. |

Samples run:
- `agent-scratch/sse_close.bal`: HTTP/1.1 SSE `close()`. The server produced 2 events at close and 31 three seconds later.
- `agent-scratch/stream_close_h2.bal`: HTTP/2 SSE `close()` produced 1 event at close and 31 later. HTTP/1.1 `getByteStream` `close()` produced 2 at close and 61 later; that counter also includes the still-running HTTP/2 stream.

Duplicate searches found nothing matching. Upstream ballerina-library was searched with: sse close connection, abort stream, getByteStream close, sse reconnect, oauth2 timeout. This repo was searched with: stream close. Related issues: #31 (seed), upstream #9317 (passthrough buffer leak when the caller disconnects), #9268 (pinning).

For the defect scanner:
- Spec §6.1 and the client sections never say what closing an inbound body stream does.
- `BytesToEventStreamGenerator.close()` sets `isClosed` only after `byteStream.close()` succeeds. If close fails, the generator keeps reading.
