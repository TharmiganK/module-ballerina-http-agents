# Handoff run 5 (defect scanner)

- **Date:** 2026-11-03 08:32 UTC
- **Commit:** `ad64ade67e37`
- **Units:** `handoff-defect4-request-add-cookies-ascending-path-order`, `handoff-defect4-request-cache-control-parse-case-and-mul`, `handoff-defect4-http2-stream-id-header-leaks-into-http11` (3 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41603242527

## Issues
- Filed (handoff-defect4-http2-stream-id-header-leaks-into-http11, bug): [HTTP/2 client exposes internal `x-http2-stream-id` header, which leaks to downstream HTTP/1.1 callers](https://github.com/TharmiganK/module-ballerina-http-agents/issues/109)
- Filed (handoff-defect4-request-add-cookies-ascending-path-order, bug): [Request.addCookies and the cookie-enabled http:Client list shorter-path cookies before longer-path ones](https://github.com/TharmiganK/module-ballerina-http-agents/issues/110)
- Filed (handoff-defect4-request-add-cookies-ascending-path-order, bug): [Request.addCookies replaces the existing Cookie header, dropping caller-set cookies in cookie-enabled clients](https://github.com/TharmiganK/module-ballerina-http-agents/issues/111)
- Filed (handoff-defect4-request-cache-control-parse-case-and-mul, bug): [Caching client ignores request Cache-Control directives in non-lowercase or on extra header lines](https://github.com/TharmiganK/module-ballerina-http-agents/issues/112)

## Security
- 0 found, 0 delivered privately

## Unit `handoff-defect4-request-add-cookies-ascending-path-order`

- **Status:** completed
- **Selected because:** handed off by the defect scanner run 4 (unit headers-payload)
- **Claude:** 23 turns, 3.5 min

### Coverage

**Mode: handoff** (from defect scanner run 4, unit headers-payload). The lead held: it is reported as finding 1, and the sub-point about overwriting the header is reported separately as finding 2.

**Examined**
- `ballerina/http_request.bal` `addCookies` / `getCookies` (L628-L664).
- `ballerina/cookie_http_client.bal` (`addStoredCookiesToRequest`, and `CookieClient` methods that call it before every request).
- `ballerina/cookie_utils.bal`: an unused `comparator` (L79-L95) cites RFC 6265 §5.4 and sorts longer paths first, then by creation time. This shows the intended order.
- Spec §7 (Header and Payload) and §2.4.1.6 (Cookie): neither describes the `Cookie` header order or whether it is merged.
- Existing tests: `http-service-tests/.../service_native_in_request_function.bal#testAddCookies` asserts the current ascending order. Finding 1 notes that this test needs updating. `http-advanced-tests` cookie tests have no ordering or merge coverage.

**Ran**
- `.github/scripts/run-tests.sh bal http-advanced-tests scanner_5_1,scanner_5_2` with the new file `ballerina-tests/http-advanced-tests/tests/cookie_header_order_test.bal` (ports 9255 and 9256, unused elsewhere). All 5 tests fail with the expected messages:
  - `short=1; long=2` where `long=2; short=1` was expected.
  - `session=root; session=app` where `session=app; session=root` was expected.
  - `Cookie header was: stored=2`: the `manual=1` the caller set was dropped, both on `Request` and through the cookie client.
  - `second=2` only, after `addCookies` was called twice.

**Classification**
- Ordering is filed as a bug rather than a question. The module's own RFC-citing comparator shows the descending order was intended, and same-name cookies make the impact concrete. The conflicting existing test is called out in the body.

**Duplicate checks**
- `known-issues.json`: cookie issues #26, #27, #28, #30, #41, #68, library #303, #337, #343, #509, #541, #6194, #6788, #7807. None covers header order or overwriting. #26 is a related umbrella cookie issue about expiry, clearing and opt-out, not this.
- Searches: `cookie order path` and `addCookies` in ballerina-library; `cookie header overwritten/replaced`; `cookie` across this repo. No matches.
- Upstream module-ballerina-http PRs: open PRs searched for `cookie`, all PRs for `addCookies`. None found.

**Not reported**
- `addCookies` has no creation-time tie-break for equal path lengths. This is folded into the suggested resolution of finding 1, not filed separately.

## Unit `handoff-defect4-request-cache-control-parse-case-and-mul`

- **Status:** completed
- **Selected because:** handed off by the defect scanner run 4 (unit headers-payload)
- **Claude:** 24 turns, 2.5 min

### Coverage

**Mode: handoff** (from defect scanner run 4, unit headers-payload): \"Request cache-control parsing ignores case and additional Cache-Control header lines\". **The lead holds; it is reported as the finding `request-cache-control-parse-case-and-multiline`.**

**Examined**
- `ballerina/http_request.bal` `parseCacheControlHeader` (L576-609). It compares directives case-sensitively, and `getHeader` reads only the first field line.
- `ballerina/caching_http_caching_client.bal` `getCachedResponse` (L269-340). This is where the parsed request cache control decides between serving from cache, revalidating and storing.
- `caching_request_cache_control.bal`, and `http_response.bal` (the response side is not parsed in Ballerina).
- Spec section 7 and the caching client section of `docs/spec/spec.md`.
- Existing caching tests in `http-advanced-tests`.

**Ran**
- `.github/scripts/run-tests.sh bal http-advanced-tests scanner_5_1`: 1 passing, 2 failing, as expected.
  - Control: lowercase `no-cache` revalidates (backend hits = 2).
  - `No-Cache`: backend hits = 1 (expected 2).
  - `no-cache` on a second header line: backend hits = 1 (expected 2).

**Response side (asked in the handoff)**
- Inbound responses are parsed natively: `HttpUtil.java` L854-858 calls `inboundResponseMsg.getHeader(CACHE_CONTROL)`, followed by `CacheControlParser.parse` and `CacheControlDirective.parseValue`. This also reads only the first field line. Whether `parseValue` matches case-insensitively was not checked.
- This code is under `native/`, outside this unit's paths, and was not reproduced here. A response-side issue would need its own run.
- The inbound-request equivalent in `HttpUtil.java` L759 (service side) has the same first-line-only read. It is also native and out of scope.

**Dedup**
- `known-issues.json`: cache-related issues are about ETag quoting, the cache key / `Vary`, spec 2.4.1.2, conditional requests, only-if-cached, and duplicate directives in freshness (ballerina-library#357, a different issue). None covers case or multi-line parsing.
- Searches of TharmiganK/module-ballerina-http-agents and ballerina-library (`cache-control case`, `no-cache case-insensitive`, `Cache-Control directive`) found nothing matching.
- No open upstream PRs in module-ballerina-http matched `cache-control`.
- Related but different: #67 (Age header ignored).

## Unit `handoff-defect4-http2-stream-id-header-leaks-into-http11`

- **Status:** completed
- **Selected because:** handed off by the defect scanner run 4 (unit interceptors-errors)
- **Claude:** 24 turns, 2.8 min

### Coverage

### Handoff verification: `x-http2-stream-id` leaking into HTTP/1.1 (from defect scanner run 4)

**Verified: the handoff holds.** Reported as one bug finding.

Examined:
- Spec §2.4 (Client): the client uses HTTP/2 by default, and the spec mentions no synthetic headers.
- `native/.../sender/states/http2/ReceivingHeaders.java`: `setupResponseCarbonMessage` and `onTrailersRead` both call `HttpConversionUtil.addHttp2ToHttpHeaders`, which adds `x-http2-stream-id`.
- `native/.../common/Util.java`, `createHttpRequestFromHttp2Headers`: the listener-side equivalent for inbound HTTP/2 requests. Mentioned in the finding as a sibling location for the fix.
- `Http2StateUtil` and both `SendingHeaders` classes: they only add or read `x-http2-scheme` and the priority extension headers on outbound messages. A search for `ExtensionHeaderNames` and `x-http2` across `native/` and `ballerina/` finds no code that strips these headers.
- `sender/http2/*` (ClientFrameListener, Http2TargetHandler): they route frames to the states above.

Ran `.github/scripts/run-tests.sh bal http2-tests scanner_5_1` twice. The tests are in the new file `ballerina-tests/http2-tests/tests/http2_extension_header_leak_test.bal`, and ports 9741/9742 were added to `test_service_ports.bal`. Both tests fail with the expected assertion: `internal x-http2-stream-id header leaked: [\"1\"]` for the passthrough and `[\"3\"]` for the propagated `ApplicationResponseError` 404.

Duplicate checks:
- `known-issues.json`: no match for `stream-id` or `x-http2`.
- Searched `x-http2-stream-id` (also as an exact phrase) in `ballerina-platform/ballerina-library` and `TharmiganK/module-ballerina-http-agents`. The library results (#7298, #7791, #8279, #7550, #6872, #5375, #3543, #3507, #486) are unrelated by title and match loosely on the search terms. The mirror returned nothing.
- Searched `ballerina-platform/module-ballerina-http` PRs for `x-http2-stream-id` and for `http2 header leak passthrough` (open): nothing found.

Not verified separately:
- The request direction: an HTTP/2 inbound request forwarded to an HTTP/1.1 backend. The root cause is the same conversion call, on the listener side.
- Trailers: `onTrailersRead` uses the same function.
