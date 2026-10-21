Current bundle superseded by [NX16/17 wake/icon verification](wake-icon-verification.md), build3f0364e7af27. Prior accepted native-navigation evidence follows.

Owner acceptance — 2026-10-21: user reports native navigation correction looks to be working in build5813939a6fff. NX15 accepted (TaskView431 complete). Broader milestone/device/resource gates remain open. No commit: tested HidhoggApp scene attachment shares substantial earlier uncommitted lifecycle changes; preserve those rather than commit broader scope or fabricate an untested staged baseline.

# Current native navigation verification

## Native navigation correction — 2026-10-21

Signed fixed bundle rebuilt as `5813939a6fff` (full ID in `dist/build-info.json`); executable SHA256 `dfaf967ecf174b7be7a3bb119e41b77f22666a29ec3b7c1297c19683e84b1d4a`, 3,083,184 bytes. Strict/deep signature and approved certificate verified, arm64/macOS26. Release log `/Volumes/Data/tmp/hidhogg-native-navigation-release.log`. Source manifest `/Volumes/Data/tmp/hidhogg-native-navigation-source.json` contains69 files.

Native SwiftUI Go menu Back/Forward uses Command+[ / Command+] and the existing model history and enabled states. Registered once on the workspace Window scene; toolbar clicks remain. No device, configuration, cross-app navigation or lifecycle change. Owner confirms existing bindings work, including System Settings; earlier connection cause remains unconfirmed. Decision73 records alternatives.

Independent suite291/291 passed (157 XCTest +134 Swift Testing), zero failures. Log `/Volumes/Data/tmp/hidhogg-native-navigation-tests.log`, SHA256 `626ac6a8218b5460159a6f55fbf3503ea81c040f9f04d664b5b2eb13d32965e5`. Initial sandbox attempt could not access SwiftPM output-file-map; scoped escalated retry passed. Native build-system flag deprecation remains. No app launch/native dispatch or device operation was exercised.

Owner check: quit the running copy and reopen `dist/Hidhogg.app`; visit Devices then Settings. Confirm Go → Back and Forward, direct Command+[ / Command+], and the configured mouse buttons traverse the same history. Commands should disable at history boundaries. Source uncommitted pending owner acceptance; other milestone gates below remain open.

---

# NX13/14/15 — Diagnostics, ownership and navigation — 2026-10-20

## Verified output

Signed fixed bundle `dist/Hidhogg.app`, build `33a3a579798d`. Executable SHA256 `e11f216db9f877d60498bd39de2707641bc98eac0e14c22f18a699e9fe0dbbe7`, 3,068,016bytes. Strict/deep signature, approved certificate fingerprint, arm64/macOS26, menu-only metadata, icon/accent/notices verified. All68 frozen source/test/build hashes match `/Volumes/Data/tmp/hidhogg-workspace-final-source.json`. Provenance `dist/build-info.json`; release `/Volumes/Data/tmp/hidhogg-workspace-release.log`. No app launch during packaging.

Independent final suite: **291 passed, zero failures (157 XCTest +134 Swift Testing)**. Command `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent`. Log `/Volumes/Data/tmp/hidhogg-workspace-independent-final.log`, SHA256 `65b7ceb344a6caa39ba7f45d73f7a0823632d5625fe49df3ffb7e5ab9971d483`. Scoped escalation required for build-service access; only final warning is deprecated native build-system flag. Earlier gates failed before test execution: test-helper missingreturn (`hidhogg-workspace-independent-compile-failed.log`, SHA19670c28d570dcea70cb42894cd0081c8ad4319c3c470881737ca7b9177b9f14) and missingLogitechBolt import (`hidhogg-workspace-independent-compile-failed-2.log`, SHA65f99650dea4bfdb1d1b03d407ba076cabc13b964011363ce94281bba79ad7c0). Both were fixed before final pass; no early test-pass claim.

Preservation audit vs prior59-file thumb package:17 changed,9 new,0 removed; package/build script unchanged. Current68 hashes verified after signing; tracked spikes/archive/redesign/designs unchanged and unrelated local files preserved unopened. Independent bounded architectural reviews found no remaining actionable defect after private-parent validation, release-error ownership recovery, recurrence dedup and unknown-error redaction fixes. Source remains uncommitted pending owner acceptance.

## Recent Activity

Settings → Diagnostics → Recent Activity is full-width leading/left-aligned with wrapping selectable messages. Header shows time and stable diagnostic code; Details shows full event UUID, build and safe module/file:line. The identical event ID/code/build/source is persisted to Console under `com.hidhogg.app`/`diagnostics`. Codes are typed, not extracted from message wording. See [code catalog and troubleshooting](diagnostics.md).

Error sources identify reporting boundaries, not necessarily the throwing instruction. Console does not persist raw shortcut/configuration/path/error payloads. Unknown localized transport text normalizes to the typed transport message. Status dedupe uses separate semantic channels; recovery/absence permits recurring errors with fresh IDs without unrelated wheel changes flooding main status. History stays bounded100; no per-wheel-report diagnostics. macOS manages persistent retention.

## Single active owner

A custom bootstrap acquires an atomic per-user flock lease before SwiftUI/AppModel/device construction. Its persistent private Application Support `com.hidhogg.instance/owner.lock` is independent of bundle path/build. Descriptor checks validate parent/current-user directory and write permissions, private directory/file types/modes/ownership, single file link and no symlink traversal. The app never unlinks, truncates or replaces the lock inode; kernel descriptor closure releases ownership, with no stale-PID heuristic.

A cooperative duplicate requests the owner's workspace and exits before runtime construction. Activation is payload-free and queued until the menu-label openWindow adapter is ready; only the lease owner handles it. Normal Finder reopen is forwarded to the same presentation path. No process scans/kills, helper, daemon or additional runtime.

Restart freezes and verifies cleanup, releases ownership, then requests a fresh launch with a10-second callback/deadline bound. Failures including release errors may unfreeze only after verified reacquisition; otherwise old copy exits frozen. Late callbacks are ignored; a late candidate meets the same lock. Brief process overlap is allowed, simultaneous cooperative runtime ownership is not. Launch acknowledgment does not prove successor runtime readiness. Already-running legacy copies and other user accounts are outside this per-user cooperative guarantee; close older copies once when updating. Native app exit, notification delivery and workspace focus remain owner gates.

Native lock tests operate only in newly created temporary directories, covering independent descriptor exclusion/release, unsafe paths/modes/hardlinks, persistent inode, bootstrap factory ordering, duplicate/owner queue behavior, restart release/reacquire, competitor-after-unlock error, deadlines/late callbacks and Quit arbitration. No live ownership path or app process was inspected or controlled.

## Page navigation presets

Devices → selected Back/Forward binding → Navigation Presets offers Page Back and Page Forward using Command+[ and Command+]. These are established [Safari](https://support.apple.com/guide/safari/keyboard-shortcuts-and-gestures-cpsh003/mac) and [Chrome](https://support.google.com/chrome/answer/157179?hl=en) conventions, not universal semantic commands. Presets use existing physical-key shortcuts (ANSI positions33/30); application or keyboard-layout differences may require overrides. No new action engine or schema version.

A missing configuration now receives these defaults without writing a file merely by loading. `.empty` remains an explicitly inert disabled value. Existing configuration bytes, disabled/custom shortcuts and application overrides are unchanged. Choosing a preset changes only the selected control/current application scope, cancels recording and follows existing validation, immediate application and one-second autosave. Native keyboard delivery remains permission-gated.

## Three owner checks

1. Close older copies, open fixedbuild `33a3a579798d`, then inspect Settings → Recent Activity. Rows should align left. Expand an error's Details and match its event ID/code in Console; source and build should agree.
2. Open the updated app twice and try Restart. One active runtime/workspace should remain; brief restart process overlap is allowed. Confirm menu Open Hidhogg and Finder reopen raise the window after closing it. All older builds must be closed for the new cooperative guard to apply.
3. In Devices choose Page Back/Page Forward presets for the desired controls, wait for Saved and test browser history navigation. Existing bindings stay unchanged until explicitly selected; new missing-file configurations use presets by default. Confirm any application overrides remain.

No normal app/UI launch, live owner lock/process inspection or control, physical HID/input posting, permission prompt, native login/status operation, owner configuration/environment/PII read occurred in automated verification. Temporary filesystem lock tests and injected lifecycle/input/logging fixtures passed; actual GUI/focus/process-exit/device behavior remains owner acceptance. Tasks429/430/431 remain In Progress for those owner gates. Decisions69–72 record scope and alternatives.
