# Find-similar run 6 for pr:9

- **Date:** 2026-11-01 12:23 UTC
- **Commit:** `fc44c504aa7d`
- **Units:** `similar-pr9-media-type-params-ballerina-client`, `similar-pr9-media-type-params-ballerina-service`, `similar-pr9-media-type-params-native` (3 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41305357401

## Issues
- Filed (similar-pr9-media-type-params-ballerina-client, bug): [Client sends a map payload as JSON when mediaType is form-urlencoded with a charset or different case](https://github.com/TharmiganK/module-ballerina-http-agents/issues/21)
- Filed (similar-pr9-media-type-params-ballerina-client, bug): [Client rejects SSE responses whose Content-Type is not lowercase `text/event-stream`](https://github.com/TharmiganK/module-ballerina-http-agents/issues/22)
- Filed (similar-pr9-media-type-params-ballerina-client, bug): [Error detail body is a string, not JSON, for 4xx/5xx responses with `application/problem+json`](https://github.com/TharmiganK/module-ballerina-http-agents/issues/23)
- Filed (similar-pr9-media-type-params-ballerina-service, bug): [Service sends map<string> as JSON when form-urlencoded mediaType has parameters or mixed case](https://github.com/TharmiganK/module-ballerina-http-agents/issues/24)
- Filed (similar-pr9-media-type-params-native, bug): [`produces` check rejects an Accept `type/*` range with 406 when the type's letter case differs](https://github.com/TharmiganK/module-ballerina-http-agents/issues/25)

## Security
- 0 found, 0 delivered privately

## Unit `similar-pr9-media-type-params-ballerina-client`

- **Status:** completed
- **Selected because:** similar to pr:9
- **Claude:** 29 turns, 4.3 min

### Coverage

**Mode:** find-similar, seeded by PR #9 (response `performDataBinding` compared Content-Type without stripping parameters or normalising case). The seed locations (`http_client_payload_builder.bal`, `http_client_url_encoded_content_test.bal`) were excluded.

**Examined:** spec §2.4.2.1, §2.4.2.3, §2.4.3 and §2.4.1.9; `ballerina/http_commons.bal`, `http_client_endpoint.bal`, `http_status_code_client.bal`, `http_request.bal`, `http_response.bal` (for call sites), `resiliency_failover_client.bal`, `resiliency_load_balance_client.bal` (call sites), `http_constants.bal`. I grepped these files for `startsWith`, `== mime:`, `match` on media types and `mime:getMediaType`.

**Places checked for the pattern:**
- `http_commons.bal:113-126` `buildRequest`: `match mediaType` exact against `mime:APPLICATION_FORM_URLENCODED`. **Affected** (finding 1). This is shared by every entity-body method of `Client`, `StatusCodeClient`, `FailoverClient` and `LoadBalanceClient`.
- `http_client_endpoint.bal:843-848` `validateEventStreamContentType`: case-sensitive `startsWith`. **Affected** (finding 2).
- `http_client_endpoint.bal:693-727` `getPayload`: lowercases and uses `mime:getMediaType`, so parameters and case are handled correctly. However, the exact `subType` match misses `+json`/`+xml` suffixes, unlike `JSON_PATTERN`/`XML_PATTERN`. **Affected** (finding 3, a related inconsistency). `text/json` and `text/xml` also become strings here, which I mention in finding 3's body rather than report separately.
- `http_commons.bal:342-350` `isMultipartRequest`/`isNestedEntity`: case-sensitive `startsWith(\"multipart/\")`, used by failover and load-balance request rebuilding. When the check misses, the request takes the non-multipart branch, which buffers the whole entity with `getBinaryPayload()`, so the body is still replayable. I found no user-visible failure, so I did not reproduce or report it.
- `http_request.bal:372-389` `getFormParams`: correct (the reference implementation).
- The `startsWith` calls in `http_request.bal:596-602` are on Cache-Control directives, not media types, so they are out of scope.
- `http_status_code_client.bal`: delegates to `buildRequest` and `getPayload`, and is covered by findings 1 and 3.

**Ran:** `.github/scripts/run-tests.sh bal http-client-tests analyser_6_1,analyser_6_2,analyser_6_3`. All 4 new tests failed with the expected messages:
- form-urlencoded with charset or mixed case: the body was sent as `{\"key\":\"value\"}`.
- `Text/Event-Stream`: `PayloadBindingError ... not of text/event-stream content type`.
- `problem+json` error: the body was a string.

The tests are in `ballerina-tests/http-client-tests/tests/client_media_type_params_test.bal`, with port constant `clientMediaTypeParamsTestPort = 9871` in `test_service_ports.bal`.

**Duplicate check:**
- `agent-context/known-issues.json`: #4 here and ballerina-library#7292 cover the response-side charset data-binding problem (the seed), not request building. The SSE issues (#1, #5, #6, #7 here; ballerina-library#9269, #9270, #9340, #9341) concern framing and parsing, not Content-Type matching.
- ballerina-library searches for `event-stream`, `problem+json` and `urlencoded charset`: no matching report.
- Open PRs in ballerina-platform/module-ballerina-http (searched for `content-type` and `media type`): none.

**Not reported:** a `Content-Type` set via the `headers` map (rather than `mediaType`) is ignored when choosing between URL-encoded and JSON encoding. This looks like a design choice (the spec gives `mediaType` priority), not this pattern.

## Unit `similar-pr9-media-type-params-ballerina-service`

- **Status:** completed
- **Selected because:** similar to pr:9
- **Claude:** 20 turns, 2.6 min

### Coverage

### Scope
Find-similar run seeded by PR #9: the client payload builder compared a raw Content-Type value against bare, lowercase media types. I hunted for the same root cause in the service-side response building code.

**Spec sections read:** 2.3.4.4, 2.3.5 (Return types), 2.3.5.1 (Status Code Response), 4.3 / 4.3.2 (Payload annotation, anydata return value info).

**Files examined:** `ballerina/http_connection.bal`, `ballerina/http_response.bal`, `ballerina/http_status_error_utils.bal`, `ballerina/http_interceptors.bal`. Existing tests read: `http-misc-tests/tests/url_encoded_responses_from_service_test.bal`, which only uses the bare `mime:APPLICATION_FORM_URLENCODED`.

### Places checked for the pattern
- `http_connection.bal` `processAnydata` (L338-360): **affected**. `match mediaType { mime:APPLICATION_FORM_URLENCODED => ... }` is an exact string match. A `mediaType` with parameters or a different case falls through to `setJsonPayload` while the Content-Type header still says form-urlencoded. Reported as finding 1.
- Callers of `processAnydata`, which all pass the raw value:
  - the anydata return path in `respond` (L175-179) passes the untrimmed `returnMediaType` from `@http:Payload`;
  - `createStatusCodeResponse`/`retrieveMediaType` (L227-255) only trims;
  - `getErrorResponse` in `http_status_error_utils.bal` (L39-60, status-code errors with `@http:Payload` media type) uses `setPayload` with `returnMediaType`.
  
  All of these share the one root cause, so they are covered by finding 1.
- `http_response.bal` `addHeader` (L132): uses `equalsIgnoreCaseAscii` on the header *name*. **Not affected.** `setHeader`/`setContentType`/`getContentType` do no value comparisons. `buildStatusCodeResponse` passes `mediaType` to native code (client side, outside this unit).
- `http_interceptors.bal`: no media-type comparisons. **Not affected.**
- `http_commons.bal` `buildRequest` and `http_client_endpoint.bal` (client side; the latter already uses `mime:getMediaType(value.toLowerAscii())`): outside this unit, not examined further.

### Run
Ran `.github/scripts/run-tests.sh bal http-service-tests analyser_6_1`. All 3 new tests in `ballerina-tests/http-service-tests/tests/url_encoded_media_type_params_test.bal` fail. In each, the body is `{"key1":"value1"}` instead of `key1=value1`, and the Content-Type assertions that run before the body checks passed.

### Dedup
- `known-issues.json`: #4 (this repo) and ballerina-library#7292 cover **client** data binding with a charset, which is the seed and is a different code path. The other urlencoded issues are about request binding or feature requests for status-code urlencoded support (already implemented).
- Searches with no relevant hits: ballerina-library "urlencoded charset" and "mediaType charset", the agents repo "urlencoded" (only #4), and upstream module-ballerina-http PRs for "urlencoded mediaType" and "form-urlencoded charset".

### Dropped
- `processAnydata` raises `InitializingOutboundRequestError` (a request error) for non-`map<string>` payloads on a response. This is a minor naming inconsistency, not the pattern, so it was not reported.

## Unit `similar-pr9-media-type-params-native`

- **Status:** completed
- **Selected because:** similar to pr:9
- **Claude:** 64 turns, 8.1 min

### Coverage

### Scope
Find-similar run for seed PR #9: media types compared without stripping parameters or normalising case. I read the scope hints and the unit paths `HttpUtil.java`, `ResourceDataElement.java`, `HttpResource.java`, `ResponseWriter.java`, `ExternResponseProcessor.java` and `AbstractPayloadBuilder.java`. I also read the existing tests in `http-dispatching-tests/tests/service_dispatching_produces_consumes_test.bal` and `http-advanced-tests/tests/service_configuration_compression_annotation_test.bal`, and spec §4.3.1/§4.3.2 (consumes/produces) and §2.4.1.9.

### Places checked for the pattern
- **`HttpUtil.populateEntityBody` (L312), inbound multipart, `startsWith(\"multipart/\")`:** not affected. The scratch sample `agent-scratch/mp.bal` sent `Multipart/Mixed; boundary=…` and `MULTIPART/FORM-DATA; boundary=…` to a service calling `getBodyParts()`, and both parsed correctly; the mime module covers the fallback.
- **`HttpUtil.addBoundaryParameter` (L1208), outbound multipart:** not affected. `setBodyParts(parts, \"Multipart/Mixed\")` went out as `multipart/mixed; boundary=…` and the receiver parsed it, because mime lowercases the value and adds a boundary before this code runs.
- **`HttpUtil.isContentTypeMatched` / compression `contentTypes` (L1055):** not affected for case. `getAsStringList` (L1060-L1069) trims and lowercases the configured values, and the response header is lowercased too. A temporary reproduction with `contentTypes: [\"Application/Json\"]` passed (its file was emptied afterwards). Two remaining points are minor and not reported: `contains` is a substring match on the full header, and `Locale.getDefault()` is used rather than `Locale.ROOT`.
- **`HttpUtil.hasEventStreamContentType` (L2047), `startsWith(\"text/event-stream\")`:** parameters are fine because it is a prefix match. Case matters only if a user sets `Text/Event-Stream` by hand, since the library itself always emits lowercase. I judged this too marginal to report and did not reproduce it.
- **`ResourceDataElement.validateConsumes`:** not affected. It uses `equalsIgnoreCase` on the trimmed part before `;`.
- **`ResourceDataElement.validateProduces`, exact branch:** not affected (`equalsIgnoreCase`).
- **`validateProduces`, wildcard branch, plus `HttpResource.setProduces` subtypes:** affected and reported, reproduced as `[200,406,406]`.
- **Whitespace in `produces` values (`\"application/xml \"`, `\" application/xml\"`, where `setProduces` computes `indexOf` on the untrimmed string):** my reproduction (`analyser_6_2`) passed, so the values are evidently trimmed before they reach native code. Not reported; the test was removed.
- **`ExternResponseProcessor.getMediaType`:** binds the raw `Content-Type`, including any parameters, into the status-code record's `mediaType` field. The spec (§2.4.1.9) does not define the semantics, and binding the actual header verbatim is plausible by design. This is outside the unit's spec sections, so it is not reported.
- **`AbstractPayloadBuilder`:** the reference implementation, already correct.

### Runs
- `bal run agent-scratch/mp.bal` (multipart, inbound and outbound).
- `run-tests.sh bal http-dispatching-tests,http-advanced-tests analyser_6_1,analyser_6_2,analyser_6_3`, then reruns. `analyser_6_1` fails as expected; `analyser_6_2` and `analyser_6_3` passed, so those candidates were dropped.
- I could not delete the dropped compression test file (`rm` was not permitted), so `ballerina-tests/http-advanced-tests/tests/compression_content_type_case_test.bal` is left as a comment-only placeholder that is safe to delete.

### Dedup
- `known-issues.json`: no produces/Accept case issue. The nearest are library #525 (produces-based content negotiation for errors, unrelated) and library #521 (compression improvements, unrelated).
- GitHub searches found no duplicate: `produces accept case` and `produces wildcard accept` in ballerina-library; `produces accept` in the mirror; and open `produces` PRs in module-ballerina-http.
