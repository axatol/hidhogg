# Compact Logitech setup — 1 November 2026

## Pairing follow-up — 1 November 2026

Owner confirms the existing-mouse list populates on entry and Refresh, then disappears after attempting new MX Master 4 pairing. The receiver-capacity error happens before discovery/authentication. Approved scope: preserve inventory through pairing/failure, verify the capacity decoder against research, and add focused synthetic regressions. No live pairing or bond mutation is authorized. Owner separately approved a bounded anonymous read-only receiver diagnostic.

- [x] Reproduce list loss, then preserve inventory while blocking stale selection during receiver ownership.
- [x] Diagnose the six-record capacity result without assuming an unresponsive slot is empty.
- [x] Finish uncertain-outcome selection guard, repeat checks/build/sign, and record remaining hardware uncertainty.

The new synthetic list regression failed on all three visibility assertions before removing the explicit candidate clear from `pairLogitechSetup`, then passed. Refresh/Add remain blocked until receiver cleanup finishes. A capacity-message regression also failed before the wording correction; it includes five offline records in a six-record inventory and retains refusal to discover/pair.

The approved read-only diagnostic found one eligible attached receiver: all six supported selectors returned nonzero record fields, none returned UNKNOWN_DEVICE, none had zero/erased product or identity fields, and five carried the not-reachable flag. This supports the full stored-pairing result; it is not an MX Master 4 discovery/authentication rejection. No raw record, address, name, serial or unit ID was printed or retained. Only register reads were requested; no discovery, pairing, unpairing or configuration writes were performed. The diagnostic does not establish that the five offline peripherals are still owned or recoverable.

The capacity algorithm remains unchanged. The error now explains that all six slots contain stored pairings, including offline devices, and suggests another receiver. [fwupd's receiver implementation](https://github.com/fwupd/fwupd/blob/main/plugins/logitech-hidpp/fu-logitech-hidpp-runtime-bolt.c#L195-L249) distinguishes the reachability flag from a returned pairing record. Receiver identity labels, explicit unpairing and new Bluetooth pairing remain separate scope.

Independent review of the retained rows found an additional boundary: after a may-have-paired or verified-but-unsaved outcome, selection must remain blocked until inventory is refreshed. Rows remain visible; Refresh remains available after cleanup. The hardening is complete: both cached selection and another Pair attempt require Refresh after an uncertain outcome. The 956-case artifact below is the earlier checkpoint.

Owner approved the mock-up direction and refined it to fewer steps: Bluetooth and Bolt options should be visible immediately after choosing Logitech. This supersedes separate Existing/New and transport-choice wizard pages.

```text
Add Device → Logitech
  Existing mice: Bolt + Bluetooth             Add / Open Existing
  New connection: Bolt                       Find mouse → Pair inline
                  Bluetooth                  New pairing unavailable

Explicit Add/Pair → verify + save → open device
```

- [x] Compare native flow with the original mock-up and confirm the refined scope.
- [x] Review app-level architecture and destination/persistence boundaries.
- [x] Implement a centre-pane route and immediate combined options/results.
- [x] Stage new registrations until verified save; retain reassociation settings and duplicate handling.
- [x] Reuse inline Bolt pairing with serialized receiver ownership and lifecycle fences.
- [x] Verify synthetic state/persistence/navigation checks and sign the app.
- [ ] Owner verifies native flow and hardware behaviour.

## Behaviour

The Add Device menu offers one Logitech category rather than model-specific creation. Existing supported mice from both transports appear asynchronously on the same page, with Add or Open Existing actions. Pairing is inline: choose a receiver only when needed, choose the discovered mouse, authenticate, then verify and save automatically. No placeholder registration, model picker, separate Existing/New screen, or required Done/Open completion step. A successful explicit addition opens the saved device. Cancelling after an admitted atomic publication can leave a saved-but-not-connected device; no automatic deletion or unpairing.

New direct Bluetooth pairing remains outside the current implementation and is visibly unavailable; existing Bluetooth mice work. D200X, Flow Lite and generic paired Bluetooth battery-monitor additions remain accessible. An existing registration's Change Connection action opens the same page with an explicit reassociation destination and preserves its UUID, name and settings.

## State boundaries

One `WorkspaceRoute.logitechSetup`, with an explicit `newRegistration` or `reassociate(UUID)` destination owned by AppModel. The setup route must not inherit `selectedMouseID` from the sole-mouse fallback. Discovery-derived, freshly verified identity/model authorizes a new registration; names and UI tokens do not. Duplicates include disabled registrations and offer Open Existing rather than creating another entry.

Reuse current management cleanup, BoltPairingStatus and receiver session. Do not introduce a second radio coordinator or alter protocol/schema. Inventory, pairing and recovery cannot compete for the same receiver. Cancel Pairing releases the receiver before returning to the same overview; Cancel Setup exits to the prior location. Navigation, sleep, reload, device changes and shutdown revoke stale save/activation authority. Preserve unrelated canonical/child-model edits during a staged commit and serialize through the existing persistence lane.

## Ownership and verification

`logitech_compact_model` owns AppModel, setup state types and integration tests. `logitech_compact_view` owns the new view, workspace/device entry points and navigation view switches. Parent owns documentation, integration decisions, build scheduling and signed delivery. Independent synthetic verification follows source freeze; no native app launch, live inventory/HID, private configuration/log or identifier reads are authorized. Prior Bolt hardware assumptions in `logitech-bolt-pairing-plan.md` remain unchanged.

The owner confirmed the old chooser now lists the mouse; this is list-visibility acceptance only. Current delivered baseline before this revision: signed LC-04, 940 offline checks, with the existing two suite exclusions and hardware acceptance still pending.

## Delivered evidence — 1 November 2026

Focused verification passes 80 XCTest cases. The full offline gate passes 955 cases (595 XCTest and 360 Swift Testing), excluding existing `WakeConnectionTests` and `NativeWorkspaceWindowTests`. The metadata test now waits for one snapshot containing available firmware and completed refresh, correcting an intermediate-state race without changing production backend behaviour.

Signed app/CLI build: `ed409cfc4d2699838be694e84a6bd6ca44f06a537b5e3d9496f8442beba11f7d`. Strict signatures and CLI help pass. All 304 source/test/build inputs match before and after signing. Logs: `/Volumes/Data/tmp/hidhogg-compact-focused.log`, `/Volumes/Data/tmp/hidhogg-compact-full.log`, `/Volumes/Data/tmp/hidhogg-compact-release-20261101.log`; metadata: ignored `dist/build-info.json`.

Source remains uncommitted. Native UI, physical association/pairing and reconnect remain owner checks. Existing Bolt allocation and bond-preservation evidence limits remain unchanged.

### Follow-up verification

The pairing follow-up passes 28 focused cases (16 setup XCTest +12 pairing Swift Testing) and the full 956-case offline gate (596 XCTest +360 Swift Testing), with the same two existing suite exclusions. Signed app/CLI build `cf3cf0b64c983c067ade3b0b7a05d93b8703df71b6b13fe2a89053253a6c41f9` passes strict signatures and CLI help; all 304 captured inputs match. Logs: `/Volumes/Data/tmp/hidhogg-pairing-fix-{focused,full,release}.log`; manifest: `/Volumes/Data/tmp/hidhogg-pairing-fix-inputs.json`. Native UI acceptance and real MX Master 4 pairing remain pending. Source remains uncommitted.

### Final source-frozen verification

Final gate: 958 cases (598 XCTest +360 Swift Testing), zero failures; same two existing suite exclusions. Focused30 cases pass (18 setup XCTest +12 pairing Swift Testing). Regressions cover list/message retention, definite-failure Add after cleanup, uncertain/verified-unsaved Add and retry refusal, and recovery after Refresh. Final logs: `/Volumes/Data/tmp/hidhogg-pairing-fix-iteration2-{focused,full}.log`.

Final signed app/CLI build: `4e63b49aa4a94c8c8dd87cf72c5c0ab59d765c2093923e45206e1ce6f03d6ee1`. Strict signatures/help pass and all304 inputs match `/Volumes/Data/tmp/hidhogg-pairing-fix-final-inputs.json`; release log `/Volumes/Data/tmp/hidhogg-pairing-fix-final-release.log`. This supersedes the earlier956-case artifact. No native app launch or pairing writes; only the separately approved read-only slot diagnostic was performed. Owner UI and real MX Master4 pairing acceptance remain open. Source is uncommitted.

Final audit decision: Refresh invalidates old candidates even if the subsequent existing-mouse scan fails, so no cached Add remains available. A new Pair attempt may then be offered because it independently reads receiver inventory before discovery/pair admission. Successful management discovery is not a prerequisite for that separate receiver check. No additional code change was required for this reviewed edge.
