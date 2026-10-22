# Diagnostic codes and correlation

Updated22 October2026. Recent Activity in Settings is a bounded100-entry, newest-first list. Rows are full-width and left-aligned; Details exposes selectable event ID, build ID and source. Console uses subsystem `com.hidhogg.app`, category `diagnostics`; macOS manages persistence/retention.

## Following an error

1. Copy its code and event ID from Recent Activity. Search the same full ID in Console to find the persisted event. Build ID and source are identical in both representations.
2. Source is a sanitized module/file and line of emission. Use the recorded build when comparing source; line numbers can change between builds. An emission location identifies the reporting boundary, not necessarily the original throwing instruction.
3. Search the stable code in [DiagnosticCode.swift](../app/Sources/HidhoggApp/DiagnosticCode.swift), then its typed mapping/emitter below. An event ID identifies one entry across UI/Console; it does not imply every stage of an operation shares that ID.

| Code family | Meaning and code seam |
|---|---|
| `app.lifecycle.sleep`, `app.lifecycle.wake` | macOS sleep/wake notification handled by AppModel |
| `app.wake-reconnect.attempt`, `app.wake-reconnect.succeeded` | Bounded numbered discovery attempt and restored connection; normal settings reconciliation continues separately |
| `app.wake-reconnect.exhausted`, `app.wake-reconnect.cancelled` | Four readiness attempts exhausted, newer intent, or a safety/cleanup gate stopped recovery |
| `app.process.started` | Owner model/store started; DiagnosticsStore initialization |
| `app.instance.ownership-failed` | Pre-runtime ownership bootstrap failed; ApplicationInstanceBootstrap |
| `app.restart.failed` | Restart could not complete; HidhoggApp/RestartCoordinator reporter |
| `app.permission.status` | Accessibility/event-post snapshot; DiagnosticsStore model subscription |
| `app.error` | Redacted generic app failure; AppModel.reportError and recorded source |
| `configuration.validation.failed`, `configuration.load.failed`, `configuration.save.failed` | AppModel validated edit/load/save boundaries |
| `input.keyboard.succeeded`, `input.keyboard.failed` | Gated shortcut delivery; AppModel |
| `input.scroll.failed`, `input.thumbwheel.failed` | Independent gated wheel senders; AppModel |
| `bolt.status`, `bolt.cleanup.uncertain` | Main session transition or unverified cleanup |
| `bolt.wheel.status`, `bolt.thumbwheel.status` | Independent physical wheel status |
| `bolt.wheel.capture-blocked`, `bolt.thumbwheel.capture-blocked` | Independent capture blocker |
| `bolt.endpoint.unavailable`, `bolt.endpoint.ambiguous` | Candidate discovery/association |
| `bolt.request.timeout`, `bolt.disconnected`, `bolt.transport.failed` | Typed transport failure |
| `bolt.reply.malformed`, `bolt.controls.unsupported`, `bolt.state.external-change` | Typed reply/capability/foreign-state failure |
| `bolt.report.stale`, `bolt.events.overflow`, `bolt.operation.cancelled` | Admission/stream/lifecycle failure |
| `bolt.request-id.exhausted` | Insufficient unambiguous request capacity after uncertain outcomes |

Bolt failure codes travel through public `BoltFailureContext`/`BoltStatus.failure` and the actual AppModel publisher into DiagnosticsStore. They are not inferred from localized message text. Unknown localized transport errors normalize to the typed generic transport message. AppModel preserves existing UI errors while emitting separate controlled diagnostic messages. Shortcut contents, configuration values, raw error payloads and absolute source/build paths are not persisted. Static pre-store ownership failures use the same code/ID/build/source Console format.

Deduplication is by semantic channel: main Bolt transitions, permission, each wheel message and each capture blocker. Unchanged projections do not flood history; recovery/absence clears the relevant state, so a recurring error receives a fresh ID. Input wheel reports themselves do not log or mutate diagnostic history. Clear Recent Activity clears the in-memory list and fingerprints; it does not erase macOS Console history.

Verification uses injected sinks and temporary/injected models. Tests cover exact UI/Console ID/build/source matching, typed failure propagation, recurrence after recovery/absence, unrelated-channel dedup and unknown-error redaction. Native layout/Console presentation remain owner checks.

## History scope and sleep

Recent Activity contains up to100 events from the current process. Relaunch starts a new in-memory history; Console may retain older events under the subsystem/category above. A normal sleep stop shows Disconnected, not Failed. Device failures show Failed in Devices plus their typed diagnostic code here. A wake reconnect success confirms discovery, not completion of all preference/binding checks. Native sleep/wake verification remains an owner gate.

## Enable failure stages — CONN-01

Enable failures can include a typed optional stage in `BoltFailureContext.stage`. Recent Activity and persisted Console messages append `Failure stage: <stage>.` The stage identifies the attempted operation where the error was observed; it does not establish a physical cause or another application interfering. Existing failures outside the instrumented enable path retain no stage. Cancellation/admission-only errors are not attributed to a previous device check.

| Stable stage | Operation |
|---|---|
| `capabilities` | Cached capability verification or available-control validation |
| `vertical-wheel` | Existing vertical-wheel ownership verification |
| `thumb-wheel` | Existing thumb-wheel ownership verification |
| `button-baseline-back`, `button-baseline-forward` | Button baseline reporting check |
| `button-write-back`, `button-write-forward` | Button diversion write |
| `button-readback-back`, `button-readback-forward` | Reporting check after successful write |

Only enum names are added; raw traffic, device identifiers and state bytes are not recorded. All requests, guards, admission and cleanup behavior remain unchanged. The generic external-state message now says the observed device state differs from the expected state, without asserting button remapping or external interference.

Owner reproduction: run the updated signed app, reconnect once, and if it fails open Settings → Diagnostics & Recovery → Recent activity. Record `bolt.state.external-change`, the `Failure stage`, event ID and build. Existing source511 events cannot be retroactively classified. Diagnostic implementation tests do not prove the original connection issue is fixed.

### CONN-01 signed checkpoint — 2026-10-22

`dist/Hidhogg.app` build `357bb2389311cf48a3fc64958566fb273cc3c38c8b03f5a8612459ffc4f8a19c`; strict signature passed. Executable3,861,536 bytes, SHA256 `128573404055509073383bfc0dfa7066a209619485d1844f826a188368635797`;106 source/test/packaging hashes in dist/build-info.json. This adds diagnostics and neutral error wording; the original hardware failure is not fixed or reproduced by these tests.

Independent actual-checkout verification:193 XCTest with2 intentional native skips,137 Swift Testing passed on retry (328 ordinary passes). First attempt had one existing intermittent capture-state assertion at BoltThumbwheelTests.swift:451; cause remains unproven and no unrelated fix was made. Preserved `/Volumes/Data/tmp/hidhogg-connection-diagnostic-regression-attempt1.log`; green retry `/Volumes/Data/tmp/hidhogg-connection-diagnostic-regression.log`. Test-first missing-stage red used a copied fixture package; it is not actual-checkout behavior evidence. Final implementation and independent green checks ran against app/. No production launch/HID/config/login operations.

Owner action pending: run the fixed-path bundle, reconnect once and report the stage/code/eventID/build if it fails. Settings single-page change is deferred until connection issues are fixed.

### Owner reproduction — 2026-10-22

Owner screenshot from build357bb2389311 shows `bolt.state.external-change`, `Failure stage: button-baseline-back`, event `310AD34B-4294-48C2-8281-FCD3DAFCE349`, source BoltController.swift:520. The same session reports vertical-wheel and thumb-wheel settings unavailable before enable. Permissions were granted by the time of discovery. This establishes rejection of Back reporting before button mutation; the decoder may classify already-diverted, other flags or remapping as non-baseline. It does not prove an external app changed state or that reply parsing is correct. Await bounded read-only device-check approval to distinguish these; no guard relaxation.

### Read-only control-state evidence — 2026-10-22

Owner approved bounded direct-transport getter checks. First sequence at most11 requests; extended sequence at most15. Both completed successfully without setters, pairing/reset/firmware, raw-frame logging or identifiers. Back and Forward reporting: diverted, flags0x0001, remap0x0000. Vertical wheel root2121 version1 with advertised capability; mode diverted=true, highResolution=false, inverted=false. Thumbwheel root2150 version0, valid info decode; mode diverted=true, inverted=false. All roots meet existing controller checks. This explains current baseline rejection and unsupported wheel projections; it does not establish who set diversion.

Logs: `/Volumes/Data/tmp/hidhogg-readonly-bolt-probe-20261022.log`, `/Volumes/Data/tmp/hidhogg-readonly-bolt-modes-20261022.log`. Temporary opt-in probe removed from app tests and preserved as `/Volumes/Data/tmp/hidhogg-readonly-bolt-probe-20261022.swift`. Exact-name process-count check found one Hidhogg and no matches for logioptionsplus_agent/logioptionsplus; this is not proof no competing software exists. No process was stopped. Device state was not modified. Proposed correction is explicit Connect ownership reclamation of recognised diversion only; owner approved reclaim on Connect on2026-10-22; implementation in progress.

### Approved recovery decisions — CONN-01, 2026-10-22

Implementation in progress; final verification pending.

| Choice | Reason / alternative considered |
|---|---|
| Reclaim during Connect | Owner selected exclusive ownership; separate manual recovery button was the alternative |
| Full read preflight before setters | Unknown remap/flags must not cause partial takeover; blind reset rejected |
| Clear diversion to verified native routing, then normal reconciliation | Do not adopt an abandoned stream as if this process owned it |
| Preserve wheel mode bits; thumb raw second byte | Existing decoded thumb mode loses extra accepted bits on re-encoding; raw preservation is scoped to reclaim |
| Dedicated attempted-write journal in existing controller | Ordinary preference cleanup may restore the abandoned diverted state; no extra runtime or general transaction engine |
| Native-only bounded failure cleanup | Recovery must not reinstate diversion; unknown concurrent state remains untouched and cleanup uncertain |
| Verify capabilities/feature association and readback | Initial snapshot alone is insufficient across asynchronous device requests |

Existing normal preference/capture encoding is outside this reclaim correction unless independently required. Origin of the pre-existing diversion remains unknown. No live recovery mutation has been performed; hardware acceptance will be an owner check after signed packaging.

### Reclaim build ready for owner verification — 2026-10-22

Build `ce930217a62cb107be086313c35e0358aa0557362d30522ec7674e5a6a06e243` is signed at `dist/Hidhogg.app`; strict signature passed. Executable3,922,112 bytes, SHA256 `2e969ecfe7589ab17ae540ee271f10b3733d47d94c8b6a25e230622418f1faf3`.107-input manifest in dist/build-info.json and `/Volumes/Data/tmp/hidhogg-reclaim-source.json`. No production app launch or recovery writes against hardware were performed. The preceding getter checks established diverted device state; the source of that state remains unknown.

Connect now preflights eligible controls, modes and request capacity; rechecks capabilities/feature association; clears recognised diversion; and verifies native routing before Ready. Existing settings reconciliation then applies saved preferences. Unsupported feature roots remain optional; malformed recognised feature data, unknown flags or foreign remaps fail before recovery writes. Existing remap0/selfCID semantics are preserved. An attempted-write journal enables bounded native-only cleanup; cancellation can leave unattempted old diversion unchanged but cannot publish Ready or restore already-cleared diversion. Ready/idle status wording was intentionally corrected to match this behavior. No Views or schema changed.

Three new stable failure stages: `connect-preflight`, `connect-recovery-write`, `connect-recovery-readback`. The stage identifies an operation, not who caused prior diversion.

| Verification | Result |
|---|---|
| Actual-checkout behavioral red with recovery inactive | New tests failed with26 issues |
| Focused recovery/transport gate |127 SwiftTesting functions passed;12 new functions/27 parameter or singleton cases |
| Independent full suite |193 XCTest cases,2 intentional native skips;149 SwiftTesting passed; zero failures (340 ordinary passes) |
| Read-index fixture adjustments | Preserve original failure/pause operations; rollback/request/admission coverage retained |
| Native hardware correction | Pending owner reconnect, buttons and both wheels |

Logs `/Volumes/Data/tmp/hidhogg-reclaim-red.log`, `hidhogg-reclaim-final.log`, `hidhogg-reclaim-independent.log`, `hidhogg-reclaim-release.log`. The current full run required no retry. Earlier intermittent capture-test evidence remains recorded in the preceding diagnostic checkpoint.

Owner checklist: quit the older instance; open fixed-path dist/Hidhogg.app; Connect or allow configured launch connection; confirm Ready and saved Back/Forward plus both wheel settings; Disconnect/reconnect once. If failure recurs, report stage/code/eventID/build. UI one-page Settings remains deferred until this connection correction is accepted. Source uncommitted; no push.

Deferred finding: normal thumb-wheel preference encoding can drop accepted second-byte bits1/2 after reclaim; this pre-existing path is unchanged. Recovery itself preserves the full valid raw second byte. No broader thumb-wheel protocol change is claimed.

### Owner acceptance — 2026-10-22

Owner reports everything working after the signed reclaim build, accepting the requested reconnect/buttons/wheels check. CONN-01 is complete. This is owner-reported acceptance, not an agent hardware mutation test. Single-page Settings is the next approved change.
