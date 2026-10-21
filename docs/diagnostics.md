# Diagnostic codes and correlation

Updated21 October2026. Recent Activity in Settings is a bounded100-entry, newest-first list. Rows are full-width and left-aligned; Details exposes selectable event ID, build ID and source. Console uses subsystem `com.hidhogg.app`, category `diagnostics`; macOS manages persistence/retention.

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
