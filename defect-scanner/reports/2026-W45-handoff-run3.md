# Handoff run 3 (defect scanner)

- **Date:** 2026-11-02 08:15 UTC
- **Commit:** `6d5a76fe6068`
- **Units:** `handoff-gap5-cb-half-open-stale-trial-decision` (1 completed)
- **Run:** https://github.com/TharmiganK/module-ballerina-http-agents/actions/runs/41410973868

## Issues
- Filed (handoff-gap5-cb-half-open-stale-trial-decision, bug): [Circuit breaker HALF_OPEN rejects requests on stale state and sends extra trials while the trial is in flight](https://github.com/TharmiganK/module-ballerina-http-agents/issues/79)

## Security
- 0 found, 0 delivered privately

## Unit `handoff-gap5-cb-half-open-stale-trial-decision`

- **Status:** completed
- **Selected because:** handed off by the gap scanner run 5 (unit client-resiliency)
- **Claude:** 25 turns, 3.0 min

### Coverage

### Handoff verification: `handoff-gap5-cb-half-open-stale-trial-decision`

**Examined:** spec §2.4.1.5 (it only shows a config example and says nothing about HALF_OPEN semantics); `ballerina/resiliency_http_circuit_breaker.bal` in full, in particular `updateCircuitState()` (L408-L450), `switchCircuitStateOpenToHalfOpenOnResetTime()` (L671-L683), `handleOpenCircuit()` (L453-L461), `updateCircuitHealthSuccess/Failure()`, and the `CircuitState`/`CB_HALF_OPEN_STATE` API docs (L20-L33). I also looked over the existing circuit breaker tests in `http-resiliency-tests` (`resiliency_http_circuit_breaker_test_*.bal`). None of them sends requests while a HALF_OPEN trial is still running.

**Verdict: the handoff holds (concurrent part).** Reproduced with the new test `testCircuitBreakerHalfOpenConcurrentTrial` (group `scanner_3_1`) in `ballerina-tests/http-resiliency-tests/tests/resiliency_http_circuit_breaker_half_open_test.bal`, using new port constant 9863. Ran `.github/scripts/run-tests.sh bal http-resiliency-tests scanner_3_1`, and it failed with: `HALF_OPEN let 2 requests reach the backend while the trial was in flight; second request: Upstream service unavailable. Requests to upstream service will be suspended for -1 seconds.; third request: response 200`. The second request is rejected because of the stale `lastRequestSuccess=false`, and the error reports a negative suspension time. The third request then flips OPEN→HALF_OPEN again, because `lastErrorTime` is old, and goes to the backend as a second trial. The trial itself succeeded.

**Second half of the handoff (unbounded trials when `totalRequestsCount < requestVolumeThreshold`):** confirmed by reading the code only. In the `else` branch at L442-L445, HALF_OPEN is never resolved, so every request passes until the volume threshold is reached. I did not write a separate reproduction. I folded it into the same finding as a related symptom of the same decision logic and did not file it separately.

**Duplicate checks:** `known-issues.json` has circuit breaker items (#66 slow-call thresholds, gap; upstream ballerina-library #339, #340, #375). None is about the HALF_OPEN trial logic. GitHub searches: `circuit breaker half open` and `circuit breaker concurrent` in ballerina-platform/ballerina-library returned only unrelated flaky-test issues (#305, #317). `circuit breaker` in TharmiganK/module-ballerina-http-agents returned #66, #31, #20 and #77, all unrelated gaps. Open PRs in ballerina-platform/module-ballerina-http matching `circuit breaker`: none.
