# NX-M1 verification

Current signed build and291-test gate: [workspace verification — 2026-10-20](workspace-verification.md). Prior256-test gate: [thumb-wheel/request-ID verification](thumbwheel-verification.md). Previous vertical amount: [verification](scroll-amount-verification.md). Previous188-test gate: [resolution verification](resolution-verification.md). Input resolution and direction share one verified mode transaction; SmartShift is deferred. Successful wheel settings now remain applied by default, with opt-in restoration. Launch connection and optional native login registration supersede earlier explicit-only startup policies below.

Scope: implementation and packaging on `next/logitech-slice`. Hardware and resource acceptance remain open. No normal app/configuration launch, HID enumeration/diversion, permission prompt, private configuration read or native keyboard posting was executed. The separately authorised permission-only probe is recorded below.

## Automated gates

**Historical menu-bar correction: 132 tests passed, zero failures (74 XCTest +58 Swift Testing).** Independent captured log: `/Volumes/Data/tmp/hidhogg-menu-independent-passed.log`. New delegate default-initialization, last-window and pre-workspace Quit regressions are included. Immediate draft delivery, trailing autosave, concurrent edits/flush, conflict protection, Reload retention, lifecycle arbitration, same-handle button/wheel coexistence and native request-budget fixtures are covered. Earlier checkpoint results below are retained for provenance.

Earlier independent package run passed **53/53 tests**, zero failures:15 configuration,13 app model/editor,4 shortcut sender,21 Bolt. Final focused app-model run passed7/7. Tests use temporary paths and injected action/session backends; the worker ownership test runs an empty CFRunLoop without opening HID. Final logs: `/Volumes/Data/tmp/hidhogg-full-tests-final.log` and `/Volumes/Data/tmp/hidhogg-appmodel-tests-final.log`.

Managed execution required scoped SwiftPM/XCBuild write escalation. An earlier scratch directory failed before testing due to artifact permissions; final verification used fresh `/Volumes/Data/cache/hidhogg-verify-final-nx04`. No failed test result was discarded.

Final independent changed-file audit found no production blocker or tracked frozen-spike changes. Unrelated local metadata, `.envrc`, diagnostic caches and spike binary were excluded and not opened. `git diff --check` passed.

## Historical menu-bar release artifact

- `dist/Hidhogg.app`: arm64, minimum macOS26, identifier `com.hidhogg.app`; packaged LSUIElement=true (no Dock/app-switcher entry).
- Release compilation and strict codesign verification passed. Extracted certificate SHA1 matched the established approved identity; no private key was exported. Temporary public certificate files were removed.
- Current executable SHA256: `432427cca74c9c957455639bafac51aee2b8be3184006716a42ad325e7e3ebc2`.
- Executable size:2,419,568 bytes. This is not an app-memory measurement.
- Startup-captured build ID prefix:`23f36efd6f39`, derived from the unsigned packaged executable; distinct from the final signed executable hash above.
- Native AccentColor asset compiled into Assets.car; asset inspection confirmed srgb components0.76/0.57/0.27/1 and Info.plist NSAccentColorName points to AccentColor. System user overrides and actual rendered appearance remain GUI checks.
- Packaged notices byte-match `docs/third-party-notices.txt`. SwiftPM pins swift-toml2.0.0 at `827506c90475e82d5a7f191f950fb3025cbdc0d6`.

## Review corrections

Owner-feedback correction gate passed **62/62 tests**, zero failures:15 configuration,22 app,4 shortcut sender,21 Bolt. Independent log: `/Volumes/Data/tmp/NX-FIX-VERIFY.swift-test.log`. The pre-fix connection tests reproduced unwanted ready-session disconnection; corrected ready save/reload/recording tests pass while queued/active activation cleanup remains fenced. Additional tests cover reserved combination keyCode21 with Command/Control/Shift, first-responder key-equivalent dispatch, repeated/duplicate capture suppression and bounded100-entry diagnostics. Corrected sources remain uncommitted pending owner GUI acceptance. Settings URL navigation, file drag and rendered native accent are source/package-reviewed rather than interactively tested.

The subsequent permission/restart gate passed **75 tests**:46 XCTest (15 configuration,31 app) and29 Swift Testing (6 sender,23 Bolt). Independent log:`/tmp/hidhogg-permission-restart-verify-final.log`. Tests cover separate AX/post mismatches without bypassing posting permission, non-prompting refresh, restart ordered cleanup/launch/termination, failure/duplicate handling, direct controller cleanup verification, and suppression of presses during synchronous restart freeze. Full Back/Forward tile hit targets use an explicit contentShape; real hit testing remains owner verification.

## Authorised permission-only probe

Owner explicitly approved an app diagnostic mode that exits before AppModel/configuration/HID initialization. Launch Services attempts failed with `-10810` and produced no report, including after precreating output files. Direct execution of the same signed app's `--permission-diagnostics` mode exited successfully and reported Accessibility trust=true and event posting=true (build prefix5aa6f2aef9a9). No prompt, event posting or configuration read occurred. Direct-launch permission attribution can differ from normal GUI launch; this does not reproduce or resolve the owner-reported normal-app disagreement. In-app dual checks, activation refresh and PID/build display provide the next verification step. The real restart button, System Settings interaction and dirty-draft dialog remain source-reviewed rather than executed.

Main and independent tester identified draft-save/reload interleavings, missing/invalid configuration readiness, queued session intent after Stop, and save/reload during pending enablement. Workers corrected those boundaries; injected app-model regressions cover configuration gates, revoked permission, document transitions and sleep/termination cleanup. Bolt regressions cover cancellation during discovery/enablement and recovery after terminal failure.

The suspected worker retain cycle was not reproduced by an empty-runloop deallocation test; explicit reference cleanup was retained. A proposed requirement to open the entire HID manager was withdrawn after checking Apple's implementation. No hardware proof is inferred from those reviews.

## Remaining owner gates

Follow [the short owner checklist](logitech-acceptance.md). Physical Forward behavior, callback timing, real permission delivery, native button restoration, sleep/reconnect/quit and actual idle CPU/memory are not verified. Abrupt crash cleanup and competing diversion clients are not supported acceptance claims. NX-M1 remains in progress until the owner gates are satisfied.

## Immediate preferences / termination correction — verified implementation

2026-10-19. Independent final frozen-source suite129/129 passed:71 XCTest and58 Swift Testing. Exact command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-live-independent`. The default managed attempt failed before tests on SwiftPM output-map I/O; the scoped escalated run passed. Captured successful log: `/Volumes/Data/tmp/hidhogg-live-independent-pass.log`. Focused model/wheel31, lifecycle11 and Bolt52 checks also passed. The original ready-only wheel regression failed before runtime changes; no pre-change red claim is made for every model test.

Earlier immediate-preferences signed Release build `49360ba4cc8f` at `dist/Hidhogg.app`; executable SHA256 `2bf83b437ba796a67f41e8550005c84a23fb1adfb4db4b7bf5738247cc920e0d`. Release log: `/Volumes/Data/tmp/hidhogg-immediate-release.log`. Deep/strict signature, approved certificate fingerprint, arm64/macOS26 target, bundle ID, native accent resources, logo and notices verified. Source/test fingerprints match the frozen test input; ignored `dist/build-info.json` records per-file hashes and log provenance. No normal app launch or owner process stop occurred.

Immediate valid editor preferences apply independently of disk saving. One-second trailing autosave coalesces edits; changes during save remain dirty until persisted. Reload and recording retain the connection. Failed Reload preserves last validated active preferences while disk overwrite stays blocked. Explicit Connect applies the current preferences; all-disabled controls are not diverted. Permission denial restores buttons without dropping wheel ownership. Quit/Restart flush pending edits; failed flush keeps the app open. Restart and Quit share one reservation, returning terminateCancel while cleanup runs and reissuing termination separately rather than waiting in terminateLater's modal loop.

Existing owner-process samples locate the old parent in NSApplication.terminate inside RestartCoordinator’s MainActor task; successor sample was in its ordinary AppKit event loop. This does not establish both instances were hung. The isolated no-config/no-HID AppKit reproduction failed before the delegate callback, including a staged synthetic app rejected by Launch Services. These startup failures are not native red/green evidence. Delegate/coordinator ordering is tested synthetically; real process exit remains an owner check.

Independent static review found no remaining production blocker within this scope. One combined interleaving is not directly tested: permission revocation during a paused wheel setter. Separate fixtures cover permission-loss disable, wheel/button coexistence and ownership retention, and paused-setter Stop serialization. Decision42 records the capability-cache tradeoff: unqueried rows are not rescanned during the same connection. Native-budget fixtures cover8–12 rows and reserve restoration IDs before diversion. Finite per-handle edits/activation cycles can require deliberate reconnection. No physical HID, abrupt-crash restoration, contention or overnight-resource claim is made.

Owner checks: [five-item checklist](logitech-acceptance.md). Source remains uncommitted pending owner acceptance; prior checkpoint234b3c2 remains intact.


## Menu-bar-only correction — 2026-10-19

Current menu-bar source/package verification and owner checks: [menu-bar verification](menu-bar-verification.md). This supersedes the prior normal-window launch policy. At this historical checkpoint: same process, same shared model, native menu and singleton workspace; automatic connection/login registration were added subsequently. Native menu clicks/focus/background device continuity remain owner gates.
