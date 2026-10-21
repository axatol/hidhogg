Current artifact superseded by [NX18 menu/status verification](menu-bar-status-verification.md), buildd57ee9dd3a4a. Prior wake/raster evidence follows.

# NX16/17 — Wake recovery and menu-bar icon

Verified2026-10-21, Australia/Brisbane. Owner acceptance pending.

## Artifact

Fixed signed `dist/Hidhogg.app`, build `3f0364e7af27` (full `3f0364e7af270aa6792d8e8ede757a1a5fbae743118da1b4abca6bd25bb3c366`). Signed executable SHA256 `8f9f6468d8e0f62f2adb8ae45b05e478a3af9eecbe89144b7acd7e849ef19134`, 3,131,328bytes. Strict/deep signature, approved certificate, arm64/macOS26, menu-only identifier/accent metadata, main icon/notices and byte-identical selected menu resource verified. Build identity now combines the pre-sign executable digest and menu PNG digest (not the signed executable hash); a first verification assertion incorrectly used the signed hash, corrected before final pass. Release log `/Volumes/Data/tmp/hidhogg-wake-icon-release.log`.

Source/resource manifest73 inputs:72 Swift/package/script files plus selected PNG, `/Volumes/Data/tmp/hidhogg-wake-icon-source.json`. Ignored `dist/build-info.json` records hashes/results/native limitations.

## Behavior

Before sleep, an active ready/enabled non-uncertain session records resume eligibility, invalidates input delivery and starts serialized cleanup. Wake waits verified cleanup and the bounded terminal status. Recovery makes at most four normal discovery attempts, with delays0/1/2/4seconds: seven seconds total delay plus bounded transport work. Only typed transient discovery failures retry; ambiguous/unknown/safety/uncertain cleanup stops. Manual Connect/Disconnect, another sleep, Restart/Quit cancel old recovery. Manual Connect during pending sleep cleanup waits it. No general removal auto-reconnect or idle polling. New configuration preferences/schema were unnecessary.

Explicit sleep/wake, numbered attempts, restored discovery, cancellation and exhaustion appear in Recent Activity and Console. Restoration means discovery restored; existing permission/preference/binding reconciliation continues. Recent Activity is100 events in the current process, while Console may retain prior processes. A clean sleep stop shows Disconnected, not Failed. See [diagnostics](diagnostics.md).

Selected A1 variation1 uses one36px raster at18pt logical size, aspect-preserving crop inside16pt. Original source remains unchanged. Isolated AppKit render verified one selected representation, alpha>=8 bounds x2–34/y5–31; corrected explicit2x coordinate scaling and separate fallback symbol. No large source image retained by a dynamic drawing closure. Main app icon unchanged. [Asset and generation prompt](product-redesign/logos/menu-bar/README.md).

## Verification

Independent full package suite **309/309 passed**, zero failures:175 XCTest plus134 Swift Testing. Command `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent`. Log `/Volumes/Data/tmp/hidhogg-wake-icon-tests.log`, SHA256 `3adbb6eb2161ac19fe6b26301b5afd3a2726e925b30f354ca25c39e060152162`. First default-sandbox attempt failed before compilation on output-file-map permissions; scoped escalated retry passed. Deprecated native build-system flag warning remains.

Worker focused53/53 passed. Immediate Disconnect-before-sleep regression demonstrated red→green: stale ready status used to incorrectly resume, fixed by synchronous active-session intent gate. Red log `/Volumes/Data/tmp/hidhogg-nx16-immediate-disconnect-red.log`; final focused `/Volumes/Data/tmp/hidhogg-nx16-worker-tests.log`. Twelve real-AppModel adapter tests plus six coordinator tests cover enabled-session reenable, receiver readiness retry/success/exhaustion, cleanup ordering, duplicate notifications, lifecycle cancellation, delayed events, timeout and late status. Tests use injected sessions/delays and temporary config paths. Script syntax and image source typecheck pass.

No normal app launch, native power notification, physical HID/input, live process/owner lock, permission/login operation, owner configuration/environment/PII read occurred in these implementation tests. Prior owner-approved Hidhogg-only log query is documented separately in [investigation](overnight-disconnect-investigation.md). Native receiver timing and actual menu appearance remain unverified; retry bounds are conservative, not measured hardware guarantees. Final explorer audit versus prior69-file manifest:65unchanged,4changed (AppModel, DiagnosticCode, MenuBarIcon, build script),3new (coordinator/two test files),0removed; Package.swift and tracked docs/research unchanged. All73 package/source/resource hashes match after signing. A missing-terminal-status timeout invalidates delivery and session intent; a late ready status cannot enable input, but the discovered transport may remain connected until a later explicit lifecycle action. This conservative input stop does not prove immediate transport closure in that exceptional case. Source remains uncommitted among earlier dirty work. Decisions74/75 record alternatives.

## Owner checks

1. Quit the running copy and open fixed `dist/Hidhogg.app`; confirm selected menu-bar dragon is readable.
2. Connect once, confirm bindings, then sleep/wake the Mac. Confirm reconnection and bindings resume; check `app.lifecycle.sleep`, `app.lifecycle.wake`, `app.wake-reconnect.attempt` and restored event in Settings diagnostics.
3. Manually Disconnect, then sleep/wake: it should stay disconnected. If recovery exhausts, inspect the preceding typed failure and use Connect; no endless retry is intended.

TaskView432/433 remain InProgress pending these native checks. NX15 remains owner accepted. Full NX-M1 and other earlier gates are unchanged; no milestone notification or commit/push/prune.
