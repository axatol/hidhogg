# BOLT-RECOVERY-02 — connection change and completion crash

Checkpoint: 2 November 2026. Base master is `3e5e6ee`; approved implementation/tests are uncommitted. Signed candidate `e94f7423` replaces `bff106c7` in dist, with owner verification pending.

## Intended product flow

Change Connection on an existing mouse should select an existing endpoint or pair through a chosen Bolt receiver, verify the mouse, save the association against the same registration UUID, then return to that device and reconcile its saved settings. Removing the registration or unpairing first is not required. New Bluetooth pairing remains unimplemented; already-paired Bluetooth endpoints are supported by the selector.

Current implementation first requires previous-controller `stopForRestart` success plus a settled status without cleanup uncertainty. This blocks the entire setup flow when the previous mouse cannot be restored/verified, even though selected-receiver pairing is a distinct operation. A replacement receiver was verified by approved numeric-only USB/HID inventory: `046D:C548`, one eligible long-report endpoint. That does not by itself verify a pairing attempt.

## Approved crash evidence

Owner reported a crash after completing the click challenge, following device removal/unpairing. Explicit permission covered only exception/termination details, build identity and the crashed-thread stack from the most recent Hidhogg report. Paths/identifiers were omitted; no configuration, raw HID payloads or other-thread data were inspected.

- IPS report header time: **2 November 2026, 16:06:21 AEST**. The owner-provided `crash.log` records an event time of **16:05:54.1677 AEST** and the same main-thread exception/stack pattern; only approved fields were extracted.
- Exception: `EXC_BAD_ACCESS`, signal `SIGSEGV`; termination signal 11.
- Main thread stack includes SwiftUICore array destruction, AttributeGraph updates, `GraphHost.updatePreferences`, `ViewGraph.updateOutputs` and `NSHostingView.layout`.
- Private report binary identity was compared in memory with the current app bundle; only the match result was emitted. It matches signed build `bff106c775aa8d2e53cf62cc6b4735742d20832e7d64297bd845ef0d308a64eb`.
- Sanitized extracted evidence only: `/Volumes/Data/tmp/hidhogg-pairing-crash-redacted.json`, mode 0600. No raw report copy was created.
- Owner-provided `crash.log` remains local and is excluded through `.git/info/exclude`; it must never be staged or copied into documentation.

This stack establishes a crash during main-thread UI layout, not the application-level cause. It does not prove whether radio pairing, identity verification or association publication had completed. A refresh of existing devices after reopening may reveal an already-completed pairing; do not infer radio rollback from app termination.

## Approved scope — in progress

Owner approved offline crash reproduction/fix and the connection-flow correction on 2 November 2026. Live device/input operations remain owner-only. Read-only crash-report permission does not extend to configurations, HID payloads or other applications.

- [x] Identify replacement receiver eligibility and inspect approved crash fields.
- [x] Verify crashed binary against current signed app.
- [x] Exercise the post-challenge verification/save/navigation transition with fake sessions and bounded offline UI layout in Debug and Release; no crash reproduced.
- [ ] Fix only the confirmed crash cause and add a regression at the reproducing seam.
- [x] Separate locally drained/stopped work from unverified remote-device restoration; preserve unresolved ownership attribution and warnings.
- [x] Permit pairing on the explicitly selected receiver after local shutdown; require fresh identity/routing/settings verification before input delivery on the resulting connection.
- [x] Run independent offline gates and sign without launching or live input.
- [ ] Obtain owner verification of receiver switching and challenge completion before committing. The exact crash remains open until further evidence or manual acceptance.

An existing passing cleanup-failure test establishes that the original block is intentional, not that the replacement-receiver user journey or post-challenge layout is correct.

## Implementation and evidence

Two pre-change offline UI exercises did not reproduce the crash: six new/reassociation challenge→save/navigation flows (32.158 seconds), followed by two flows with dynamic SmartShift/haptic/full UInt16 pressure, controls, battery and firmware snapshots (12.961 seconds). They host the real WorkspaceView in hidden, non-key windows and emit no real input/device writes. The initial harness attempt outputs were overwritten by its author; their recorded failure reasons are reconstructed in the attempt ledger, not preserved original logs. Passing baseline and later capability iteration logs are separately preserved under `/Volumes/Data/tmp/hidhogg-pairing-completion-*`.

The application-level crash cause remains unknown. No speculative layout change is claimed as a crash fix. Bounded static completion-stage diagnostic codes now distinguish verification, pairing-session close, association save/publication and navigation; they contain no device identifiers or payloads.

The independent connection-flow correction adds a typed local-stop result, explicit transport close acknowledgement and retained remote-cleanup attribution. Setup/inventory/pairing use local-stop authority rather than requiring remote restoration or a separate status-event wait. Native close seals submissions, drains accepted application work, unregisters callbacks, closes the handle and awaits worker exit. It cannot retract an output frame already accepted remotely. Success/not-open are locally closed; absent/offline results require observed removal. Unexpected close failures still block pairing.

Repeated stops preserve the original restoration policy/recovery payloads. Candidate save and remapping require the same freshly verified physical identity/full Bolt association; reassociation retains its UUID and remove/re-add may remap recovery to a new saved UUID. Another/unknown identity may be radio-paired but is not published or activated while previous cleanup is unresolved. Different-mouse management, cross-transport uncertain recovery and recovery across process restarts are outside this narrow correction.

Review found a delayed-status race: retaining only the first cleanup generation let a later stale Ready clear newer uncertainty and permit a different association. The new actual-AppModel regression was run against the old floor behavior and failed six assertions, including wrong association publication and lost warning, in 3.823 seconds. The correction advances the floor with `max(old, new)` while retaining original attribution. Red log: `/Volumes/Data/tmp/hidhogg-receiver-change-stale-floor-red.log`.

Combined focused iteration 1 stopped at test-fixture compilation errors; no tests ran. Iteration 2 used an intermediate 348-input manifest, SHA-256 `2bfe9e36771b6a3617c77e2aff44aa9ab8fa4bc60bf6a2e264f2a4a28138e39a`. Its failures and final corrected results are recorded below; no intermediate gate is presented as the final source state.

## Final offline candidate

The paragraph above records an intermediate gate. Focused iteration 2 then found a first-stop restoration-policy timing regression plus two fixture assumptions; those were corrected, with the first stop policy installed before waiting and later stops prevented from replacing it. Focused iteration 3 passes 56 XCTest + 296 Swift Testing cases. Independent source review is clear. The concurrent-stop test uses a 20 ms delay rather than an explicit second-entry handshake; source inspection also verifies the policy fence.

The initial Release runs on both old/current production source did not crash, but failed the fixture's operation-count assertions: expected automatic wheel/thumb preference reconciliation was still queued when counts were sampled. Only the fixture was corrected to await hardware/wheel/thumb reconciliation and cleared apply flags before measuring layout. No count assertion was removed, and no production change was made for that timing issue.

Final results:

- Full Debug gate: **669 XCTest + 478 Swift Testing = 1,147**, zero failures. Same existing exclusions: `WakeConnectionTests` (17) and `NativeWorkspaceWindowTests` (6). Log: `/Volumes/Data/tmp/hidhogg-receiver-change-full-iteration2.log`.
- Current-source Release UI: **2/2**, 42.862 seconds. Log: `/Volumes/Data/tmp/hidhogg-receiver-change-release-ui-settled.log`.
- Original-source Release UI: **2/2**, 43.428 seconds, against archived HEAD with 329 tracked Swift blobs verified and only the new test added. Log: `/Volumes/Data/tmp/hidhogg-pairing-release-baseline/native-test-settled.log`. Initial XCBuild cache failures and initial assertion-failure logs remain preserved. The test-start watchdog marker missed buffered output, but the completed log confirms both tests executed.
- Final 348-input manifest SHA-256: `7e6aa3588f3eec5b85e9b670630b58b86e9bf1bb3165c1f21794ea015de1bb01`. All hashes match before/after final gates. Fixture SHA-256: `1ba57ba9080e856c81abde5bba8a6c96d431e9c15d6a741ab85dc0a5da1cce44`.
- Signed app/CLI build: `e94f7423e2f7a8cfe4d910835967547c2311c29ca239c6f76cdeda1d57457dc5`. Strict app/CLI signatures and CLI help pass. Only a test fixture changed after signing; production build inputs are unchanged, and final signature checks pass. Release log: `/Volumes/Data/tmp/hidhogg-receiver-change-release.log`.

No agent production launch, live HID/input/pairing write, private configuration read or push occurred. Source remains uncommitted pending owner acceptance. The connection-flow correction is offline verified; the post-challenge crash is **unreproduced, not proven fixed**. Completion diagnostics and native teardown hardening are present for the next manual attempt.

Owner next quits/reopens the rebuilt dist app. Keep the new receiver connected, use the existing mouse's Change Connection action, and select that receiver if more than one is listed. Refresh Devices first if radio pairing already completed during a prior attempt. Do not delete the Hidhogg registration merely to change receivers. Check retained settings/UUID and challenge completion. If it crashes, inspect only the already-approved report fields and generic completion stages; do not expand into private configs or HID payloads.

## Owner follow-up — 2 November 2026

Receiver switching is owner-confirmed and accepted for check-in. The crash remains open: the owner reports a repeat after navigation to the device page. Approved bounded extraction records an event at 17:40:43.2281 AEST, EXC_BAD_ACCESS/SIGBUS on the main thread in CoreText truncation and SwiftUI text measurement. Binary identity matches e94f7423. No root cause is established and no speculative layout fix has been applied. The tested checkpoint includes diagnostic support and offline repro attempts; committing it does not assert a crash fix.
