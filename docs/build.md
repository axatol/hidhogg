# Local application build

The application contains the native editor and Bolt Back/Forward integration. Builds do not launch it, enumerate HID devices or request input permissions. Physical acceptance remains separate from compilation.

## Requirements

Apple Silicon Mac, macOS 26+, Xcode command-line toolchain supporting Swift tools 6.2 or later, and the established local development-signing identity. SwiftPM resolves the pinned swift-toml 2.0.0 dependency, including its C++ toml++ implementation; no package plugins are used. Third-party notices are packaged in Contents/Resources/ThirdPartyNotices.txt.

```sh
bash scripts/build-app.sh \
  --signing-identity BD088C6A3D3855EA8F47857A604894BF98E3CF98
```

Output: `dist/Hidhogg.app`. This fixed path and identifier `com.hidhogg.app` replace the retired D200X app. Permission retention is not guaranteed by path alone. Do not use an ad-hoc identity for local updates; the script rejects `-` and requires an explicit identity.

The script defaults its SwiftPM scratch directory to `/Volumes/Data/cache/hidhogg-swift-build`. Use `--scratch-path` for another directory beneath `/Volumes/Data/cache` or `/Volumes/Data/tmp`; its parent must already exist. Use `--output /absolute/path/Hidhogg.app` for an isolated verification product. Signing and verification occur on a sibling stage before replacing any existing output; a failed build or sign leaves it untouched. Replacement has a brief gap while an old bundle is moved aside. Do not build concurrent copies to the same output path.

Some managed execution environments reject SwiftPM's nested sandbox. The explicit `--disable-build-sandbox` option disables only SwiftPM subprocess sandboxing; it is not the default and does not alter app permissions. Environment escalation may also be required for the Apple build service. This was needed during the 2026-10-19 verification.

The accepted selected PNG is converted with native `sips` and `iconutil` into all standard ICNS sizes during packaging. The original design image is preserved. The icon is a raster design asset; button geometry and visual small-size acceptance are separate from packaging checks.

Packaging also compiles `app/Branding.xcassets` with native `actool` and declares NSAccentColorName. This supplies the app gold for native accent-aware controls in addition to the explicit SwiftUI tint/custom outlines. macOS user appearance overrides remain system-controlled.

HidhoggBuildID records the pre-sign executable digest for startup diagnostics. The diagnostic-only `--permission-diagnostics` argument prints PID/build and Accessibility/post-event booleans, then exits before configuration/runtime construction; it never requests permissions or posts events. Launch attribution affects permission results, so a direct terminal invocation is not proof of the normal GUI process's permissions.

Open `app/Package.swift` in Xcode to inspect the package, or use the build script without opening Xcode. No old Xcode project or D200X source is used.


The packaged app declares `LSUIElement=true`: it runs from its native serpent menu-bar item without a Dock or app-switcher entry. Launch does not open or restore the workspace. Choose **Open Hidhogg** to open/raise its single window; closing the window leaves the same process running. **Quit Hidhogg** in the menu uses the existing pending-save/device cleanup path. The menu icon is a cached native vector template; Finder and permission drag retain the full-colour icon. Settings offers optional native main-app login registration. Packaging never registers or launches the app; registration occurs only through the explicit user toggle.

The current custom bootstrap acquires per-user application ownership before SwiftUI/AppModel; diagnostics-only mode exits before that lease or runtime construction. Packaging never launches the app or touches the live ownership path. Close all legacy copies once before testing the new single-owner guard. See [workspace verification](workspace-verification.md).
