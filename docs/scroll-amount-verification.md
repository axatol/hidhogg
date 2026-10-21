# NX-11 — Vertical scroll amount — 2026-10-20

Historical checkpoint: [thumb-wheel and request-ID verification](thumbwheel-verification.md) records the current package, Natural terminology and replacement of the lifetime-ID policy below. Owner reports this vertical amount control works in the current setup; broader physical/lifecycle gates remain separate.

## Output and evidence

Signed fixed bundle: `dist/Hidhogg.app`, build `88191e0457c7`. Signed executable SHA256 `3af2e41486ff0a66a861e91ec835d3d83d6dafbfe482a9b60eeb1ce3488d8958`, 2,686,304 bytes. Strict/deep signature, approved certificate fingerprint, arm64/macOS26 target, menu-only metadata, icon/accent/notices verified. Provenance: `dist/build-info.json`; release log `/Volumes/Data/tmp/hidhogg-scroll-amount-release.log`. The app was not launched by automated verification.

Independent final unfiltered synthetic suite passed220/220 (117 XCTest +103 Swift Testing), zero failures. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-scroll-amount-independent`. Log `/Volumes/Data/tmp/hidhogg-scroll-amount-independent-final.log`. The final added permission-revocation regression checks successful posting followed by denial, no subsequent post and cleared fractional state. The preceding219-test pass is preserved separately. The first final-gate attempt failed before compilation on scratch output-map access; scoped escalation passed. That failed output remains in the tool transcript because the retry overwrote its log. SwiftPM warns that the native build-system flag is deprecated.

Preservation audit against the prior resolution package:12 changed source/test files,3 new files,0 removed,38 unchanged; package/build script unchanged. All53 source/test/script hashes verified against `/Volumes/Data/tmp/hidhogg-scroll-amount-final-source.json` before and after release. A final test-only change updated the manifest after packaging; production hashes and the signed executable remained unchanged. Tracked spikes, archive, redesign and designs unchanged; unrelated local files preserved unopened. Source is uncommitted pending acceptance.

## Behavior and limits

Devices → Scroll → Custom scroll amount enables a native slider from0.25× to10× in0.25 increments. Existing configurations leave it off. Connected edits apply immediately and autosave after the existing one-second debounce; disconnected edits apply on connection. Optional TOML `wheel_scroll_amount` accepts finite numeric values within the same range. Nil uses native scrolling.

This is a fixed host multiplier, not exact Options+ acceleration/filter parity.1× means one Quartz line unit per normalized wheel count; it does not promise native1× distance, a fixed pixel distance or identical movement across apps. High-resolution reports are normalized by the advertised wheel multiplier. Vertical movement is scaled; horizontal data within the same0x2121 report is forwarded at1×. Independent horizontal thumb-wheel controls remain deferred. Fractional accumulation preserves small movements; no acceleration, timer tail or momentum is added. Applications may animate line events.

Custom amount requires input-posting permission. Capture is mouse-scoped, with temporary neutral device inversion and direction applied once in software. Temporary routing and neutralization are always released on orderly disconnect/quit/sleep, independently of the default policy retaining physical direction/resolution. Amount-only edits consume no HID requests. Bounded request exhaustion stops with cleanup rather than silently spending the reserved restoration requests.

The static report supports this functional subset. It does not establish exact Options+ parity, actual target-device report compatibility, suppression/no duplicates, polarity, count normalization or delivery in the owner’s target app. See [research](scroll-controls-research.md) and [decisions56–62](logitech-slice-contract.md). The earlier inertia characterization was retracted; NX-10#426 is deferred/unconfirmed. SmartShift NX-07, horizontal direction NX-08 and horizontal amount NX-09 remain deferred.

## Quick owner checks

1. Quit the older instance and open `dist/Hidhogg.app`; confirm build `88191e0457c7` in Settings. Connect with competing mouse software closed. In a long document, enable Custom scroll amount and compare0.5×,1× and2×. Check direction is correct and there is no double scrolling. Compare Low/High resolution at the same amount. Report the app and selected settings if movement differs unexpectedly.
2. Check Back/Forward still work while custom scrolling is active. Change amount, wait for Saved, Reload and Restart; confirm the value and scrolling survive without a stranded connection.
3. Disable Custom scroll amount and check native scrolling returns; re-enable, then Disconnect and check native scrolling returns again. Physical direction/resolution should follow the selected retention/restoration policy. If permission is denied, expect a visible blocker and native scrolling rather than capture without delivery.

No normal app launch, HID communication, input posting, permission prompt, native login/status operation, owner configuration/environment read or owner process control occurred in automated verification. Hardware/UI/resource acceptance remains open; Task427 remains In Progress pending owner checks.
