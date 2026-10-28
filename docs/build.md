# Local application build

The Swift package contains the native Logitech/D200X/Flow Lite84 workspace and the local automation CLI. Builds do not launch them, enumerate HID devices or request permissions. Physical acceptance remains separate from compilation.

## Requirements

Apple Silicon Mac, macOS 26+, Xcode command-line toolchain supporting Swift tools 6.2 or later, and the established local development-signing identity. SwiftPM resolves the pinned swift-toml 2.0.0 dependency, including its C++ toml++ implementation; no package plugins are used. Third-party notices are packaged in Contents/Resources/ThirdPartyNotices.txt.

```sh
bash scripts/build-app.sh \
  --signing-identity YOUR_SIGNING_IDENTITY
```

Outputs: signed `dist/Hidhogg.app` and adjacent `dist/hidhoggctl`. The app retains the fixed path and identifier `com.hidhogg.app`. Permission retention is not guaranteed by path alone. Do not use an ad-hoc identity for local updates; the script rejects `-` and requires an explicit identity.

`flowlite84-status` is a separate developer-only SwiftPM executable, excluded from app packaging. Without arguments it prints usage without opening HID. Explicit `--read-only` opens only the exact Flow Lite84 receiver, reads one approved status snapshot, closes it and prints safe decoded fields. Optional `--refresh-once` performs one explicit refresh after connecting, bounded to two snapshots and the same deadline. Diagnostics retain only bounded semantic query-stage names. Its allowed commands and live-test boundary are recorded in [FL-01](flow-lite84-implementation.md); it does not change lighting, mode or firmware.

The script defaults its SwiftPM scratch directory to `/Volumes/Data/cache/hidhogg-swift-build`. Use `--scratch-path` for another directory beneath `/Volumes/Data/cache` or `/Volumes/Data/tmp`; its parent must already exist. Use `--output /absolute/path/Hidhogg.app` for an isolated verification product. Signing and verification occur on a sibling stage before replacing any existing output; a failed build or sign leaves it untouched. Replacement has a brief gap while an old bundle is moved aside. Do not build concurrent copies to the same output path.

Some managed execution environments reject SwiftPM's nested sandbox. The explicit `--disable-build-sandbox` option disables only SwiftPM subprocess sandboxing; it is not the default and does not alter app permissions. Environment escalation may also be required for the Apple build service. This was needed during the 2026-10-19 verification.

The accepted selected PNG is converted with native `sips` and `iconutil` into all standard ICNS sizes during packaging. The original design image is preserved. The icon is a raster design asset; button geometry and visual small-size acceptance are separate from packaging checks.

Packaging also compiles `app/Branding.xcassets` with native `actool` and declares NSAccentColorName. This supplies the app gold for native accent-aware controls in addition to the explicit SwiftUI tint/custom outlines. macOS user appearance overrides remain system-controlled.

HidhoggBuildID hashes the pre-sign app executable digest together with the selected menu-bar head asset digest for startup diagnostics. The local ignored `dist/build-info.json` verification manifest separately records current source, signed artifact and log hashes; it is maintained by the verification workflow rather than automatically emitted by the build script. The diagnostic-only `--permission-diagnostics` argument prints PID/build and Accessibility/post-event booleans, then exits before configuration/runtime construction; it never requests permissions or posts events. Launch attribution affects permission results, so a direct terminal invocation is not proof of the normal GUI process's permissions.

Open `app/Package.swift` in Xcode to inspect the package, or use the build script without opening Xcode. No old Xcode project or D200X source is used.


The packaged app declares `LSUIElement=true` and starts menu-only. Launch does not open or restore the workspace. Choose **Open Hidhogg** to open/raise its single window; while that workspace is open, the app uses regular activation and appears in the Dock and app switcher. Closing it restores accessory mode while the same device models keep running. **Quit Hidhogg** uses the pending-save/device cleanup path. The menu icon composes the selected head with connection status; Finder and permission drag retain the full-colour app icon. Settings offers optional native main-app login registration. Packaging never registers or launches the app; registration occurs only through the explicit user toggle.

The current custom bootstrap acquires per-user application ownership before SwiftUI/AppModel; diagnostics-only mode exits before that lease or runtime construction. Packaging never launches the app or touches the live ownership path. Close all legacy copies once before testing the new single-owner guard. See [workspace verification](workspace-verification.md).
