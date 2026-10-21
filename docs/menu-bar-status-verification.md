Owner screenshot rejected dot visibility; NX18 is superseded by [NX19 single-image fix and dual-icon trial](dual-menu-icon-verification.md). Historical evidence follows; genericView/raster proofs did not establish actual MenuBarExtra rendering.

# NX18 — Larger menu-bar icon and status

Verified2026-10-21 Australia/Brisbane. Native appearance acceptance pending.

## Signed output

Fixed `dist/Hidhogg.app`, build `d57ee9dd3a4a` (full `d57ee9dd3a4aea6bbd3ac2245e60304c7a99f64e038d8381e85aa4b777550073`). Signed executable SHA256 `c429281d2f7e691597cf9be644048d1187216a81912631c7ab378a553b07bb98`, 3,158,496bytes. Deep/strict signature and approved certificate verified, arm64/macOS26, menu-only bundle/accent metadata, icon/notices and byte-identical menu PNG verified. Build identity combines pre-sign executable and PNG digests. Release log `/Volumes/Data/tmp/hidhogg-status-icon-release.log`; source manifest `/Volumes/Data/tmp/hidhogg-status-icon-source.json`,76inputs. `dist/build-info.json` records provenance.

Explorer audit versus prior73inputs:2changed (HidhoggApp, MenuBarIcon),3new (MenuBarStatus, MenuBarStatusLabel, MenuBarStatusTests),0removed; all other baseline inputs unchanged. Package/build script/sourcePNG/lifecycle/transport/discovery code unchanged. Broad earlier dirty/untracked work preserved; no commit/push or fullmilestone claim.

## UI and native conventions

Selected A1 retains its shape and source pixels, cropped to visible geometry without added transparent margin. Aspect-preserving fit24x20pt, one48x40cached raster; actual fitted glyph24x19.3548pt. Isolated AppKit alpha>=8 bounds x0..47/y0..38. No additional artwork side padding; macOS click-target spacing remains. A separate6pt original-color bitmap dot follows a3pt gap. Four tiny dot images are cached, with no polling or per-frame source decoding.

Green=ready/enabled connected; amber=connecting/enablingbindings/disconnecting; gray=idle/disconnected; red=failed/cleanupuncertain, with uncertainty overriding cachedphase. Tooltip and combined VoiceOver label share semantic state, independent of color. This summarizes the current supported device, not a speculative multi-device model. Workspace activation remains mounted on the label. Dot centerRGB samples: green52/199/89, amber255/141/40, gray142/142/147, red255/56/60, alpha255.

Apple documents [custom View labels](https://developer.apple.com/documentation/swiftui/menubarextra/init(content:label:)), [template/original image modes](https://developer.apple.com/documentation/swiftui/image/renderingmode(_:)) and [help tags](https://developer.apple.com/documentation/swiftui/view/help(_:)). Implementation keeps the dragon template-rendered and dot original-rendered. These API contracts and isolated raster checks do not prove macOS preserves colors/layout/VoiceOver in the actual MenuBarExtra; owner visual check is required. No NSStatusItem migration or extra runtime was introduced.

## Verification and retained failure

Independent final suite **311passed**, zero failures (177XCTest+134SwiftTesting); new status tests2/2. Command `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent`. Final log `/Volumes/Data/tmp/hidhogg-status-icon-tests-final.log`, SHA256 `958f0d36c3f3072510ef79266b7c85870705747798787bd3cd8d979b3e239450`.

First full run compiled but failed one existing SwiftTesting assertion: `thumbwheelAndVerticalCaptureEditsContinueBeyondIDWrapAndRestoreBothOwnedSettings` expected recorder.last.wheel.captureActive at BoltThumbwheelTests.swift435. Preserved `/Volumes/Data/tmp/hidhogg-status-icon-tests-failing-full.log`, SHA256 `03d1c0f5b256ffdf76ca5b6a5dd69d36eed90d1819c07954518121170f3a087c`. Isolated test passed1/1 (`/Volumes/Data/tmp/hidhogg-nx18-thumbwheel-isolated.log`, SHA256 `10e115c29f06bab00fe837e2bb07805f0bd38328ed4b544c277907534fb94d41`), then one full rerun passed. Test waits only thumb state before separately reading vertical state from an asynchronous observer; this suggests an observation race but does not establish root cause or production safety from that failure alone. No unrelated test/controller edits made. Retain as an unresolved intermittent test finding.

Worker pre-compile attempts were blocked by nested sandbox/build-cache permissions; independent scoped build access compiled and ran. Deprecated native build-system flag remains. Isolated AppKit raster check `/Volumes/Data/tmp/hidhogg-nx18-menu-icon.png` verified dimensions/alpha/color. No normalapp launch, live power/HID/input/process/ownerlock/permission/login/config/environment operation was performed. Actual menu visibility/color/tooltip/VoiceOver is not automated acceptance.

## Owner check

Quit running Hidhogg and reopen fixed dist/Hidhogg.app. Check dragon readability on the4Kdisplay, dot visibility/color, and hover text. Disconnect should show gray; Connect should transition amber to green. Red/uncertainty mapping is covered synthetically; do not provoke hardware faults just to test it.

Task434 InProgress pending ownerappearance check. Prior NX17 small glyph notaccepted and superseded by this correction. Prior wake recovery is owner-reported functional but~20second discovery latency remains separately deferred; NX18 deliberately does not alter discovery timing. Decision76 records scope/alternatives.
