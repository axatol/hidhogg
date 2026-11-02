# Logitech connectivity and pairing — 1 November 2026

## Requested outcome

Manage MX Master 3S and MX Master 4 through Logi Bolt or direct Bluetooth, including previously paired mice and creating new pairings from Hidhogg. Existing device settings must survive integration. This is a proposed implementation plan; no pairing operation has been performed.

Current checkpoint, 1 November 2026: LC-02 existing association and basic read-only MX4 support are implemented. LC-04 Bolt pairing and the SDK-native receiver eligibility correction are now offline verified and signed, before LC-03 Bluetooth pairing. See [Bolt pairing and chooser diagnosis](logitech-bolt-pairing-plan.md) for assumptions, exclusions and manual acceptance. No live pairing was performed by the agents. Earlier starting-point/spike notes below are historical, not current source claims.

## Verified starting points before LC-02

- Current `app/Sources/LogitechBolt/IOKitBoltTransport.swift` matches USB receiver `046D:C548`; direct Bluetooth is not integrated into this checkout.
- Earlier work remains in `/Volumes/Data/tmp/hidhogg-bluetooth-device-management`, branch `feature/mx-master-bluetooth-device-management`. Its current tree has uncommitted transport, identity, configuration and lifecycle changes. Integrate selectively against the current registry; do not merge either dirty tree wholesale. Its plan records offline evidence and outstanding hardware checks.
- [Logitech's MX Master 4 setup guide](https://hub.sync.logitech.com/mx-master-4/post/getting-started---mx-master-4-LSEt5tZXsbeMP3c) documents Bolt and direct Bluetooth, with OS Settings for Bluetooth pairing and receiver setup through Options+.
- Earlier static research in `/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/protocol-workflows.md` establishes receiver discovery/pair/cancel command construction and pairing-event parsing boundaries. It does not establish actual successful pairing, complete fragmented advertisements, or every authentication transition. The companion `pairing-buttons-scrolling.md` distinguishes frontend schemas from verified native dispatch.
- Current [Solaar receiver implementation](https://raw.githubusercontent.com/pwr-Solaar/Solaar/master/lib/logitech_receiver/receiver.py) independently corroborates Bolt discovery/cancel and pair/cancel/unpair register operations. This is protocol evidence, not Hidhogg/macOS hardware verification.
- Public Apple SDK declarations provide a plausible explicit Bluetooth LE pairing route: `IOBluetoothUserLib.h` defines LE inquiry, `IOBluetoothDeviceInquiry.searchType` selects discovery types, and `IOBluetoothDevicePair` accepts an `IOBluetoothDevice` and starts pairing with delegate progress. The installed MacOSX27.2 SDK header describes in-app pairing without IOBluetoothUI panels and declares CoreBluetooth delegate conformance. See [Apple inquiry API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdeviceinquiry) and [pairing API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevicepair). Combining these into LE inquiry → selected device → pair.start is an inference to validate on hardware, not proof of Logitech HID enrollment. No claim that public APIs cannot pair BLE is justified by the earlier research.

## Proposed vertical slices

1. **LOGI-CONNECT:** reconcile earlier transport/identity work with the current device registry; select already-paired Bolt/Bluetooth endpoints; verify model and fresh capabilities; preserve independent device settings and reject ambiguous or duplicate ownership. Cover both MX Master 3S and 4, including relevant receiver variants once evidenced. Read battery/firmware first; enable existing settings only behind confirmed capabilities.
2. **LOGI-BOLT-PAIR:** receiver selection, bounded discovery, explicit mouse selection, authentication instructions/progress, cancel/timeout/error handling, and successful paired-device registration. Keep the pairing session separate from active settings/input management. Do not automatically unpair or replace an occupied receiver slot. Completion requires enumeration and read-only identity verification, not a command acknowledgement alone.
3. **LOGI-BT-PAIR:** spike public LE inquiry plus IOBluetoothDevicePair before promising an end-to-end Bluetooth UI. Confirm compilation against the deployment target, owner-operated discovery/pairing and OS HID enrollment; then integrate selection, OS confirmation, cancellation and verified registration. A GATT connection does not establish an OS HID bond. If this supported-API route does not work, present the evidence and agree on a Settings-assisted alternative before treating that alternative as complete. Perform the bounded spike early, ahead of full pairing UI implementation.
4. **LOGI-VERIFY:** fake transcript/state-machine tests and signed build, followed by owner-operated new/existing pairing, cancellation, reconnect, settings and input restoration on both transports/models. Offline checks cannot certify radio authentication or physical mouse behavior.

## Boundaries and open evidence

No firmware updates, automatic unpairing, Flow, Actions Ring or movement gestures. New hardware controls/haptics need explicit capability/protocol evidence rather than MX Master 3S assumptions. Exact MX Master 4 endpoint identifiers, supported feature versions, receiver variants and cross-transport identity behavior require verification.

No live Bluetooth inventory, identifiers, raw pairing material, device commands or OS prompts were inspected during planning. Pairing occurs only through an explicit user-driven flow; preserve the current operational mouse connection until the new endpoint is verified.

## Checklist

- [x] Inspect earlier research and confirm both existing/new pairing are requested.
- [x] Inspect current and earlier worktree boundaries without changing either implementation.
- [x] Identify a public macOS LE inquiry/pairing API candidate; hardware compatibility remains unverified.
- [x] Owner approved the proposed sequence, beginning with the Bluetooth pairing spike. Any fallback still requires agreement.
- [ ] Implement and verify each approved slice; record owner hardware results separately.

## Bluetooth spike: compile-only checkpoint

On 1 November 2026, a Swift typecheck against `arm64-apple-macos26.0` passed for LE inquiry selection, `IOBluetoothDevicePair(device:)`, pairing start and cancellation. Probe: `/Volumes/Data/tmp/hidhogg-bluetooth-pairing-api-probe.swift`; log: `/Volumes/Data/tmp/hidhogg-bluetooth-pairing-api-probe.log`. The probe defines a function and was typechecked only, never executed. It performs no discovery, pairing or device access. Initial Swift import-shape errors were corrected (`searchType` uses the enum raw value and pair.stop returns Void).

This verifies API compilation for the existing deployment target, not permission behavior, discovered results, BLE pairing success or HID enrollment. Further Options+ analysis should target unresolved Bolt fragmentation/authentication fields and MX Master 4 capability differences rather than repeat established discovery/connection research.

## Gap-report review — 1 November 2026

Additional reference supplied by the owner: `/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-bolt-functionality-coverage-2026-11-01.md`. Its stable receiver/transport/device/maintenance coverage IDs are useful for later pairing implementation and deferred-work tracking. A research inventory does not authorize firmware, reset/unpair or other deferred hardware operations. Existing-connection regression diagnosis takes priority before LC-02.

Historical review of `/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-connectivity-gap-report-2026-11-01.md` matched its then-recorded transport/controller/configuration snapshot and identified a singleton mouse-settings projection. LC-01 has since replaced that projection with per-registration UUID-scoped settings and runtime ownership; do not reintroduce global settings. The strict1B04 V5 guard still applies to existing button management; LC-05A independently admits the shared2121V1 wheel contract without loosening that button guard.

The report provides a more precise implementation sequence: LC-01 UUID-scoped settings/runtime ownership; LC-02 explicitly selected existing endpoints and read-only identity/capabilities; LC-03 Bluetooth pairing directly inside Hidhogg; LC-04 serialized receiver pairing; LC-05 capability-gated management; LC-06 multi-device/recovery acceptance. This refines the approved scope rather than authorizing new hardware features. No separate executable spike is planned under the owner's later instruction.

MX4 control-feature V6 requires an evidenced decoder/operation path, not a relaxed V5 guard. Other reported identity/battery/name version differences also need bounded compatibility handling. Ordinary Bolt advertisement/challenge evidence is sufficient to begin bounded implementation, while recovery records, unknown authentication combinations and receiver variant/allocation behavior retain separate gates. Basic connectivity must not depend on implementing haptics, force sensing or gestures.

Mock-up implications: preserve separate pairing/HID/management readiness; show paired-but-not-added if saving fails or cancellation races success; reject ambiguous endpoint association; no automatic bond rollback. The current mock-up remains simulated and provisionally accepted. Further research is targeted at a specific blocked decoder/operation, while permissions, HID enrollment and physical recovery are verified manually in the signed app.
