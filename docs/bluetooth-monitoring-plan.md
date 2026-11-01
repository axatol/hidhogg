# Current delivery — BT-01 / BT-02 / VERIFY-02

Generic paired Bluetooth discovery and read-only battery monitoring implemented, including verified registry fallback. Signed build `4cd8c060ff105e838591902ae0ea297aa90ddc4d9dea36ecd2574144203638a5` passes strict app/CLI signatures and includes the Bluetooth purpose string. Independent focused88 and full786 tests pass (466XCTest+320SwiftTesting), zero failures; WakeConnectionTests/NativeWorkspaceWindowTests excluded. All240Swift/Package/script pre/post/postbuild inputs match a7c22613febf3ce562d540a5ed45abdbe9f7bbcde3cbf6ca812acd71bf517c26. Final evidence below supersedes earlier approval-pending/failed-gate checkpoints, which remain historical. Owner confirms initial discovery/AirPods; updated registry fallback app acceptance remains pending.

# Generic Bluetooth discovery and battery monitoring — BT-01

31 October 2026. Owner approved starting the next planned slice after committed registry checkpoint4bf494a. Scope: discover existing paired Bluetooth devices, register selected devices for read-only battery/connection monitoring, allow multiple generic registrations, retain Add/Disable/Remove semantics and flat hashed configuration. Pairing remains in System Settings. No Logitech-specific HID++ Bluetooth configuration, firmware, generic nearby discovery or hardware writes.

## Checklist

- [x] Verify public macOS enumeration, identity, battery and notification APIs using docs/SDK only.
- [x] Define typed generic endpoint registrations and per-UUID navigation/management.
- [x] Implement read-only provider with lazy permission/init and no name-based identity merging.
- [x] Integrate discovery picker, per-device connection/battery/freshness and unavailable states.
- [x] Verify synthetic multi-device persistence, lifecycle, permission and source parsing cases.
- [x] Independent offline gate and signed build.
- [ ] Owner updated fallback/permission/lifecycle checks.

## Boundaries and assumptions

No agent queries of actual Bluetooth inventory, addresses, user-defined device names, private preferences/configuration, environment or device payloads. Compile-only platform probes and synthetic fixtures are allowed; owner performs live app discovery and validates hardware. Unknown/unsupported battery is unavailable, not guessed. System observation timestamp does not establish device-sample freshness. Bluetooth permission must be explained and requested only through explicit owner UI action. Disabled/removed devices must not remain actively monitored or trigger reconnect/read work. Public API availability and reliable cross-provider identity matching must be proven; do not merge via names, model IDs or address guesses. No automatic Bolt/Bluetooth deduplication in this generic slice.

Public evidence: Apple IOBluetoothDevice pairedDevices and CoreBluetooth retrieveConnectedPeripherals(withServices:) describe different enumeration paths. CoreBluetooth service enumeration is not proof of pairing; standard Battery Service0x180F/BatteryLevel0x2A19 is a candidate where supported. Implementation boundary follows verified SDK evidence, not promises of universal Bluetooth battery support.

## Selected initial provider — BT-01

Public framework research found no universal paired-device battery getter or reliable public IOBluetooth-address/CoreBluetooth-UUID crosswalk. Initial implementation uses IOBluetooth paired inventory as registration authority and exact normalized Bluetooth-address joins to a bounded read-only /usr/sbin/system_profiler -json -timeout10 SPBluetoothDataType report for optional macOS-cached battery fields. The installed tool's -help confirms JSON output, scoped data types and timeout support; its battery JSON schema is not a stable public API. Treat absent/unknown/ambiguous fields as unavailable, parse only known shapes/percent fields, never match by name and never log raw report/names/addresses. This gives useful existing-paired coverage without BLE scanning or connecting. CoreBluetooth/GATT is deferred rather than presenting connected/unpaired peers as paired. Framework LE enumeration/connection-notification completeness remains unverified; owner hardware trial required.

Provider is inert on construction. First inventory/report access is explicit owner discovery; persisted enabled registrations may resume read-only observation after previously granted/allowed access without prompting. Bluetooth purpose string included. Manual Refresh available; coalesced system connect/disconnect events refresh registered entries, no periodic polling timer. Values labelled macOS-reported, with observation time distinct from device sample freshness. Disable/remove revokes entry monitoring/callbacks; no IOBluetooth openConnection/pair/unpair or HID commands. System Information subprocess bounded by timeout, output size and one in-flight report; launch via Process absolute executable/argument array, no shell. Tests use synthetic JSON/process fakes only; no agent actual report capture.

## Sources and alternatives

- [Apple pairedDevices](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/paireddevices()) documents system-paired enumeration; Classic/LE completeness is not specified.
- [Apple retrieveConnectedPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)) describes currently connected service-matching peers, not paired inventory. [CBPeer.identifier](https://developer.apple.com/documentation/corebluetooth/cbpeer/identifier) is a separate OS UUID namespace. CoreBluetooth-only enumeration was rejected for the initial paired-only path.
- [Bluetooth SIG Battery Service1.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/BAS_v1.1/out/en/index-en.html) defines180F/2A19; deferred until explicit peer identity/provenance is addressed.
- [Apple protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources) requires a Bluetooth purpose string. Public authorization preflight/explicit request may use CoreBluetooth without scanning/connecting.
- Installed system_profiler -help (help only, no report) confirms scoped JSON and timeout options. Its report schema remains an implementation detail; conservative optional parsing is preferred to private Bluetooth preferences, private framework selectors or name-based IOHID joins. These alternatives were rejected due identity/privacy/compatibility uncertainty.

Validation limitation: no actual Bluetooth inventory, device report, battery read, connection or permission prompt has been exercised by agents. Synthetic report fixtures establish parser behaviour, not hardware coverage or freshness.

## BT-01 checkpoint — implementation complete, full gate pending

Typed Bluetooth endpoints, multiple generic UUID registrations, paired picker, per-device navigation/cards, menu/sidebar, shared management controls and app-wide Bluetooth permission row implemented. Provider uses paired IOBluetooth authority plus bounded read-only System Information JSON and exact normalized address joins; no nearby scan/connect/pair/HID command. Source report schema/LE coverage unverified at runtime. Worker90focused tests pass. Independent full run failed an unchanged Logitech thumbwheel assertion; isolated case passed. One authorized unchanged-source full retry executed771tests and failed ONE Lofree test on THREE assertions (not three failed test cases); all Bluetooth tests passed. The Lofree case passed isolated. Logs in dist/build-info.json and /Volumes/Data/tmp/hidhogg-bt01-*.log.

Suspected test synchronization defects: Thumbwheel waits only thumb capture before separate scroll capture assertion; Lofree waits connected/notbusy before initial editable snapshot, so setup edits can be ignored in that inter-event gap. No Logitech/Lofree production or test source changes made. Owner approval requested through async question for two test-only readiness corrections, then gate rerun; waiting answer. Do not silently broaden source scope or call full gate green.

Signed build988a88f0252c8094a0e4c455702ccc37a70a1f3bebf6d36db90d2577951c8aaa passes strict app/CLI signatures and includes Bluetooth purpose string.237source/package/script pre/post/postbuild inputs match c20eccb1f1bdebfe4a6af37e2687da0c4b66c2a819a1c06916f57425bc256a53. No production app/inventory/report/permissions/device operation. GenericBluetooth process tests use synthetic executables and cover already-started child cancellation, without direct OS-exit assertion. Source uncommitted on master after4bf494a. Public research/limits recorded above.

## Owner trial and approved redacted diagnosis — battery source gap

Owner trial shows paired discovery and AirPods components work, while two other connected devices report battery unavailable. Owner confirms macOS shows percentages for both and explicitly authorized a read-only redacted battery diagnostic. The diagnostic ran scoped System Information JSON and ioreg plist BatteryPercent snapshots without connecting/writing devices. Raw names/addresses/serials were neither emitted nor persisted. Anonymous results: two missing System Information readings have valid registry BatteryPercent values with exact normalized-address matches to those report entries. This establishes a provider coverage gap for these observed devices; it does not establish universal registry-key/API support.

Proposed correction (awaiting owner implementation approval): isolated read-only registry fallback, using BatteryPercent plus explicit Bluetooth address properties only; no display-name/serial guessing. Keep primary component readings intact; use fallback only when primary has no usable battery for that endpoint. Reject conflicting identities/invalid levels/ambiguous values. Bound subprocess time/output/cancel, default test/inert injection never queries the actual registry. Preserve per-entry stale readings/failures. Add synthetic matching/merge/failure/lifecycle cases and repeat focused/broader verification. Pending separate approval for existing Logitech/Lofree readiness-test corrections remains explicit.

## Approved follow-up — BT-02 / VERIFY-02

Owner approved the read-only registry fallback and both existing test-only readiness corrections. registry_battery_fallback owns generic parser/report/model/composition and tests; device_test_readiness owns only BoltThumbwheelTests.swift and FlowLite84ModelTests.swift; bluetooth_verification remains read-only. No further live diagnostic queries are authorized/needed. Root coordinates freeze, independent gate and signed release. Preserve primary AirPods components; fallback only missing endpoint reading. No native device runtime changes in readiness corrections.

## Final verified checkpoint — 31 October 2026

Read-only provider sources: paired IOBluetooth inventory plus bounded System Information JSON. If an enabled/current/paired endpoint has no primary reading, bounded IORegistry plist can supply BatteryPercent using normalized DeviceAddress STRING only. Approved redacted technical diagnostics confirmed that property; BD_ADDR is BYTES and ignored (no byte-order guessing). Unverified aliases/names/serials are not used. Primary main/components remain authoritative; missing/failing data retains earlier observations as stale per endpoint; late callbacks after disable/remove/sleep/stop cannot publish. No polling, pairing, connection or device writes. Generic registrations support multiple UUIDs and preserve native singleton policies/hash config cleanup. App-global Bluetooth permission row and lazy explicit permission request remain.

Two owner-approved test-only synchronization corrections: Lofree fixture waits for editable current-generation snapshot; Bolt wrap fixture waits for one coherent ready/captured/direction state per alternating edit. No Logitech/Lofree production source changed. Earlier one Logitech failure and one Lofree case/three assertion failures are retained as history; final full786gate passes. Logs /Volumes/Data/tmp/BT-02-focused.log and BT-02-full.log; postbuildmanifest /Volumes/Data/tmp/BT-02-postbuild.sha256. Signed build `4cd8c060ff105e838591902ae0ea297aa90ddc4d9dea36ecd2574144203638a5`,249current input hashes in ignored build-info; release /Volumes/Data/tmp/hidhogg-bt02-release-20261031.log. No production app launch or native device input; only separately approved, fully redacted read-only cache diagnostics.

Owner trial: restart updated app, use Refresh on the generic keyboard/glasses entries, verify battery fills in while AirPods components remain intact; check Add/Disable/Remove and app-wide Bluetooth permission flows. macOS cache/LE coverage and underlying report/property schemas remain platform-dependent. No automatic Bolt/Bluetooth merge. Source remains uncommitted on master after4bf494a, no push. Next planned slice remains Logitech Bluetooth investigation after owner acceptance/checkpoint.


## BT-03 — approved alerts and menu alignment (in progress)

Generic Bluetooth alerts default off, threshold 10%, configurable 1–100 inclusive. Recovery must reach five points above the threshold (capped at 100), strictly above it. Charging state is unknown. Native mouse policy is unchanged. A shared ten-minute cached check is restricted to enabled, connected devices while awake; no device connection or writes. Accepted sample identifiers and persistent per-component latches prevent stale readings and repeated alerts.

Menu rows now use a compact popover: names left, values right, component readings on a second line. Cached device classes provide icons, with a manual override and Bluetooth fallback. A standard menu was considered but restricts column layout.

- [x] Implementation and initial focused gate: 136 tests plus one shared-authorization integration test passed.
- [x] Resolve independent review findings and freeze sources.
- [x] Independent offline gate, layout review, signed build and manifests: 129 focused tests; full 808 tests (488 XCTest + 320 Swift Testing), zero failures. WakeConnectionTests and NativeWorkspaceWindowTests excluded.
- [ ] Owner acceptance of native popover interaction and notification delivery.


## BT-03 verified delivery — 31 October 2026

Implemented optional per-device generic Bluetooth battery alerts (default off, threshold 10%, range 1–100, inclusive), component latches and accepted-sample guards. A shared ten-minute cached check processes only enabled, connected registrations with alerts enabled while awake. Manual/discovery refresh retains full scope. Report providers read macOS cache snapshots; no pairing, connection or device writes. Native mouse notification thresholds are unchanged. Charging state for generic devices remains unknown.

Sidebar rows show connection dots and metadata-derived icons with a manual override; unknown kinds use the Bluetooth symbol. The menu is a compact popover with names left, battery values right and earbud/case components on a second line. Main readings remain visible alongside components. Actual row sources rendered correctly offscreen in light/dark mode; fit probe measured natural height for two rows and a 420-point scroll cap for twenty rows. Native menu interaction is not exercised.

Independent offline gate and focused results are recorded in `/Volumes/Data/tmp/BT-03-verification-result.json` and ignored `dist/build-info.json`. Signed build `675ced0e2c93ec3ee7d30192011b6e42292c5ff91e09559454d64610a2f69aa9` passes strict app/CLI signatures. All 248 Swift/package/script inputs match through testing/build: manifest SHA-256 `1e8a12dcccc1a87951a0f7a25ed9e9ebe5d5c9348b9a11e5961926e105c78e07`. Review regressions corrected icon-only pending-alert invalidation and scheduled refresh scope; deterministic tests reproduced both before fixes.

Owner checks: restart updated app, inspect aligned popover/navigation and generic sidebar icons, enable a generic battery threshold and verify actual notification delivery/permission flow, and observe scheduled cached updates. No agent production app launch or real notification delivery occurred. Earlier owner screenshot confirms registry fallback now supplies previously missing battery readings. Source remains uncommitted on master after `4bf494a`; no push. Preserve all BT-01/02/03 work and the two approved test readiness fixes. Next Logitech Bluetooth investigation remains deferred until this checkpoint is accepted.
