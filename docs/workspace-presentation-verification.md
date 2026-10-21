# NX22 — Window-dependent app-switcher presence

Owner-approved behavior on 2026-10-21: Hidhogg launches as a menu-bar app. Opening its workspace requests regular activation, which supplies a Dock icon and native app-switcher presence. Closing the workspace requests accessory activation while the same app/device sessions continue. Minimizing or switching to another app does not count as closing.

The existing bootstrap handles menu, duplicate-launch and reopen requests. It requests regular activation before opening the workspace, including reopening a retained window. A zero-size native view identifies the concrete workspace window; the existing app and window delegates are preserved. One app-owned coordinator observes that window's close notification. Observation survives SwiftUI bridge teardown and close/reopen, and is replaced when a different window attaches. Window/self captures are weak; no polling or application-wide window scanning is added.

This replaces an initial bridge-owned observer design that could miss close after SwiftUI teardown. The coordinator stores only the last successful activation policy, allowing a failed request to retry on a later open/close event. No new persisted setting, device runtime, reconnect policy or login-item behavior is involved.

Apple documents [regular/accessory activation policies](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum) and the distinct [window-close notification](https://developer.apple.com/documentation/appkit/nswindow/willclosenotification). These APIs support the implementation; injected tests do not establish native Dock/focus/window behavior on this desktop.

## Verification record

The first independent compilation and Release build failed because the default observer closure omitted an explicit return after a guard. The worker corrected this before final testing. Failed test log: `/Volumes/Data/tmp/hidhogg-nx22-tests-compile-failure.log`, SHA256 `18cd07db711fb1ab3d5f77aa03f6ae7006dfc6d6214a8781b03fb97583204dd5`; failed Release log: `/Volumes/Data/tmp/hidhogg-nx22-release-compile-failure.log`. Sandbox-only attempts failed before compilation; established scoped cache/build access was used. No failed attempt is counted as a test pass.

## Owner check

Final signed build **`9e322504174b`** (full `9e322504174bc1fc212a8e96e64d0d13261f51995891d4ad18869f215402bc92`) is at `dist/Hidhogg.app`. Executable SHA256 `d0b0b0096e61b101cdeedc55724d5d40047a5ec7f77128d72c0c5e73128a911d`, 3,246,720 bytes. Release compile, strict/deep signature, approved certificate, arm64/macOS26, menu-only launch metadata, head resource and build identity passed verification. Release log: `/Volumes/Data/tmp/hidhogg-nx22-release.log`.

The final frozen full suite passed **316 tests**, zero failures: 182 XCTest and 134 Swift Testing. Five coordinator tests cover startup, open/close, retained-window reopen, stale close/replacement, and close observation after bridge release. The prior intermittent thumb-wheel test passed; it is not declared fixed. Log: `/Volumes/Data/tmp/hidhogg-nx22-tests.log`, SHA256 `733c1c40a438eba8755f66f4d502774407fab31e462c98b33581d83c24d3b575`.

Independent source audit against the prior 78-input manifest found three changed existing files and four added files, with no missing inputs. Current 82-input manifest: `/Volumes/Data/tmp/hidhogg-nx22-source.json`. Runtime, configuration, transport, permission, login and artwork inputs match the preceding checkpoint. Tests use injected policy/observer callbacks; no live app, Dock, window, HID, input, login or owner-configuration operation was performed. Native behavior remains the owner gate below. Source is uncommitted; nothing was pushed.

1. Quit and reopen the fixed signed app: initial launch should remain menu-only.
2. Open Hidhogg from its menu: check the Dock icon and native ⌘Tab entry. Minimize or switch apps; the entry should remain.
3. Close the workspace: Dock/switcher entries should disappear while Hidhogg stays in the menu bar. Open it again and confirm the same behavior.

This update does not start the planned UI alignment or D200X implementation. The ordered [future roadmap](d200x-roadmap.md) puts UI acceptance before D200X source work.

## Owner acceptance — 2026-10-21

Owner reports the latest build looks good and requests check-in. NX22 accepted; no additional native tests were run by the agent. Broader resource and boot-login behavior remain outside this acceptance.
