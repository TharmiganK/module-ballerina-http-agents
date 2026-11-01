# Weekly analyser: `sse-streaming`

- **Date:** 2026-11-01 07:20 UTC
- **Commit:** `e11e275522d6`
- **Selected because:** requested
- **Agent job:** success
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41283781283
- **Claude:** 53 turns, 6.9 min

## Issues
- Filed (bug): [text/event-stream response body loses all bytes after the last "\n\n" (CRLF-framed streams arrive empty)](https://github.com/TharmiganK/module-ballerina-http-agents/issues/5)
- Filed (bug): [SseEvent comment/event/id containing a line break produce malformed SSE output or extra events](https://github.com/TharmiganK/module-ballerina-http-agents/issues/6)
- Filed (bug): [SSE client merges events when the blank line uses a different line terminator (\n\r\n, \r\n\r)](https://github.com/TharmiganK/module-ballerina-http-agents/issues/7)
- Filed (spec): [Spec 2.3.5.3 does not describe SSE serialization, error events or client-side SSE consumption](https://github.com/TharmiganK/module-ballerina-http-agents/issues/8)

## Security
- 0 found, 0 delivered privately

## Coverage

### Scope: sse-streaming

**Spec read:** §2.3.5.3 (Return SSE stream) and §6.1 (Message body streaming and back-pressure).

**Implementation read:**
- `ballerina/bytes_to_sse_stream_generator.bal`, `ballerina/sse_to_bytes_stream_generator.bal`, `ballerina/http_back_pressure.bal`
- The SSE call path in `http_client_endpoint.bal` (`processResponse`, `getSseEventStream`, `validateEventStreamContentType`), `http_response.bal` (`setSseEventStream`, `getSseEventStream`), the `SseEvent` type in `http_types.bal`, and `init.bal`
- Native: `HttpMessageDataStreamer` (event-stream output stream), `HttpUtil.hasEventStreamContentType`, `ExternBackPressureConfig`, and `Util.setMaxBackPressureStallTime` / `isWithinBackPressureStallLimit` / `remainingBackPressureStallNanos`

**Tests read:** `ballerina-tests/http-advanced-tests/tests/server_sent_event_tests.bal`. They cover headers, client binding on all methods, and the error-event ending. They do not cover CRLF framing, multi-line or newline-bearing fields, non-SSE payload setters with `text/event-stream`, or mixed line terminators. Back-pressure has extensive native tests (`BackPressureAwareIdleStateHandlerTest`, `BackPressureStallLimitTestCase`, `Http2ClientBackPressureStallLimitTestCase`, `PassthroughBackPressureListenerTest`).

**What I ran:**
- `.github/scripts/run-tests.sh bal http-advanced-tests analyser_2_1,analyser_2_2,analyser_2_3`, twice. On the final run all 7 reproduction tests fail with the expected assertion messages.
- Scratch samples `agent-scratch/crcase.bal` and `agent-scratch/cr2.bal`. These isolated the event-stream writer data loss: the same bodies arrive intact with `text/plain` and empty or truncated with `text/event-stream`.

The reproductions are in `ballerina-tests/http-advanced-tests/tests/sse_parsing_test.bal`, with new ports 9771–9773 in `test_service_ports.bal`.

**Scope note on finding 1:** its root cause is in `native/.../transport/message/HttpMessageDataStreamer.java` (`EventBufferOutputStream`), outside the unit's listed paths. I kept it because it is the SSE response write path of this unit (§2.3.5.3, \"Server-sent events and payload streaming\"). I only verified it over HTTP/1.1.

**Candidates dropped:**
- Client rejecting a mixed-case `Content-Type: Text/Event-Stream` (`startsWith` is case-sensitive): not reproducible end to end, because the content type set through `setTextPayload` reaches the client lowercased. My test passed, so I dropped it.
- Multiple `data:` lines joined without `\
`: duplicate of #1.
- Field names trimmed in `parseSseEvent` (`\" data: x\"` is accepted although the WHATWG grammar would ignore it), a leading UTF-8 BOM not stripped, and `retry` accepting a sign (`int:fromString(\"+5\")`): minor deviations from WHATWG with little user impact. Not filed.
- `getNextByte` indexing `value[0]` on a possibly empty chunk: `getByteStream(1)` never yields empty arrays in practice. Not reproducible.
- Events with no `data` being delivered: a deliberate Ballerina behaviour, included in the spec finding rather than reported as a bug.
- Back-pressure (`maxBackPressureStallTime` conversion and limit checks): the code matches §6.1 (negative means unlimited, zero means no allowance, the allowance restarts on progress) and is covered by native tests. No discrepancy found.
