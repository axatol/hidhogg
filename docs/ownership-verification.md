# Historical ownership/login checkpoint — 2026-10-20

Current signed artifact and 188-test gate: [resolution verification](resolution-verification.md). The build and 177-test result below describe the prior checkpoint.

## Verified output

Signed fixed bundle: `dist/Hidhogg.app`, build `d45cde0bd9ea`, executable SHA256 `c7b4824e7578cb2b40af5f982a58892729efa7b3c33836dcd6b0a8498f65369a`, 2,554,304 bytes. Deep/strict signature, approved certificate fingerprint, arm64/macOS26, menu-only metadata, icon/accent/notices and all 50 frozen source/test/script hashes verified. Provenance: `dist/build-info.json`; release log `/Volumes/Data/tmp/hidhogg-ownership-release.log`.

Independent combined gate: **177 passed, zero failures (108 XCTest + 69 Swift Testing)**. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-ownership-independent`. Captured log: `/Volumes/Data/tmp/hidhogg-ownership-independent-passed.log`. SwiftPM warns that the native-build-system flag is deprecated. Focused ownership tests: `/Volumes/Data/tmp/hidhogg-ownership-worker-tests-final.log`; attribution regression failed against the old guard in `/Volumes/Data/tmp/hidhogg-ownership-worker-attribution-red.log`, then passed. Login regression red/green results were captured only in worker tool output, not standalone logs; its earlier red-named file contains a pre-test sandbox failure, not test evidence.

## Resulting behavior

Hidhogg retains verified wheel-direction changes on ordinary Disconnect, Quit, Restart and sleep by default. The device page offers **Restore previous device settings on disconnect**, initially off, stored under the device as `restore_previous_settings_on_disconnect = false`. Opt-in restoration uses the captured connection baseline and only attributable mode values. Leave unchanged retains current direction by default; with restoration enabled it releases Hidhogg's wheel change by restoring that baseline. Saved shortcut configuration is retained, while temporary button interception always ends when handling stops. No firmware persistence across power cycles or OS-level exclusivity claim is made.

Policy/direction requests and teardown are serialized. Stop receives the latest valid draft policy even if its reconciliation has not started; it never applies a queued direction just to disconnect. Separate pending-write provenance allows rollback of an uncertain mutation without discarding an earlier verified preference. Opt-in recovery accepts both the attempted target and the exact immediate prewrite mode, fixing a failed second-setter case. Other full modes are rejected. Unrelated resolution drift is rejected before mutation. Desired TOML configuration is not erased by a physical-write failure and can be retried on a later connection.

The Launch at login switch now permits explicit registration from macOS notFound. Initialization and activation refresh remain read-only. Real errors include domain/code and remain visible through unchanged refresh; status and approval remain OS-authoritative. The controller-blocking defect is reproduced with an injected service and corrected; the cause of native notFound and actual registration success are still unverified. No app relocation, registration reset, helper or LaunchAgent was added.

## Quick owner check

1. Close the older copy and open the fixed bundle. Confirm build `d45cde0bd9ea` in Settings. With restoration off, change scroll direction, then Disconnect: the direction should stay applied and buttons return to native behavior.
2. Reconnect, enable restoration, and change to the opposite direction. Disconnect: it should return to the direction observed at that connection's start. Turn restoration off afterward if you want permanent ownership.
3. Try Launch at login. It should accept the click from notFound and show the actual enabled/approval state or an operation error with domain/code. If it fails, report that text. Actual launch at a later login remains an owner check.

No normal app launch, real login API status/register/unregister action, physical HID/input operation, owner configuration/environment read or process stop occurred in verification. Native GUI, device retention and process termination require owner acceptance; broader physical/resource gates remain open. Source remains uncommitted pending acceptance. Decisions49–51 and the [general checklist](logitech-acceptance.md) retain constraints.
