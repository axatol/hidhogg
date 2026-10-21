# Historical startup and login-item checkpoint — 2026-10-20

Current artifact: [resolution verification](resolution-verification.md). Ownership policy and login recovery: [prior checkpoint](ownership-verification.md). The build and 159-test result below describe the preceding checkpoint.

Signed fixed bundle: `dist/Hidhogg.app`, build `c61c9133f5e5`, executable SHA256 `4e5bf024dea967183e507e96b9cb145bfe1284812a8d921e6f13e81a4316286a`, 2,528,384 bytes. Deep/strict signature, approved certificate fingerprint, arm64/macOS26, menu-only metadata, icon/accent/notices and frozen source fingerprints verified. Provenance: `dist/build-info.json`.

Independent combined suite: **159 tests passed, zero failures (101 XCTest + 58 Swift Testing)**. Log: `/Volumes/Data/tmp/hidhogg-start-independent-passed.log`. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-start-independent`. Includes 15 startup, 10 login-controller and 9 codec tests. SwiftPM reports the native-build-system flag deprecated. Release log: `/Volumes/Data/tmp/hidhogg-start-release.log`.

Settings → Startup offers Attempt connection on launch (default on, saved as root `connect_on_launch`) and optional Launch at login. One connection attempt follows valid initial loading, including Restart; missing config uses defaults, invalid config skips discovery. Existing candidate/capability/permission gates remain. No retry loop. A pending lifecycle stop cancels startup. Login status comes from macOS, with explicit approval/error states and a Settings link; registration only follows the user's toggle. No helper or extra runtime.

Tests use temporary configuration and injected service/session adapters. No real login-item status query/registration, normal app launch, owner configuration read, HID operation or process stop occurred. Actual login approval, startup device behavior and native process exit remain owner gates. Source is uncommitted pending owner acceptance; NX-03/04/05 remain in progress.

## Quick owner check

1. Close old copies and open the fixed bundle. Confirm one menu icon, no Dock icon, and one connection attempt. Inspect the device result through Open Hidhogg.
2. In Settings → Startup, disable Attempt connection on launch, wait for Saved and Restart: expect one disconnected successor. Enable, wait for Saved and Restart: expect one attempt. No retry is expected if the device is unavailable.
3. Toggle Launch at login; inspect the actual status and follow Open Login Items Settings if approval is needed. On a later login confirm one menu-only instance. Turn it off to unregister if desired.

Keep the bundle at its fixed path. Builds do not register login items. Existing [owner checks](logitech-acceptance.md) still apply.
