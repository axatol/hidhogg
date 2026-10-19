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

Open `app/Package.swift` in Xcode to inspect the package, or use the build script without opening Xcode. No old Xcode project or D200X source is used.
