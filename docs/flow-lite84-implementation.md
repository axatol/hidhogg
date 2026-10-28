# FL-01 — native read-only status implementation

## 28 October 2026 — useful battery events and reply correlation

The owner reported an intermittent `unexpected command 4 reply` and approved keeping useful battery data rather than dropping it. The old reader failed closed for a battery reply arriving without a pending query or during a different read; both cases were reproduced with fake receivers before the fix.

The revised reader processes the current matching request first, retaining its status/payload validation and confirmed-send barrier. Fully valid identity-confirmed battery updates outside that request update battery data and the host received-at timestamp without completing, extending or issuing a query. Unsolicited partial/rejected battery frames leave the last useful reading unchanged. Solicited partial/unavailable fields retain their original semantics. Globally valid off-current ordinary read replies are ignored; global checksum/schema/read-scope failures and wrong/rejected identity remain fatal. Vendor command10 behaviour is unchanged.

Session-local receipt order prevents a later batch commit from overwriting newer battery telemetry, including when two receipt Dates are equal. Full status time remains separate. The page now labels battery freshness **Battery received**; packet origin (late, duplicate or unsolicited) and actual device sample time remain unknown. No traffic, setting writes or retries were added; read retransmission remains unapproved. [Approval and alternatives](flow-lite84-read-reliability-plan.md).

Independent verification passes 69 focused checks (56 module, 13 model), with all 12 scoped input hashes unchanged and no owned compiler/test processes remaining. Signed app/CLI build `c7c485f779318576457313ef0b9da097aadab13be860f22c71016d9f9749f19f` passes strict signatures; 211 input hashes (now including the package lockfile) are recorded in `dist/build-info.json`. Red logs: `/Volumes/Data/tmp/hidhogg-battery-red.log`, `/Volumes/Data/tmp/hidhogg-battery-pending-red.log`. Worker green: `/Volumes/Data/tmp/hidhogg-battery-final.log`; independent logs: `/tmp/hidhogg-fl-rx-independent-lofree.log` and `/tmp/hidhogg-fl-rx-independent-model.log`; release: `/Volumes/Data/tmp/hidhogg-battery-events-release-20261028.log`. No live HID, app restart or physical acceptance is claimed.

## Original implementation — 26 October 2026

26 October 2026. Owner approved implementation and bounded receiver queries after the feasibility review. Feature branch: next/lofree-flow-lite84, based on published master f5bb00f. Keep the existing uncommitted research documentation.

## 27 October 2026 — activity-driven refresh follow-up

The owner approved adding the keyboard to the existing Connect on launch preference and replacing proposed periodic polling with event-driven, hourly-throttled battery refresh. Independent offline verification passes 75 focused checks: 43 Lofree module tests, 13 model tests and 19 startup tests. All 16 scoped input hashes matched before/after verification, and no owned build/test process remained. Signed app/CLI build `fc98d1aed0f64203f5b38087b58150ae5b7e06036145635d644f759a3b26c433` passes strict signature verification; 210 input hashes are recorded in `dist/build-info.json`. Owner validation remains pending. This supersedes the original explicit-only startup/refresh boundary below.

- Production composition injects global and local AppKit key-down monitors; test models default to an inert monitor. Callbacks ignore characters and key codes, and local events are returned unchanged. Activity from any keyboard qualifies. There is no polling timer or idle device query. Key-event monitoring outside the app is subject to macOS Accessibility authorization; manual Refresh remains usable. [Apple event-monitor documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html).
- The first activity at least one hour after the latest accepted snapshot or automatic attempt starts a battery/status-only read. The attempt claims its throttle before starting; busy operations cannot overlap. The reader queries online status, then battery only when online, preserving full metadata and its timestamp. A separate battery-read timestamp records battery freshness.
- Explicit manual Refresh still reads the full status. Sleep, suspension, explicit Disconnect, stop and deinitialization remove activity monitors; reconnect reinstalls them. An explicit keyboard connection decision made before initial configuration loading finishes prevents launch auto-connect from overriding it.
- Existing receiver-pushed status-change notifications can still request a full refresh. The hourly battery-only throttle applies to keyboard-activity triggers, not manual Refresh, connection initialization or these pre-existing vendor notifications. No timer requests status while idle.
- Alternatives: periodic hourly/ten-minute device queries were rejected in favour of no idle traffic. Polling macOS's local activity timestamp was superseded by event monitors at the owner's request. Device-specific HID activity was deferred because any-keyboard activity was accepted and does not require expanding receiver input parsing.
- Actual battery cost, event delivery under secure input, and physical-device acceptance are unmeasured. The existing strict response validation remains unchanged; this work does not implement the separately pending generalized reply-correlation/read-retry plan.

Independent logs: `/tmp/hidhogg-activity-independent-lofree.log`, `/tmp/hidhogg-activity-independent-model.log`, `/tmp/hidhogg-activity-independent-startup.log`. No live input monitor, permission prompt, app launch or HID operation was exercised. Native event registration and physical acceptance are distinct from these fake/codec/model tests.

## Boundary

Add one receiver-specific native device module and status page alongside Logitech/D200X. Show reported battery/charging/voltage, keyboard/receiver versions and targeted lighting/current-system snapshots. Connect and Refresh are explicit; no automatic connection from merely opening the workspace. Refresh manually and on relevant vendor status events; do not add an unvalidated periodic keep-awake loop.

Output requests are restricted to identity 1, online 3, battery 4, configuration read 8 and version 18/29. Configuration reads are restricted to two-byte fields at 8496, 8498, 8500 and 9416, plus the four-byte active lighting-effect header at 8544 + mode×32 for a bounded mode 0...15. No generic flash accessor, driver-state command 2, keymap/macro reads, mutation, pairing/reset or bootloader requests.

Use exact VID/PID 05AC:024F, vendor usage FF02:0002 and the observed report-8 raw descriptor, then verify CID1/MID1/type0 before status reads. Open without seizure. Filter non-vendor report IDs and invalid lengths before copying; never decode/log/store normal keys, radio addresses or serials. Transport/protocol logs are semantic errors and field availability only.

## Public contract — module LofreeFlowLite84

- FlowLite84SessionProtocol: events: AsyncStream<FlowLite84Event>; connect() async throws; refresh() async throws; disconnect() async.
- FlowLite84Session: production actor implementing that protocol with injectable transport/timing; default live factory is invoked only by explicit connect.
- FlowLite84ConnectionStatus: disconnected, connecting, connected(FlowLite84Identity), disconnecting, failed(FlowLite84Failure).
- FlowLite84Event: status(FlowLite84ConnectionStatus, generation: UInt64), snapshot(FlowLite84Snapshot, generation: UInt64).
- FlowLite84Identity: cid, mid, connectionType (UInt8), with exact model validation.
- FlowLite84Snapshot: identity; online: Bool; keyboardVersion/receiverVersion: String?; battery: FlowLite84Battery?; lighting: FlowLite84Lighting?; systemMode: UInt8?; readAt: Date; unavailableFields: [String]. Public fixture initializers should default optional fields.
- FlowLite84Battery: reportedLevel: UInt8?, charging: Bool?, voltageMillivolts: UInt16?. Invalid/sentinel fields are unavailable, never fabricated percentages or curve-derived estimates.
- FlowLite84Lighting: mode: UInt8, enabled: Bool, idleOffUnits: UInt8, brightnessLevel/speedLevel: UInt8? (raw 0...4). Preserve unknown modes without assigning unsupported semantics.
- FlowLite84Failure: bounded typed errors with userMessage. No raw packet/identifier text.
- FlowLite84Transport: reports: AsyncThrowingStream<Data, Error>, open() async throws, write(Data) async throws, close() async. Output data is report ID 8 plus 16-byte payload; input normalization accepts the observed 16/17-byte forms.

One serialized exchange owns a request, deadline and generation. Validate report-inclusive checksum, command, status and read address/count. Unsolicited command-10 events use a separate route, coalesced behind active reads. Required identity/online failures stop the attempt; optional valid rejections produce unavailable fields. Transport failure or ambiguous timeouts must not be mislabeled as supported fresh data. Late/duplicate replies and cancellation are bounded and invalidate stale work.

## App model/view contract

FlowLite84Model(session: (any FlowLite84SessionProtocol)? = nil) is @MainActor ObservableObject and inert by default. Expose status, snapshot, errorMessage, isRefreshing, connectionRequested, isConnected, isKeyboardOnline, isBusy, connectionTitle and batteryText. Methods: connect(), refresh(), disconnect(), sleep(), wake(), setSuspended(Bool), stop() async. Expose onDiagnostic ((DiagnosticEvent) -> Void)? using parent-added flowLiteStatus/flowLiteFailure codes.

Preserve intent across system sleep and release the read-only handle; wake reopens only if previously requested. No hardware power writes. Explicit Disconnect clears intent. Session/UI epochs reject stale events and prevent duplicate connection/refresh tasks. Invalid unrelated TOML or input-posting permissions must not disable this read-only device's Connect button.

FlowLite84DeviceView observes the model directly. Use the existing native overview/card layout: battery/connection first, read-only OS/backlight status centrally, versions/details at the bottom. No setting pickers or mutation affordances. Parent owns AppModel, package targets, navigation/sidebar/menu and lifecycle integration; model/view worker does not edit those shared files.

## Bounded live verification

Add a developer-only SwiftPM executable flowlite84-status, requiring --read-only explicitly. It uses the same production session/allowlist, collects one snapshot, closes the handle and prints only safe decoded status fields (no raw reports/private identifiers). An overall timeout and cleanup bound the run. This diagnostic is not packaged in Hidhogg.app and is not a new local-automation API.

Run live only after independent fake/allowlist tests pass. No production app launch or configured actions. If the receiver is absent/offline, report that precise limit; do not broaden discovery or write settings to wake it.

## Checklist

- [x] Owner approves FL-01 and explicit bounded read scope.
- [x] Add pure read-only codec/types and exact receiver transport/session.
- [x] Add model/view, parent integration and fake/native test sources.
- [x] Independently verify allowlist, concurrency, stale state and no normal-input capture.
- [x] Run approved bounded read probe and record safe results/limits.
- [x] Build/sign fixed app/CLI, refresh provenance and owner checklist.

All other device behavior remains unchanged. FL-02/03 setting writes require separate approval and readback/restoration evidence. No commit/push is implied by this implementation approval.

## Verification checkpoint — 26 October 2026

### Intermittent invalid response — 27 October 2026

Owner confirms active2.4GHzreceiver and reports invalid status response before the first snapshot. The unchanged bounded probe first completed full online Connect→Refresh (battery40/notcharging3755mV,keyboardv1.61,light/system available). Three subsequent independent two-snapshot attempts produced one invalid response during the online query after send completion, then two full online successes. This supersedes the pending transport-mode question and confirms that online=false from the earlier run was not evidence of a normal macOS disconnection. It does not establish why that flag was false.

Safe logs: /Volumes/Data/tmp/hidhogg-flowlite-invalid-response-repro-20261027.json and hidhogg-flowlite-invalid-response-repeat-20261027.json. Existing generic invalidFrame does not distinguish checksum, correlation, duplicate/unrelated reply, online flag or configuration checksum failures. Backend validation diagnostics are being classified with safe enum reasons/known vendor command numbers only; packet contents/private identifiers remain excluded. Acceptance/correlation rules remain unchanged until a live classified failure identifies the cause. The receiver-firmware-query correction remains intact.

Typed diagnostics then reproduced the exact cause: replyCommand(expected:3,received:1), a late identification reply during an online-status query. Two other attempts completed full online snapshots. Safe evidence: /Volumes/Data/tmp/hidhogg-flowlite-invalid-classified-repeat-20261027.json. No malformed raw frame dump was needed.

Correction adds one positive filter after generation/transport/decode/checksum validation and command10 routing. A status0 command1 reply is ignored only when its CID/MID/type exactly matches the identity already confirmed in this generation and the pending request is not identification. It never satisfies a pending query, resets its deadline, publishes state or skips validation of other replies. Wrong/rejected identity, invalid checksum, unrelated command and duplicate during the identification request remain failures. Broad ignore-unmatched routing and automatic retries were deliberately not introduced.

The exact expected3/received1 fake case failed before the filter, then all39 module cases passed, including idle-repeat/no-refresh and wrong-identity/checksum/other-command failures. Logs: /Volumes/Data/tmp/hidhogg-flowlite-late-identity-red.log and hidhogg-flowlite-late-identity-green.log. Safe validation enums distinguish11 failure reasons; transport preserves the typed cause without private bytes.

The bounded probe now waits two seconds between Connect and manual Refresh, preserving any underlying session failure before cleanup. Three corrected live cycles exited0 without invalid responses or timeouts, but returned online=false and therefore omitted keyboard fields. Owner confirms2.4GHz and says the keyboard has always been awake/available, not disconnected. Safe evidence: /Volumes/Data/tmp/hidhogg-flowlite-late-identity-fixed-live-20261027.json. Do not infer normal keyboard disconnection or sleep from the vendor flag.

After the owner's active/awake confirmation, a fresh run completed an initial online snapshot, then Refresh completed online, keyboard-version and battery exchanges before the lighting-mode send completed without a successful reply. It timed out. Evidence: /Volumes/Data/tmp/hidhogg-flowlite-user-active-live-20261027.json. Thus the late-identity fix is verified separately, but read reliability remains incomplete. A [bounded same-logical-read retry proposal](flow-lite84-read-reliability-plan.md) has independent read-only review and awaits owner confirmation; it is not implemented. Do not describe the whole connection problem as solved or attribute it to sleep/disconnection.

Latest owner screenshot adds another concrete case: expected battery4, received firmware18 after a successful connection and failed refresh. That demonstrates the identity-only exception is too narrow; it does not alone prove the firmware payload was identical or successful. Independent review favours the reference reader's simpler correlation matcher over a response-history cache: discard ordinary schema/checksum-valid off-current replies without state/deadline changes, accept only the current command/read header, preserve the special identity-binding guard and all matched-response validation. No reply history is needed. Same-request retries remain separately optional. The [revised two-part plan](flow-lite84-read-reliability-plan.md) awaits owner confirmation; no general-routing or retry code is implemented. No sleep/disconnection assumption.

Current signed build9ff4e08cd36e42f74c6bd29a9926cc578ada080a8fdbf874ebdb7423fca63aee passes strict signature/CLI checks;209 current input hashes verified. Full offline349XCTest+260SwiftTesting plus6explicitfake native=615unique passing checks. Logs: /Volumes/Data/tmp/hidhogg-flowlite-invalidresponse-full-20261027.log, hidhogg-flowlite-invalidresponse-native-20261027.log and hidhogg-flowlite-late-identity-release-20261027.log. No production app launch, commit or push. These automated passes do not close the real unanswered-read issue.

### Refresh regression — 27 October 2026

Owner reports Connect succeeded once but Refresh timed out and closed the session. A bounded diagnostic-only --read-only --refresh-once mode reproduces timeout at receiver-version command29; semantic write-completion markers show identity, online and29 sends completed, with no successful29 exchange. Safe red evidence: /Volumes/Data/tmp/hidhogg-flowlite-refresh-repro.json and hidhogg-flowlite-refresh-milestone-repro.json. No raw frames/private identifiers are retained.

The initial snapshot made optional receiver firmware part of every normal Connect/Refresh batch. Correction: routine status now omits that unverified query, leaves receiverVersion unavailable, and retains keyboard firmware/battery/lighting/system reads plus existing fail-closed rules for their ambiguous failures. This is not a claim that29 is universally unsupported; the codec allowlist remains unchanged. Alternatives rejected: a longer timeout/retries would still make basic status depend on uncertain metadata; continuing the same ambiguous exchange would weaken correlation. No new commands or settings writes.

Two fake regressions cover silence from the outset and the exact reported sequence: successful Connect after valid29 rejection, then silence before explicit Refresh. The latter failed specifically in Refresh against the old query sequence and passed with the fix. Exact fixed Session bytes were restored after the negative test. Logs: /Volumes/Data/tmp/hidhogg-flowlite-refresh-fidelity-red.log and hidhogg-flowlite-refresh-fidelity-green.log. Independent full offline:349 passing XCTest +251 Swift Testing, with six intentional native skips; explicit fake native6/6 pass.606 unique passing cases. Focused filter additionally passes30 Swift Testing and12 XCTest cases (including one matching fake native case).

The exact bounded live Connect→Refresh probe now exits0 with two fresh receiver snapshots and no29 query. It reports online=false, so keyboard/battery/light reads were correctly skipped. Owner says the keyboard never disconnected; normal macOS typing connectivity is not inferred from this vendor flag. Active2.4GHz/Bluetooth/USB connection-mode confirmation is pending, and full online keyboard refresh is not yet hardware-verified. Safe result: /Volumes/Data/tmp/hidhogg-flowlite-refresh-fixed-live-20261027.json. No speculative change to online interpretation, keep-alive or driver state was made.

Signed app/CLI buildd00415f320d16652b78fe14b644d95a259620e07e8a5f22d037c5e8c5e42e487 passes strict signature checks and CLI help.209 current source/resource/test hashes and new logs are verified in local ignored dist/build-info.json. Release: /Volumes/Data/tmp/hidhogg-flowlite-refresh-release-final-20261027.log. No production app launch, commit or push; quit/reopen the updated app before owner validation.

### Initial FL-01 local evidence — 26 October 2026

Owner reapplied WezTerm Full Disk Access; exact Clang/Swift external overwrite repros and original-cache builds then passed. No build-script/cache-path/permission workaround was needed. The new native test height measurement now matches the existing harness minimum-size contract; width, non-key/passive and snapshot assertions remain. Independent fake native suite: 6/6 pass. Full offline: 355 XCTest cases including six intentional native skips (349 passing) plus 249 Swift Testing cases; zero failures. With the explicit native suite this is 604 unique passing cases. Focused Flow Lite/model/menu gate passed39/39. Logs: /Volumes/Data/tmp/hidhogg-flowlite-full-final-20261026.log, hidhogg-flowlite-native-final-20261026.log and hidhogg-flowlite-fda-focused.log.

Signed dist/Hidhogg.app and dist/hidhoggctl build783f76c1cd9488e724aeb0ea34f0964a5dd0659822485d957363a85ea566a4f5 passed strict signature checks and CLI help. Release log: /Volumes/Data/tmp/hidhogg-flowlite-fda-release-final.log. Local ignored dist/build-info.json records current artifacts/logs and209 verified source/resource/test inputs. Source remains uncommitted on next/lofree-flow-lite84; no push or production app launch.

The first bounded read probe failed closed with an invalid status response. A second one-snapshot run succeeded: exactCID1/MID1/type0, online; keyboardv1.61; reported battery40, notcharging,3755mV; lightingmode10/enabled/rawbrightness0/speed1/idle6; storedsystem1(Mac). Receiver firmware was unavailable. The diagnostic-only probe now records the last attempted semantic query stage on failure; it retains no raw frames and delegates the unchanged strict read allowlist. This instrumentation does not establish a cause or fix for the first failure. Safe results: /Volumes/Data/tmp/hidhogg-flowlite-fda-readonly-probe.json and hidhogg-flowlite-stage-readonly-probe.json. No settings writes occurred.

Owner checks below remain open, including charging transitions, accuracy/granularity, physical light/system mapping, lifecycle and app UI acceptance. Synthetic captures verify the upper status card; lower GroupBox bitmap regions were blank, so lower-field visual rendering is not established by background captures. Receiver firmware availability and intermittent invalid responses remain follow-up limits. FL-02/03 writes are not implemented or authorized by this slice.

### Earlier checkpoints (superseded by final evidence above)

Permission retry after owner reapplied WezTerm Full Disk Access: exact external Clang/Swift output overwrites pass; original-cache focused tests pass 39/39. No agent chmod/chown, cache deletion or build-script workaround. Native height measurement correction, full/native gates, release and bounded live probe are resuming. See the subsequent retry section in [diagnosis](flow-lite84-build-diagnosis.md); earlier blocked states below are historical.

Later diagnosis supersedes the all-tests-unrun state below: a workspace-local cache compiles and runs tests. The focused run passes 39 backend/model/menu cases, while the synthetic native case fails two 32-point height measurements. External compiler output overwrite EPERM remains reproducible; its underlying policy is not identified. See [diagnosis and exact evidence](flow-lite84-build-diagnosis.md). No production/test source change or signed release occurred during diagnosis.

Source implementation is frozen, but executable acceptance is blocked. Independent source review checked the exact non-seizing selector, strict request/address allowlist, callback filtering/scrubbing, callback-token cleanup, explicit probe argument boundary, passive navigation and menu aggregation. The four production backend files typecheck together; all new source/test files parse. Whole-app Swift 6/macOS 26 compilation to discarded SIL and the probe's equivalent check passed, using existing dependency modules; this is not a packaged build or test execution. Logs: /Volumes/Data/tmp/hidhogg-flowlite-app-sil.log and hidhogg-flowlite-probe-sil.log. Test sources include 25 backend cases, independent literal-boundary cases, eight model cases, aggregate-status assertions and a fake native workspace route/render case. None of those tests has executed yet.

SwiftPM was accepted for escalated execution, then macOS returned Operation not permitted while writing existing compiler outputs. A fresh scratch failed reading its newly created dependency repository config. An isolated dependency-free temporary package compiled the four production backend files, then failed emitting Combine into its ModuleCache. Disposable create/overwrite/delete checks succeeded in both permitted temp/cache roots; the specific build restriction remains unresolved. No cache deletion, permission changes, or automatic-approval rejection occurred.

Logs: /Volumes/Data/tmp/hidhogg-flowlite-focused.log, hidhogg-flowlite-focused-fresh.log, hidhogg-flowlite-focused-norefresh.log, hidhogg-flowlite-offline-20261026-tests.log and hidhogg-flowlite-release-20261026.log. The release build stopped before replacing dist/Hidhogg.app; the previous signed checkpoint and its provenance remain unchanged. The live receiver probe is deliberately unrun until the independent fake gate passes. No runtime screenshots, hardware acceptance, commit or push are claimed.

Resume with the source unchanged: resolve the build output/module-cache restriction; run focused FlowLite/model/status tests, full offline tests and explicit fake NativeWorkspaceWindowTests; only then run the approved --read-only probe with an external process timeout, sign the fixed-path app/CLI and refresh provenance. Physical battery accuracy, charging transitions and stored-mode/light semantics remain owner checks.

## Decisions and alternatives

| Decision | Alternative considered | Reason |
| --- | --- | --- |
| Separate receiver-specific module | Reuse Logitech/D200X transport assumptions | Distinct report shape, discovery and protocol correlation; existing devices keep their established boundaries. |
| Explicit Connect/Refresh and relevant vendor events | Periodic status polling | Avoid an unvalidated keep-awake effect and unnecessary traffic in the first status slice. |
| Device-reported battery level plus voltage | Vendor host-estimated percentage | The vendor voltage conversion has a documented boundary defect; raw reporting avoids fabricated precision. |
| Read-only OS/light snapshots | Immediate editing controls | Physical meaning and reversible writes remain separate FL-02/03 gates. |
| Close receiver handle during system sleep, retain intent | Send power commands or keep handle active | No verified Flow Lite power protocol is required for this read-only slice. |
| Developer-only bounded status executable | New automation API or old keymap probe | Same allowlist as the app, one safe snapshot, no private keymaps or broader service surface. |

Receiver identity is exact model validation, not authentication. The investigated protocol has no established echoed nonce or request sequence number. One outstanding request, command/address/count checks, and closing on ambiguous timeout/unexpected duplicate reduce stale-response risk; an arbitrarily delayed same-command reply cannot be authenticated across otherwise successful batches. The native SDK documents the output callback timeout in milliseconds; the transport uses 600 ms plus a bounded run-loop deadline and token-based callback lifetime cleanup.

## Owner validation after the signed build

| Check | Expected result |
| --- | --- |
| Open Flow Lite84 before connecting | No receiver traffic; Connect available independently of mouse permissions. |
| Connect with the original receiver present and keyboard awake | Receiver connects; keyboard online, reported battery/charging/voltage and versions populate where supported. |
| Compare battery/charging with a known charging change | Charging reflects the device; reported level granularity/accuracy is assessed rather than assumed. |
| Refresh after changing physical lighting shortcuts | Updated read-only snapshot; Hidhogg does not apply settings. |
| Compare reported system selector with physical Fn+N/Fn+M | Record the observed mapping before treating it as verified hardware mode. Restore the original mode manually. |
| Disconnect, unplug or sleep the keyboard | No stale battery shown as a live menu/sidebar value; old page snapshot is marked as last-read data. |
| Sleep/wake the Mac after explicit Connect | Read-only handle closes and intent resumes on wake; no setting/power commands. |
| Explicit Disconnect, then sleep/wake | Remains disconnected. |
| Use Logitech and D200X | Existing controls and status remain functional. |
