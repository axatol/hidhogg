# NX-06 — Scroll-input resolution verification — 2026-10-20

Historical checkpoint: the current package and functional amount control are documented in [scroll amount verification](scroll-amount-verification.md). The owner later corrected the earlier inertia description to likely multiplier; NX-10 is deferred/unconfirmed. Original observations below are retained as history.

## Output

Signed fixed bundle: `dist/Hidhogg.app`, build `0d561b8fb66a`, executable SHA256 `4287ed1da2117539880f068975df58966902585d6a5990d220bb560bb1cd1c1e`, 2,569,792 bytes. Strict/deep signature, approved certificate fingerprint, arm64/macOS26 target, menu-only metadata, icon/accent/notices and all50 frozen source/test/script hashes verified. Provenance: `dist/build-info.json`; release log `/Volumes/Data/tmp/hidhogg-resolution-release.log`.

Independent full gate: **188 passed, zero failures (111 XCTest +77 Swift Testing)**. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-resolution-independent`. Log `/Volumes/Data/tmp/hidhogg-resolution-independent-passed.log`. Source manifest `/Volumes/Data/tmp/hidhogg-resolution-final-source.json` matches tested/built source. SwiftPM warns that the native build-system flag is deprecated. Scoped escalation was required for build-service scratch access; earlier config sandbox/transitional compile failures are retained separately. Final focused codec12/12 passed in `/Volumes/Data/tmp/hidhogg-resolution-config-actual-passed.log`; runtime/lifecycle logs `/Volumes/Data/tmp/hidhogg-resolution-runtime.log` and `/Volumes/Data/tmp/hidhogg-resolution-lifecycle.log`.

Scope audit: exactly nine expected source/test paths changed since the preceding ownership package, with no source paths added/removed. Frozen spikes/archive/redesign/design paths are unchanged; unrelated local files preserved unopened. No SmartShift or helper/process path added.

## Behavior and decisions

Devices → Scroll → Input resolution offers Leave unchanged, Low and High. Observed resolution shows the last validated device readback. Optional per-device `wheel_high_resolution`: absent/nil leaves unmanaged, false low, true high; existing files default nil. Connected valid edits reconcile immediately and save through the existing one-second debounce. Offline edits persist for the next connection. No manual Save/Apply step.

Direction0x04, resolution0x02 and restoration policy are one serialized request against the existing validated 0x2121 path. Native routing remains required, with reserved/routing bits rejected; the inherited version1/capability0x08 gate remains limited to the current MX Master3S/Bolt slice. No claim of generalized device support. Existing finite per-handle request budget and reconnection limits remain.

Successful settings remain applied by default. Optional restoration uses per-bit attribution: making one field unmanaged restores only its owned bit while leaving the other managed preference in place; without restoration it retains that value. At orderly stop, opt-in restores attributable bits to the captured baseline. Actual unknown full-mode changes block mutation; pending writes retain the exact prewrite mode for rollback. Current stop-policy handling, button cleanup and latest-mode tracking remain. Unverified cleanup intentionally clears both observations to Unknown; normal status transitions preserve both.

Tests cover nil/false/true strict codec behavior, mixed mode6→2→6→4 and one-write composition, both partial releases/policies, resolution-only changes preserving unmanaged direction, model coalescing/autosave without keyboard permission, failed/cancelled full-mode rollback, latest-policy stop, foreign drift, token limits and existing lifecycle regressions. See decisions52–55 in the [contract](logitech-slice-contract.md).

SmartShift automatic/ratchet/free-spin and automatic-switch threshold are deferred as **NX-07#423**. Task **NX-06#422** remains In Progress pending owner behavior check; previous NX-03/04/05 gates remain open.

## Owner observation — 2026-10-20

Owner reports: changing resolution makes scrolling larger, but some inertia remains. This does **not** satisfy the original stepped/non-smooth scrolling goal. The target app, selected resolution, running build and whether the physical wheel had stopped were not specified; no instrumented cause is established. NX-10#426 tracks distinguishing physical coasting, OS momentum and app animation, then defining a mouse-scoped solution. NX-06 remains a distinct resolution feature; other acceptance gates are not closed by this observation.

Owner clarification: Low moves approximately3 lines and High approximately60; around3 is desirable but the movement amount must be adjustable. These are user estimates with the app/increment unspecified. NX-11#427 tracks the separate amount/speed control; residual inertia remains NX-10#426.

## Quick owner check

1. Close the older copy and open the fixed bundle. Confirm build `0d561b8fb66a` in Settings. Open Devices → Scroll; select Low, then High and compare scrolling in the target app. Confirm Observed resolution follows each successful choice, direction remains correct and disk status reaches Saved. Low resolution does not guarantee whole-line movement or removal of app animation. If it already shows Low, remaining animation is not resolved by selecting Low again.
2. Leave the preferred setting, wait for Saved and Restart; check it is restored on connection. With restoration off, Disconnect should retain direction/resolution and release button interception. Optional restoration should restore only Hidhogg's changed bits to that connection baseline.

No normal app launch, native HID/input/login/status action, owner configuration/environment read or process control occurred in automated verification. Physical resolution behavior, GUI appearance, actual termination/login registration and resource use remain owner gates. Source remains uncommitted pending acceptance. [Research](scroll-controls-research.md) distinguishes device granularity from software smoothing.
