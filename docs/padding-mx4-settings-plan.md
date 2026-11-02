# Padding consistency and first MX Master 4 settings slice

Approved 2 November 2026, based on clean master checkpoint9eb6e8e. Owner requests padding first, then MX4 settings, and confirms the long-term goal is all MX Master3S/4 hardware capabilities. Owner explicitly approves a small first slice and asks for a model-agnostic protocol or clearly separated versions. Padding implementation starts first; source architecture is being mapped before settings edits. No live device operation or production launch is authorized.

## Checklist

- [x] Audit current layout and model-wide MX4 read-only gates.
- [x] Compare relevant wheel/control contracts with existing controller.
- [x] Owner approves these concrete slices and feature/model-version separation.
- [x] UI-PAD-01: implement consistent custom-card insets; review narrow/wide offscreen renders.
- [x] LC-05A: capability-gated MX4 main-wheel direction and input resolution.
- [x] Independent source-derived regression checks, appropriate broader checks, strict signed delivery and hash reconciliation.
- [x] Owner reports current padding and initial MX4 settings work well; specific restoration/reconnect and Bluetooth cases remain unreported.

## UI-PAD-01 — custom card spacing

Use one shared16-point internal inset convention for custom card/GroupBox contents, consistent label/content separation, and existing page margins. Apply to Logitech setup/pairing/device information, D200X device/inspector/preset/script/action groups, and generic Bluetooth cards. Keep correctly padded Flow Lite sections consistent; replace inconsistent explicit content padding rather than stacking it. Preserve native grouped Form spacing, compact menu/sidebar rows, and deck artwork/preview geometry. Retain existing native colors, materials and controls.

Findings: Logitech Bolt/Bluetooth/Devices GroupBoxes have no explicit content inset; D200X firmware/settings and inspector/editor GroupBoxes mix absent or vertical-only insets; DeviceInformationView and GenericBluetoothDeviceView use8; Flow Lite section helper and disclosure use16. Existing mouse/deck headers use18 and page containers mostly24. The target is internal card consistency, not a broad page redesign.

Verification boundary: build and inspect representative offscreen fake-data layouts at narrow/wide widths; no production app activation or live models/devices, no new tests that merely assert padding constants. Reuse relevant existing layout checks. Owner performs final visual acceptance.

## LC-05A — first actual MX4 settings

Deliver main-wheel direction (Standard/Natural/Leave unchanged) and input resolution (Low/High/Leave unchanged) using the bounded2121 V1 contract, only when fresh identity, feature/version, capability and baseline reads validate it. Preserve unedited mode bits, check post-write readback, retain per-registration saved settings, and restore only owned fields according to the existing restore preference. Unsupported/malformed/foreign state stays explicit and cannot authorize a write.

This requires feature-specific admission. Current controller line868 enables management only for3S; MX4 is explicitly read-only. Button connect preflight requires1B04 V5 and <=12 rows, while MX4 specimen evidence is V6. AppModel line707 and active device/inspector views also hide all MX4 controls. Do not remove those gates wholesale or make wheel availability depend on successfully enabling an unsupported button table.

MX4 UI should offer the supported Scroll wheel settings without enabling unimplemented buttons, thumbwheel or host scroll capture. Existing saved button/custom-amount/other-feature preferences must not cause such writes when connecting this first slice. Keep native pointer, primary click and scrolling usable throughout. Existing3S behavior stays covered by its regression suite.

Custom scroll amount requires a separate diversion/permissioned synthesis lifecycle; thumbwheel2150 has capability/resolution/sensor nuances; V6 button mapping needs independently validated tables/reporting ownership; SmartShift2111 and DPI2201 need their own adapters. These are subsequent slices. Haptic/panel controls are not added by this plan. No gestures/Flow/Actions Ring or new pairing work.

Validation: independent literal source-derived feature replies (not constants/builders imported from the implementation), dynamic indices, supported/absent/unknown versions, short/malformed responses, field-preserving mutation/readback, no writes to unsupported features or foreign ownership, lifecycle restore/reconnect and registration isolation. Fake transports only for agent checks. Owner verifies MX4 Bolt first; direct Bluetooth is a separate acceptance path. No real device writes or sensitive runtime inspection by agents.

## Source basis and remaining uncertainty

Primary local research: `~/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-mx-master-feature-contracts-2026-11-01.md` (wheel/control contracts and source-specific V5/V6 mapping) and `hidhogg-pairing-mouse-protocol-spec-2026-11-01.md` (capability/ownership/actual-length and acceptance rules). Existing controller2121 support is version1;2150 is version0. A known specimen does not establish every firmware/transport.

Pinned OpenLogi URLs could not be retrieved in the current browser attempt; the supplied research remains the inspected local evidence. Pinned Solaar hidpp20.py was accessible and corroborates per-control flags/routing field distinctions. Do not claim fresh OpenLogi revalidation. Resolve any command-field contradiction against retained technical sources before implementing that operation. No private/manual-results/captures were inspected.

The old connectivity-plan singleton-projection description is stale; current registry has per-device UUID settings. Retain the current registry and do not reintroduce global settings. Research gives source contracts, not physical verification; first owner write/readback and restoration remain acceptance gates.

## Approved protocol direction and full hardware roadmap

Shared HID++ report framing, request correlation, receiver/slot routing, identity, ownership/serialization and lifecycle remain common. Put real wire differences behind small feature-ID/version adapters (for example2121V1,1B04V5/V6,2110V0/2111V0), not copied monolithic3S/4 controllers. Use model profiles only for evidenced model-specific policy or control interpretation; live per-endpoint feature versions/capabilities remain authoritative. Shared versions reuse a common implementation. Unsupported/unknown capability stays distinct from model unsupported.

For the first slice, define a small pure codec/change-planning seam before touching I/O policy. It must preserve the established3S behavior while giving MX4 independently gated2121V1 direction/resolution access. Saved but unimplemented button/capture/thumb preferences must not leak through the old global supportsManagement flag. Avoid inventing adapters for future features before their differing contracts are implemented.

| Hardware family | Coverage goal / later contract | Current slice |
| --- | --- | --- |
| Identity, firmware, battery, connection | Per-model/transport fresh identity and readable status; retain unknowns | Existing, regression coverage retained |
| Main wheel reporting | Direction and input resolution2121; per-capability owned field writes/readback | First MX4 settings slice |
| Main wheel capture/amount | Permissioned host synthesis and safe diversion/cleanup | Later independent slice |
| Thumbwheel |2150 direction/reporting, resolutions and advertised sensors; amount/tap only when contract complete | Later independent adapter |
| Programmable hardware controls |1B04V5/V6 enumerate actual CIDs/tasks/flags; Back/Forward, middle, mode/thumb controls where evidenced | Later versioned adapters |
| Wheel mechanics |2110/2111 SmartShift, fixed/automatic modes, threshold and torque only when advertised | Later adapters, preserve physical mode-button behavior |
| Sensor |2201 supported sensors/ranges/DPI and any evidenced device presets | Later bounded adapter |
| MX4 force/haptic hardware |19B0/19C0 configuration, capability/range and correct panel association | Later source/physical gates |
| Host channels | Evidenced Easy-Switch/host capabilities without guessed slot/channel joins | Later scoped adapter |
| Other advertised hardware features | Every observed capability gets implemented/deferred/unknown/blocked disposition | Inventory-driven roadmap, no generic unknown writes |

Earlier exclusions for Flow, Actions Ring and directional gesture software remain. Firmware update/reset/recovery remains a separate deferred maintenance scope, not implicitly activated by all hardware-feature support. This is a complete coverage goal, not a claim every source/firmware/version contract is closed. Owner checks3S/4 and Bolt/direct-Bluetooth paths separately.

## UI-PAD-01 checkpoint — 2 November 2026

Padding source frozen: shared CardContentPadding.swift and18 view updates cover41 scoped explicit GroupBoxes, replacing boundary insets rather than stacking. Independent source review has no findings. Offscreen gate passes2 tests (new CardPaddingOfflineLayoutTests plus existing preset render test), with12 fake-data PNGs under /Volumes/Data/tmp/hidhogg-padding-offscreen. Parent viewed all12: setup600/1000, information380/720, FlowLite360/840, inspector320/480, preset editor580/760 and chooser780/1000. Content has visible inset, narrow setup stacks, chooser fitting and fixed image frames retained. Tests assert never-visible/non-key windows, no adapter/input/config writes/edits. Log hidhogg-padding-layout.log. Harness initially had a missing cleanup method and missing environmentObject; fixes were test-only, runtime-abort log preserved, first compile log inadvertently overwritten (exact error retained in task event). No production defect or source change required from those harness failures.

## LC-05A implementation contract

Use a pure HIDPP2121V1 codec/planner to validate capability/mode replies and merge direction/resolution changes with the fresh mode and owned-field masks. This shared feature-version implementation serves both models; transport/identity/operation/readback/restore remain in BoltController. Do not add an interface protocol with only one speculative implementation.

Add only BoltWheelStatus.supportsInversion (defaultfalse for source compatibility) as the extra capability indication; keep wheel.support as validatedV1 readiness. Existing supportsManagement remainsfalse forMX4 and continues guarding buttons/capture/thumbwheel. Add independently admitted wheel-preference operations, including their owned cleanup, without enabling a general writer or unrelated saved config. Central mutateRequest currently also gates supportsManagement: its narrow wheel-preference authorization must identify the real feature/version/set operation and reject capture/routing writes, while preserving identity/lifecycle preflight. Do not solve by removing that guard wholesale.

Capability08 means inversion, not whole-wheel support. Resolution is a separately definedV1 mode bit; a resolution-only device must not authorize inversion writes. Preserve existing3S behavior when its inversion capability is present; prove capability absence through independent literals and no-write assertions. Freshly observed mode, default natural-scrolling mapping and per-registration restore remain authoritative.

Backend source implementation starts only after this padding checkpoint, with narrow targetedRED/GREEN and existing regression suites. Frontend AppModel/UI integration follows the stable backend contract to avoid parallel fixture/API compile races. Whole-slice independent focused/full gates and signing follow integration.

## LC-05A backend checkpoint

Independent literal MX4 dynamic-index cases23/42 were RED before runtime changes:12issues on supported status/expected mode6 and owned restore0, proving the old model-wide closed gate. Shared pure HIDPP2121V1 codec/planner and additive supportsInversion status are implemented; targeted75 and entireLogitechBolt256 pass in author checks. Existing3S08-based connect-reclaim policy was restored after a regression run exposed that broadening it read an unrelated synthetic feature. The failure was diagnosed rather than bypassed in the fixture. Public physical3arg operation is separate from capture5arg operation; MX4 capture overload remains refused even amountnil/postingtrue.

Read-only backend review has no findings; narrow permission validates feature/function/one-byte native-mode change and re-reads root/caps/mode after identity, including owned restore, with reserved token overhead. Reviewer notes a test named cancellation actually changes mode; author is renaming it and preserving short-capability associationLost/activecapture refusal semantics before final backend freeze. Frontend remains unedited/on hold until that brief compatibility check completes, preventing concurrent API/test compilation races. These checks are offline only; hardware writes/readback/restoration remain owner gates.

## Combined signed delivery — 2 November 2026

UI-PAD-01 and first LC-05A implementation are complete offline, with owner acceptance still open. Pure HIDPP2121V1 serves shared wheel semantics; transport, identity, serial operations and owned cleanup remain in BoltController. MX4 full management staysfalse; only validated physical main-wheel preference/restoration writes are admitted. AppModel uses the non-amount interface and filters saved unsupported inversion/amount/button/thumb settings. UI exposes supported direction, input resolution and the existing restore policy, preserves real refusal messages, and has no3S artwork or capture/thumb/button controls for wheel-only access. Existing3S paths retain regression coverage. No schema migration or speculative future feature adapters were introduced.

Backend RED dynamic-index MX4 cases produced12issues before runtime correction; author finaltarget77 passes. AppModel behavioralRED has2tests/10expected failures before routing correction; finalauthorfrontend40passes. Independent combinedfocused321 passes (63XCTest+258SwiftTesting), full1,056 passes (625+431), first runs, with only WakeConnectionTests/NativeWorkspaceWindowTests excluded. No hiddenretry/extraexclusion. Whole-run logs /Volumes/Data/tmp/hidhogg-padding-mx4-{focused,full}.log.

All14 final fake-data captures exist and parent reviewed them:12 padding and2MX4 mainpanel/inspector. Never-shown/non-key window checks and no-read/no-write/no-input/config assertions pass. Preview paths /Volumes/Data/tmp/hidhogg-padding-offscreen and hidhogg-mx4-settings-offscreen. These are synthetic views, not screenshots from a physical connection. No native accessibility acceptance is inferred.

Signed app/CLI build `303a3f4139b4b18fa9c45d279fc45b7cafbdb2d9faed4b0af8b972ed9ba48272` passes strict signatures and CLI help. All326 input hashes match before/after tests/signing; finalmanifest hidhogg-padding-mx4-inputs.json; complete logs/artifact hashes/provenance dist/build-info.json. Base master `9eb6e8e6a86a95617807ea9b44e8c1bf08096ac7`; source uncommitted/unstaged, no push or production launch/live device queries/writes. Residual external-writer read/write window is best effort, not atomic CAS.

Owner next reopens signed app, checks padding, connects MX4 via Bolt, changes Standard/Natural and Low/High resolution, observes readback/native pointer/scrolling, then tests restore enabled/disabled across disconnect/reconnect. Bluetooth is a separate acceptance path. Other3S/4 hardware capabilities remain the versioned roadmap above; this is not full model support.

## Owner feedback — 2 November 2026

Owner reports: “Seems to work well.” Record acceptance of the current padding/initial MX4 settings behavior on the delivered build. The statement does not enumerate resolution/direction readback, restore-on/off reconnect, Bluetooth or fault cases individually; do not invent those results. Source remains uncommitted; no further implementation, commit, push or live operation was requested.
