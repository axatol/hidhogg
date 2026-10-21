# NX-08/09/12 — Thumb wheel and request-ID correction — 2026-10-20

Historical checkpoint: [workspace verification](workspace-verification.md) records the current app, traceable diagnostics, startup ownership and navigation presets.

## Output and verification

Signed fixed bundle: `dist/Hidhogg.app`, build `f4523d8eb766`. Signed executable SHA256 `9f1abac560ecfeef7dac70c7e6906df8c1826ea44b1dce7e5107188b60a918cf`, 2,845,760 bytes. Strict/deep signature, approved public certificate fingerprint, arm64/macOS26 target, menu-only metadata, icon/accent/notices verified. All59 frozen source/test/build hashes match `/Volumes/Data/tmp/hidhogg-thumbwheel-final-source.json`. Provenance: `dist/build-info.json`; release log `/Volumes/Data/tmp/hidhogg-thumbwheel-release.log`. No app launch during packaging.

Independent final unfiltered synthetic suite: **256 passed, zero failures (124 XCTest +132 Swift Testing)**. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-thumbwheel-independent`. Log `/Volumes/Data/tmp/hidhogg-thumbwheel-independent-final.log`, SHA256 `7c8ec1d4dee7b0103f48a7eedc6a1b6ddc4eb87f05dc2a84d5a39191e4689e6a`. Scoped escalation was required for build-service access. SwiftPM warns the native build-system flag is deprecated. Earlier app/sender focused sandbox denial is not a test failure; injected scoped retries passed. Runtime thumb fixtures and final110-declaration Bolt gate passed; independent full gate supersedes their counts.

Independent architectural review corrected latest-stop-policy ordering and start/end fraction resets before signoff. Preservation audit:13 changed,6 added,0 removed vs prior53-file vertical-amount manifest; package/build script unchanged. Current59 hashes match. Tracked spikes, archive, redesign/designs unchanged; unrelated protected local files unopened. Source remains uncommitted pending acceptance.

## Thumb-wheel behavior

Devices → Thumb wheel offers Leave unchanged / Standard / Natural, observed/effective direction and runtime status. Custom thumb-wheel amount is optional0.25–10× with0.25 slider increments, selected default1×. Existing configurations leave both thumb preferences unmanaged. Connected edits apply immediately and autosave after one second; offline intent applies on connection. TOML `thumbwheel_inverted` is optional Boolean; `thumbwheel_scroll_amount` is optional finite numeric in range. Native direction-only changes require no input-posting permission; custom amount does.

Independent0x2150 state/admission/sender shares the existing serialized app/controller and Bolt transport. Lazy discovery adds no thumb requests to an unchanged configuration. Compatibility is conservatively limited to featureversion0; actual device version is not measured. Typed info preserves resolution/time/default-direction/raw capability values without inventing capability names. Selected event0 must be a20-byte long report; raw BE signed rotation and state0…3 are validated. Start/end reset fractions only inside admitted, timestamp-validated delivery; inactive movement is ignored. Separate senders prevent cross-wheel fraction/generation collisions. Normal reports do not publish UI state or diagnostics.

1×means one Quartz horizontal line per raw rotation count, **not native-equivalent distance or fixed pixels**. No extra resolution ratio or Options+ /180pixel-backend factor is applied. No acceleration, added tail, gesture notifications, alternate thumb actions or exact Options+ parity. Applications decide line distance and animation. Calibration may need owner feedback.

Physical direction is verified first; capture temporarily uses neutral inversion and applies recorded direction once in software. Native reporting/neutralization are always released on orderly stop, independent of physical retention. Physical direction stays by default; the existing restoration opt-in restores attributable baseline direction. Both wheel captures and buttons are attempted during cleanup even if one fails. Fresh posting checks gate capture and delivery; failures latch until explicit retry. Unknown/foreign state remains blocked rather than silently overwritten.

## Request-ID correction and alternatives

The owner screenshot exposed the previous lifetime15-request allowance. Both controller and native worker permanently consumed software IDs; the old tests expected exhaustion after repeated operations. The actual-controller red regression failed before correction (`/Volumes/Data/tmp/hidhogg-token-red.log`), then passed (`/Volumes/Data/tmp/hidhogg-token-green.log`). It now performs24 alternating direction edits with button cycles, exceeds15 read/setter requests, remains connected and restores a final owned setting. A paired-capture regression performs25 edits and exceeds100 status requests on each wheel before verified restoration.

One transport-owned lock-protected ledger now rotates IDs1…15 per slot/feature/function. Exact matched success plus completed send releases the ID; every throwing request conservatively retires it. Unique issuance identity prevents late/double completion releasing a newer lease. Controller capacity and all fake channels query/use that same production ledger/transaction logic. Unmatched or retired-ID replies cannot settle a current request. Production lifetime counters/read ceilings are removed. Complete-transition and final-cleanup reserves remain against available unretired capacity.

Caching alone only delays exhaustion; invisible transport renewal risks changing association or dropping ownership. Those alternatives were rejected. There is no automatic reconnect or new runtime process. The practical limitation remains that an old duplicate of a successfully completed identical wire tuple after eventual ID wrap is indistinguishable; no on-wire generation is available. Ambiguous-ID retirement and rotation are the selected conservative policy. Native late-response behavior is not established by synthetic tests. See [decision68](logitech-slice-contract.md) and [primary-source evidence](scroll-controls-research.md).

The owner’s terminology correction changes Reversed to **Natural** for both wheels; stored Boolean/wire behavior is unchanged. Genuine ambiguous-request exhaustion can still fail safely; ordinary successful edits have no lifetime allowance.

## Three owner checks

1. Quit the older copy and open the fixed bundle. Confirm build `f4523d8eb766` in Settings. Connect, then compare Standard/Natural under Devices → Thumb wheel in a horizontally scrollable document. Enable custom thumb-wheel amount and compare0.5×,1× and2×; check direction, useful distance and no duplicated motion.
2. Check vertical scrolling and Back/Forward still work. Repeat direction changes and button-binding edits without a request-budget disconnect. Let Saved appear, Reload and Restart; saved settings should return according to startup preference.
3. Disable custom thumb amount, then re-enable and Disconnect: native horizontal scrolling should return each time. Direction follows default retention or the selected restoration opt-in. No capture should remain when posting is unavailable.

No normal app launch, physical HID communication, input posting, permission prompt, native login/status API, owner configuration/environment read or owner process control occurred. Actual deviceversion/reporting, suppression/polarity/counts, visible Quartz output, native GUI/lifecycle/login and resource acceptance remain owner gates. NX08#424/NX09#425/NX12#428 remain In Progress for owner checks; SmartShift and exact Options+ parity remain deferred. Owner reports preceding vertical amount works in the current setup; that does not close unrelated gates.
