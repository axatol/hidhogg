# NX20 — Head-only eye status

Verified on 2026-10-21. Final menu-bar appearance awaits owner acceptance.

The fixed signed output is `dist/Hidhogg.app`, build `cc642f05d2f7d268d0dde316ee40f766744889c1b60139c739ee1dd7ce6b3d57`. Its signed executable SHA256 is `d2772f2197fda6edba3aa1fa9375e312f6bb3065fe451779b0f1533b131e4a50` (3,171,008 bytes). Strict/deep signature, approved certificate fingerprint, arm64, macOS 26 minimum, menu-only metadata and head resource identity passed verification. Tail is no longer packaged; historical artwork remains unchanged.

The selected head keeps its original silhouette and proportions within 22×18 points. A 3.5-point solid status disc overlays the eye inside a cleared 5.5-point opening, giving a nominal 1-point transparent radial gap. These optical dimensions are implementation choices for the requested smaller circle. The alternative of a painted outline was rejected because the owner requested empty space. The temporary Head/Tail selector and separate side dot are removed. One original-color image contains both head and status; eight small cached images cover four status colors and two appearances.

Independent tests passed: **311 total**, zero failures (177 XCTest and 134 Swift Testing). Log: `/Volumes/Data/tmp/hidhogg-head-eye-tests.log`, SHA256 `6f8f5a8cee52f20b94963620daa43caca50876b1cdd60121be08b7b570d33517`. Release log: `/Volumes/Data/tmp/hidhogg-head-eye-release.log`. The earlier intermittent thumb-wheel observer assertion remains documented in the preceding verification report; it did not fail in this run and is not declared fixed.

The source audit against the preceding 79-input manifest found five changed files and one removed trial-style enum. All other inputs match, including connection, wake, transport, configuration and tests. The current 78-input manifest is `/Volumes/Data/tmp/hidhogg-head-eye-source.json`. No production app, HID, input, permission or login-item operation was performed for this update. The preceding isolated native harness established visibility of the single-image label; it did not establish the final eye appearance or every display/highlight/contrast state.

The isolated raster helper compiled, but direct AppKit drawing aborted before output, and one bounded LaunchServices attempt failed with `kLSNoExecutableErr`. No final raster previews or eight-variant alpha/color proof were produced. Source clears the opening using the clear compositing operation; the resulting pixels and optical placement remain unverified. Further helper launches were stopped.

Owner check: quit and reopen `dist/Hidhogg.app`; check the smaller eye circle and clear gap at normal menu-bar size. Status meanings remain green connected, amber transitioning, gray disconnected and red failed/cleanup uncertainty. Tooltip text distinguishes states without relying on color alone.
