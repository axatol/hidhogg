# Receiver ambiguity and vertical direction — 1 November 2026

Owner approved two corrections after LC-01: show a visible ambiguity warning, and make Standard/Natural consistent with and without custom scroll amount. Owner confirmed multiple Bolt receivers caused connection refusal; removing the extra receiver restored connection. Owner also confirmed macOS Natural scrolling is enabled.

- [x] Diagnose ambiguity using approved structured diagnostics; no device/identity reads.
- [x] Implement typed ambiguity presentation and clearing-on-success regression.
- [x] Reproduce vertical mapping mismatch through injected OS preference and real protocol fixture.
- [x] Apply semantic/wire conversion and capture normalization, preserving raw ownership/baselines.
- [x] Run focused/full offline gates, signed build and source-input verification.
- [ ] Owner verifies physical Standard/Natural with amount disabled/enabled.

No receiver picker, pairing, same-owner cleanup recovery fix, firmware, thumbwheel behavior change, forced capture or global preference writes. The previously reproduced uncertain-cleanup regression remains separately recorded in `logitech-lc01-connection-diagnosis.md`.

Direction contract: persisted `wheel_inverted` retains user intent (false Standard, true Natural). Native hardware inversion accounts for macOS Natural scrolling; custom-amount output uses the same semantic intent while raw mode bits remain the basis for foreign-state checks and restoration. The production app may read only the named scrolling-direction preference; automated checks inject its value and do not inspect live user preferences. Amount remains optional and the standard permission boundaries remain intact.

RED gate: `wheelVerticalDirectionMatchesNativeAndCapturedAmount` built and exercised OS false/true × desired false/true through the actual Bolt fixture, amount nil→1→nil, with restoration and captured output assertions. It failed eight expectations only for OS Natural=true; captured sign/horizontal assertions passed. Evidence: `/Volumes/Data/tmp/hidhogg-direction-red.log`. This verifies the synthetic mapping defect, not physical macOS rendering. Apple's [direction-inverted event documentation](https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice) describes preference-based direction inversion; the owner's native-versus-custom report supplies the physical symptom motivating the correction.

## Delivery and verification

The app reads only the named OS preference on discovery and vertical preference application; no global writes, polling or agent reads of the live preference. The captured stream keeps an immutable direction snapshot. Changing the sampled OS value invalidates the physical request comparison so a later application reconciles it; immediate monitoring of external OS changes is not implemented.

Focused gate passed 50 XCTest and 162 Swift Testing tests. Full offline gate passed 550 XCTest plus 326 Swift Testing tests (876 reported total), zero failures, excluding `WakeConnectionTests` and `NativeWorkspaceWindowTests`. Logs: `/Volumes/Data/tmp/hidhogg-direction-green.log`, `/Volumes/Data/tmp/hidhogg-direction-full.log`. Tests cover observed/effective semantics, native fallback, raw baseline/restore, preference snapshots, horizontal preservation and unaffected thumbwheel behavior, plus visible ambiguity with no lease and clearing after success.

Signed app/CLI build `40b20c46c34c132218fd5aebf0ca2e401174b8bbf6bef4f0877b3b09eac60e33` passed strict verification. Release log `/Volumes/Data/tmp/hidhogg-direction-warning-release-20261101.log`; all 271 captured source/test/package/build inputs remain unchanged (`/Volumes/Data/tmp/hidhogg-direction-inputs.json`). No production app launch, actual scroll/input posting, receiver operation or pairing was performed. Source remains uncommitted.

Owner check: keep macOS Natural scrolling enabled; compare Standard then Natural with custom amount off, on at 1×, and off again. Selected direction should stay consistent. Optionally reconnect the extra Bolt receiver to verify the explicit warning; remove it again for single-receiver connection until LC-02 provides selection. Physical acceptance remains open.

## Physical follow-up — not accepted

Owner subsequently reports both Standard and Natural behave like Standard on build `40b20c46...`. The offline fixture result is not physical acceptance. Reused the previously approved Hidhogg-only structured diagnostic read (last 15 minutes): the current build connected and verified a wheel preference at 19:39:05 Brisbane time, then completed session cleanup at 19:39:16. No direction-apply failures were recorded in that bounded window, but the log does not establish both picker changes reached the controller. Await owner confirmation of custom amount state and whether Connected/Observed direction changes during the comparison. No further production code or sign changes made in this follow-up.

Read-only source review found no deterministic no-op in picker → UUID workspace → owner reconciliation → controller mapping. Remaining test seam gap: app fake-session and protocol fake-HID fixtures are tested separately; no composed app/controller fixture currently proves the whole UI-to-wire path. Do not treat that gap as proof of the cause or alter inversion again without discriminating evidence.

Owner clarified amount both on/off, remaining connected, and Observed direction staying Not observed. The model skips unknown-support edits; a temporary fake-session test reproduced that behavior. However, actual controller connection preflight publishes supported/unsupported, not unknown, before ready. Therefore the fake test is not a proven physical reproduction and no lazy-probe production patch was made. Preserve the diagnostic test outside the repository and the log `/Volumes/Data/tmp/hidhogg-wheel-unknown-red.log`; obtain a cropped screenshot of the mouse card and vertical-wheel Advanced details together to reconcile status/selection. A repeated approved structured-code read in the next 15-minute window returned no matching recent Bolt/configuration events; this is a bounded absence, not proof of a disconnected process.
