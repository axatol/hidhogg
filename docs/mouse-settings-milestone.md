# MX3S / MX4 settings milestone

Approved 2 November 2026. Base checkpoint 5973d41. One combined settings milestone and integrated signed build for owner verification. No live device operations or private runtime inspection by agents.

## Requirements

- Independent pointer speed and hardware DPI; pointer speed must feel consistent and take cues from Logitech, without prescribing a movement-multiplier implementation.
- Vertical scroll direction defaults Standard; thumbwheel defaults Natural. Remove Leave unchanged direction. Migrate old unspecified directions and apply saved direction whenever supported/connected.
- Main/thumbwheel direction and scroll amount, SmartShift mode/sensitivity and advertised wheel force.
- Capability-gated DPI, MX4 haptic enable/intensity/test and supported panel sensitivity.
- Physical button assignments for supported controls; preserve existing per-app assignments.
- Per-device persistence, debounced application, readback, lifecycle fencing and restore only still-owned changes.
- Shared session/transport with feature-version codecs, no wholesale MX4 write admission.
- No Bluetooth pairing, Ring, gestures, Flow or firmware updates in this milestone.

## Checklist

- [x] Reconcile established contracts; owner deferred pointer speed; V2 DPI write contract remains unresolved.
- [x] Domain/config defaults, migration and settings persistence; targeted56 tests pass.
- [x] Implement established adapters and guarded operations; V2 DPI writes remain blocked.
- [x] Integrate scroll behavior/directions; independent host pointer speed deferred by owner.
- [x] Accessible settings UI and model synchronization.
- [x] Independent offline verification, integrated regressions and signed checkpoint delivery.
- [ ] Owner manual verification; automatically commit accepted scope locally.

## Boundaries

Agent checks use fake transports/models only. Hardware capability absence is distinct from read failure; unsupported controls stay explicit. Existing restore preference remains authoritative. Test depth: focused feature/config/model correctness plus existing offline regression gate; no new live or end-to-end test without further approval. Unknown mappings/ranges are blockers for the affected write, not permission to guess.

## Contract checkpoint — 2 November 2026

Core feature-version backend and nested configuration are being integrated. Domain/UI remain independent of raw wire layouts. New pointer-speed path is capability-gated HID++2205V0, separate from2201 DPI; Solaar raw46...511/256 policy bounds are not hardware-advertised or proven Options+ UI bounds. Options+ retained reports prove separate pointer-speed/DPI concepts, but its exact pointer-speed implementation is unresolved. No ordinary-device identity is evidenced in a global Quartz tap; private IOHID-service host scaling is a separate potential fallback, not silently enabled.

Sources: [Logitech feature index](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst), [Solaar settings](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py), [technical Options+ DPI/pointer report](/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/dpi-thumb-battery.md).

SmartShift2110/2111V0, haptics19B0V0 and force19C0V0 use feature-specific status/capability/readback. DPI2201V0/V1 is restricted to one advertised sensor until multi-sensor and V2+ level semantics are verified. Force requires one changeable entry, not an invented force-index/CID association. Independent pointer support on the actual3S/4 remains unobserved; unsupported path will be explicit. Existing ScrollSender uses line events; retained Options+ research describes a nonlinear pixel-event pipeline, so equivalent feel is not yet established.

## Integration checkpoint — 2 November 2026

Nested hardware preferences and sparse optional middle/wheel-mode/thumb-rest bindings roundtrip per registration. Missing optional controls remain native; Back/Forward defaults remain required. Config/registry suites56pass. New fake model suite6pass for200ms latest-only debounce, nonowner isolation, disconnect cancellation, reconnect apply, explicit false/true direction defaults and haptic test admission. Old wheel nil/no-op expectations are being updated to the approved default policy without removing lifecycle/save-race coverage. Granular supportsWheelCapture/supportsThumbwheelManagement/supportsButtonManagement separate feature authorization. Optional button selection follows the effective foreground application, with production-only activation observation and immediate dispatch closure while the selected subset changes. Backend and expanded model verification remain in progress.

Public pinned OpenLogi fixtures freshly checked:3S table has36 entries, MX4 table46, both advertise2201 and neither2205. That is specimen evidence, not a live inventory. OpenLogi PR1922 describes2205 for mice without adjustable DPI and follows the DPI path on DPI mice. Independent host pointer speed remains a gap on these specimens; owner was asked whether to include a private-Apple-API per-device host implementation or retain this item pending. No dependent host code has been written while that choice is pending.

Sources: [3S fixture](https://github.com/AprilNEA/OpenLogi/blob/1851f89ac2f7c372d7191f91ed9d32f7573e97b7/fixtures/devices/mx-master-3s-001/cases/feature-table.json), [MX4 fixture](https://github.com/AprilNEA/OpenLogi/blob/1851f89ac2f7c372d7191f91ed9d32f7573e97b7/fixtures/devices/mx-master-4-001/cases/feature-table.json), [pointer-speed PR](https://github.com/AprilNEA/OpenLogi/pull/1922).

## Remaining contract gates and owner steering — 2 November 2026

Owner chose Keep pointer speed pending. No private-Apple-API host implementation will be added in this checkpoint. Generic advertised2205V0 scaling remains independently guarded; both pinned target specimens lack it.

Both pinned3S/MX4 tables advertise2201V2. Retained Options+ native setter appends its third argument as dpi_level forversion>1; ordinary UI caller, meaning and baseline/readback binding are unresolved. Pinned OpenLogi PR1952 explicitly leaves it unknown. V2 reads/current/default/ranges are now admitted, but setters remain blocked with explicit read-only UI. Source-supported V0/V1 writes remain verified. This is a remaining requested-feature gap, not completed DPI support for these target specimens. Native investigator had no connected REA/Ghidra session, and existing partial imports did not recover these setters; no repeated large import or guessed sentinel was used.

Follow-up query: resolve inbound native references to _set_dpi0x100a54d40, its+0x30 virtual dispatch, and SetSensorDPI0x1003f7188; trace ordinary numericDPI UI request to argumentw3 and establish how the corresponding state is read/preserved/restored. Schema field names and a zero-padded generic writer are not sufficient evidence.

Backend283 tests pass after real-ledger/cancellation/owned-recovery and haptic observed-rounding checks. Initial integrated fullgate ran641XCTest+456SwiftTesting and failed: real passive-enable/delayed-disable regressions plus old direction expectations/pre-lease fakeclock timestamps, and unrelatedD200X test cancellation synchronization. Failed log/333manifest retained. Parent corrected source eligibility/pendingdisable, updated test expectations while preserving lifecycle/registration assertions, and waits explicitly for D200X fakeclock deadline cancellation. Focused regression rerun is in progress; no new signed build or fullpass claim yet.

## Signed partial checkpoint — 2 November 2026

Build df12cc383925ee63277f4cadaeb41bf5833d12246b61c07181cfc251e51c2d27 is in dist/Hidhogg.app with adjacent hidhoggctl. Corrected targeted gate passes67XCTest+5SwiftTesting; final full gate passes641XCTest+456SwiftTesting (1,097 total), exactly the existing WakeConnectionTests/NativeWorkspaceWindowTests exclusions. All333 inputs match before/after tests/signing. Strict app/CLI signatures and CLI help pass. Parent reviewed final380/720-width fake offscreen captures: controls fit and card insets are consistent. No production app launch or live device/OS input/settings operations by agents.

Included: SmartShift/fixed modes/threshold/advertised force, wheel capture/thumb settings, selective V5/V6 Back/Forward/middle/mode/thumb-rest direct assignments, MX4 haptics/test/one-entry panel pressure, explicit default directions, UUID storage,200ms hardware debounce and owned readback/restore/recovery. Missing optional bindings stay native; foreground changes close dispatch while the selected subset settles.

Limits: owner deferred pointer speed; target-specimen DPI V2 reads work but writes remain blocked. Haptic firmware rounding retains actual intensity/capability state, while the unmatched desired value stays refused and restoration can be uncertain. This checkpoint does not complete all settings. Physical/Bluetooth/persistence acceptance remains separate.

Evidence: /Volumes/Data/tmp/hidhogg-mouse-settings-{inputs.json,targeted-iteration3.log,full-iteration2.log,release.log,cli-help.log}; backend283-case observation log; independent source review clear. First failed full gate/manifest and compile-overlap log are retained. Source remains uncommitted on master5973d41; automatically commit accepted scope after owner verification, no push unless authorized.

## Owner checks

- Reopen the signed app; connect each mouse and check vertical Standard/thumb Natural defaults replace only unspecified legacy values.
- Check wheel direction/speed, SmartShift/fixed modes/sensitivity and advertised force.
- Assign optional direct buttons and return to native; check app switching and primary clicks.
- On MX4 check haptic enable/intensity/test/power-saving and panel pressure/readback.
- Check restore off/on, disconnect/reconnect and per-registration isolation; Bolt/Bluetooth separately.
- DPI V2 should show current/range with a read-only explanation. Pointer speed remains pending.

## Tracking

Automatic approval review rejected TaskView task creation because it would externally transmit repository/build details and local paths. No task was created. Local tracking remains until the concrete TaskView draft is approved.

## Owner feedback after CPU fix — 2 November 2026

Owner confirms the window-freezing fix appears resolved and again reports inability to set DPI. This closes only the CPU-interaction acceptance item. The delivered build deliberately blocks2201V2 setters; DPI completion remains open. All1,098 offline cases and333build inputs remain verified. No further hardware acceptance is inferred. Public primary-source compatibility research is checking whether a source-backed V2 write/restore contract can resolve the existing gate.
