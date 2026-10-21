# Menu-bar-only interface — historical 2026-10-19 checkpoint

Current artifact and policy: [2026-10-20 resolution verification](resolution-verification.md). The startup/login and Restart-disconnected statements below describe this earlier checkpoint and are superseded.

Owner-approved native menu-bar entry with a monochrome serpent silhouette and no Dock icon. One app-owned model/controller feeds both the menu and one workspace Window. Open Hidhogg opens/raises the workspace and activates the app without changing Dock policy; closing it does not stop the device session or quit. Startup/restoration suppress the workspace. No automatic connection, login item, daemon or idle polling was added.

## Verified output

- Signed fixed bundle: `dist/Hidhogg.app`, build `23f36efd6f39`, executable SHA256 `432427cca74c9c957455639bafac51aee2b8be3184006716a42ad325e7e3ebc2`, bytes2,419,568.
- arm64/macOS26+, com.hidhogg.app, LSUIElement=true and no LSBackgroundOnly; deep/strict signature and approved certificate fingerprint verified without owner metadata/private-key export.
- Full-colour ICNS, native accent and third-party notices retained. Menu icon is a cached18pt native NSImage template; parent rendered/viewed18pt/enlarged light/dark previews at `/Volumes/Data/tmp/hidhogg-menu-icon-preview.png`, without app/config/HID initialization.
- Independent package suite **132/132 passed**:74 XCTest+58 SwiftTesting. Command: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-menu-independent`. Successful log `/Volumes/Data/tmp/hidhogg-menu-independent-passed.log`; first sandbox failure preserved separately as `hidhogg-menu-independent-failed.log` (pre-test output-file-map I/O error). Scoped retry passed.
- Focused termination suite7/7 includes default delegate construction, last-window survival and forwarding Quit to the coordinator before any workspace opens. A generic NSObject default-construction negative control trapped with an all-default-argument initializer alone; explicit override control passed. Logs `/Volumes/Data/tmp/hidhogg-menu-delegate-init-repro.log` and `hidhogg-menu-delegate-init-control.log`. Production delegate now explicitly overrides init and reads the bootstrap installed synchronously in App.init.
- Release log `/Volumes/Data/tmp/hidhogg-menu-release.log`; frozen source/script/test fingerprint `/Volumes/Data/tmp/hidhogg-menu-final-source.json` matched tested/built files. Ignored dist/build-info.json holds provenance. Read-only source/scope review found no remaining blocker and no tracked spike/archive/design changes. Existing unrelated dirty files preserved/unopened.

## Owner check

1. Close older copies, then launch the updated bundle. Expect a monochrome serpent menu-bar icon, no Dock icon and no automatic workspace. The full-colour icon remains in Finder and permission dragging.
2. Choose Open Hidhogg. With the workspace active, confirm the Dock icon stays absent. Close the workspace, then Open Hidhogg again; expect one window with the same navigation/preferences.
3. Connect explicitly and check current bindings/scrolling. Close the workspace and confirm they continue. Menu Disconnect should restore the session state; Menu Connect should reconnect deliberately.
4. Use Quit Hidhogg while the workspace is closed, including after editing then immediately closing it. Expect pending edits saved and cleanup completed before exit. Restart from Settings should leave one successor menu icon with no automatic workspace and no automatic connection.

No normal app launch, owner process stop, owner configuration/environment/TCC access, HID enumeration/mutation or native keyboard posting occurred. Native menu rendering/focus/Dock absence, real close/reopen background continuity and process exit are therefore owner gates, not automated acceptance claims. Existing finite request-ID, release-arming, cleanup uncertainty and capability-cache limits remain: see decisions38–46 in the [contract](logitech-slice-contract.md). Source remains uncommitted pending owner acceptance; NX-M1/NX-04 are not marked complete by these offline gates.
