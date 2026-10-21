# NX19 — Two smaller icons and single-image status

Verified2026-10-21 Australia/Brisbane; final Hidhogg visual acceptance pending.

## Output

Fixed signed `dist/Hidhogg.app`, build `ef168673f088` (full `ef168673f088f572ac2bb97c0c29d6bb3990ec45134616afc320b325bb795d6b`). Signed executable SHA256 `4a82dc20501333b164f05a7e8e35470d7b2126c30c8897f57c64bb7bb2749d58`, 3,219,104bytes. Strict/deep signature, approved cert, arm64/macOS26/menu-only metadata/accent/mainicon/notices verified. Both staged PNGs byte-match sources; old singleMenuBarIcon.png is absent. Build identity hashes the pre-sign executable, headPNG and tailPNG in that order. Release `/Volumes/Data/tmp/hidhogg-dual-icon-release.log`; provenance `dist/build-info.json`.

Audit manifest `/Volumes/Data/tmp/hidhogg-dual-icon-source.json` contains79source/resource/preservation entries (the oldselectedPNG is preserved but no longer staged). Compared prior76:5changed(HidhoggApp,MenuBarIcon,MenuBarStatusLabel,MenuBarView,buildscript),3new(MenuBarIconStyle,head-clean.png,tail-swirl.png),0removed. All other baseline hashes, including runtime/lifecycle/discovery/config/test sources, match. No unrelated thumbwheel fix or discovery timing change.

## Design and selection

Menu → Icon style offers **A · Head** and **B · Tail**. Choice is in memory and defaults to Head on relaunch; no UserDefaults, TOML/schema or config write for this comparison. Head removes the false-ear/second-eye cutout. Both generated source PNGs retain complete silhouettes and one eye cutout; tail adds the large body swirl. [Assets and generation](product-redesign/logos/menu-bar/README.md).

Each glyph fits within22x18pt, with tight variable width instead of forcing side padding or stretching. Composite sizes: Head29.5x18pt (59x36px), Tail25.5x18pt (51x36px), including3pt gap and6pt dot slot (5pt paintedcircle with antialiasmargin). Parent deliberately revised the initial fixed31pt hypothesis to honor no added sidepadding; tester withdrew its obsolete dimension concern. Glyph masks are generated once then large sources released; cache has at most2styles x4statuscolors x2appearances=16smalloriginalimages.

NX18 HStack rendered only its first image in the owners actual menu bar, so a separate correctly colored dot raster was insufficient. NX19 supplies ONE composited non-template NSImage through Image.renderingMode.original. The glyph is explicitly black/white for the label light/dark scheme and dot retains semantic RGB. State mapping/help/VoiceOver remain unchanged; workspace activation stays mounted. [Apple original rendering](https://developer.apple.com/documentation/swiftui/image/renderingmode(_:)) and [colorScheme updates](https://developer.apple.com/documentation/swiftui/colorscheme) support this approach but do not establish automatic menu wallpaper/highlight behavior on every setup. High-contrast and highlighted-state variants are not implemented or verified; current desktop visibility is owner-confirmed only.

## Verification

Independent full suite **311passed**, zero failures (177XCTest+134SwiftTesting), including prior intermittent thumbwheel assertion in this run. Command `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent`. Log `/Volumes/Data/tmp/hidhogg-dual-icon-tests.log`, SHA256 `19fa52d287be707e1657ed89bde43b004c070f1beddccf84da69e1079d0945d4`. Prior NX18 failed log/isolated/fullretry remain preserved and the suspected observer race is not declared fixed. SwiftPM native flag deprecation remains. Worker typecheck, full compile and bash syntax passed; scoped build access addressed nested sandbox/cache restrictions.

Isolated raster gate covers16style/status/appearance composites, non-template and opaque colored dots, dimensions above; log `/Volumes/Data/tmp/hidhogg-nx19-raster.log`. Native harness `/Volumes/Data/tmp/HidhoggNX19MenuBar.app` and source `/Volumes/Data/tmp/HidhoggNX19MenuBar.swift` use productionrenderer/style plus SwiftUI/AppKit, no HidhoggApp/AppModel/HID/configuration. Parent launched this approved temporary app. ComputerUse attach timed out after198seconds, so no automated native screenshot or interactive verification. Owner answered **Dot and dragon both visible** for actual test item on current desktop. This verifies one nativevisibility context, not both styles/allstatuschanges/highlight/VoiceOver. Harness then gracefully terminated, exactbundle-path-filtered query confirmed zero remaining harness instances. Running Hidhogg/other apps were not controlled.

No normalHidhogg launch, hardware/input/power/permission/login/config/env read or operation in these tests; native app activity was limited to the no-device harness above. No code drift after test/build. Task435 InProgress until final app appearance accepted; priorNX18dot is explicitly not accepted and superseded.

## Owner check

Quit/reopen fixed dist/Hidhogg.app. Menu → Icon style → **A · Head** or **B · Tail** to compare. Confirm smaller size, filled false-eye area in A, visible colored dot and tooltip. Connect/Disconnect should update gray/amber/green. Choice resets on relaunch; choose a final design before deciding persistence. No need to repeat physical sleep tests; discovery latency is unchanged.
