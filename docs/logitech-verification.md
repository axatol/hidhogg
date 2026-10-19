# NX-M1 verification — 2026-10-19

Scope: offline implementation and packaging on `next/logitech-slice`. Hardware and resource acceptance remain open. No production app launch, HID enumeration/diversion, permission prompt, private configuration read or native keyboard posting was executed during verification.

## Automated gates

Independent final package run passed **53/53 tests**, zero failures:15 configuration,13 app model/editor,4 shortcut sender,21 Bolt. Final focused app-model run passed7/7. Tests use temporary paths and injected action/session backends; the worker ownership test runs an empty CFRunLoop without opening HID. Final logs: `/Volumes/Data/tmp/hidhogg-full-tests-final.log` and `/Volumes/Data/tmp/hidhogg-appmodel-tests-final.log`.

Managed execution required scoped SwiftPM/XCBuild write escalation. An earlier scratch directory failed before testing due to artifact permissions; final verification used fresh `/Volumes/Data/cache/hidhogg-verify-final-nx04`. No failed test result was discarded.

Final independent changed-file audit found no production blocker or tracked frozen-spike changes. Unrelated local metadata, `.envrc`, diagnostic caches and spike binary were excluded and not opened. `git diff --check` passed.

## Release artifact

- `dist/Hidhogg.app`: arm64, minimum macOS26, identifier `com.hidhogg.app`.
- Release compilation and strict codesign verification passed. Extracted certificate SHA1 matched the established approved identity; no private key was exported. Temporary public certificate files were removed.
- Executable SHA256: `be6a3123751def44edf513377b678a9dddf41798c9ba2bcae7f006a455caf6b9`.
- Executable size:1,861,520 bytes. This is not an app-memory measurement.
- Packaged notices byte-match `docs/third-party-notices.txt`. SwiftPM pins swift-toml2.0.0 at `827506c90475e82d5a7f191f950fb3025cbdc0d6`.

## Review corrections

Main and independent tester identified draft-save/reload interleavings, missing/invalid configuration readiness, queued session intent after Stop, and save/reload during pending enablement. Workers corrected those boundaries; injected app-model regressions cover configuration gates, revoked permission, document transitions and sleep/termination cleanup. Bolt regressions cover cancellation during discovery/enablement and recovery after terminal failure.

The suspected worker retain cycle was not reproduced by an empty-runloop deallocation test; explicit reference cleanup was retained. A proposed requirement to open the entire HID manager was withdrawn after checking Apple's implementation. No hardware proof is inferred from those reviews.

## Remaining owner gates

Follow [the short owner checklist](logitech-acceptance.md). Physical Forward behavior, callback timing, real permission delivery, native button restoration, sleep/reconnect/quit and actual idle CPU/memory are not verified. Abrupt crash cleanup and competing diversion clients are not supported acceptance claims. NX-M1 remains in progress until the owner gates are satisfied.
