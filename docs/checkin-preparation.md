# Check-in checkpoint — 1 November 2026

Local branch `master`, baseline `4bf494a01cb1f12c77b151031f0ea96264a9b423`. Owner accepts the Bluetooth/sidebar/menu/count layout and authorizes local check-in, then requests D200X feature parity next. No push or branch rename is included.

## Included scope

- Generic paired Bluetooth discovery and read-only battery monitoring, bounded macOS report/registry fallback, permission handling and lifecycle fences.
- Persisted per-device battery alerts and thresholds, class-derived icons with a Bluetooth fallback, shared sidebar alignment, complete component readings and Add Device layout.
- Menu popover with aligned values, bounded measured content, direct device-model observations and connected/enabled count. Ordinary disconnections are neutral; explicit errors remain visible.
- Startup first-device fallback with no phantom navigation history.
- Editable thresholds with 200 ms typing debounce, immediate Return/focus-loss commit and invalid-value preservation.
- Two previously approved test-only readiness corrections for Logitech thumbwheel capture and Lofree editable initial snapshot. No native Logitech/Lofree transport changes in this checkpoint.

## Verification

Consolidated offline gate: **822 passed** (502 XCTest, 320 Swift Testing), zero failures. `WakeConnectionTests` and `NativeWorkspaceWindowTests` are excluded. That gate predates only the later threshold view debounce change; the final view compiled, four focused model tests passed, and an actual offscreen NSTextField typing probe failed before the change and passed afterwards without Return/focus change. A further synthetic matrix verifies delayed commit, latest draft, invalid input preservation and 100% boundary.

Signed app/CLI build `1446cb3a5b5e1dcb4462622566dc29a1ae2f8afe45ecd0db63574f9ff88fe54b` passes strict signatures. All 252 Swift/package/script inputs match final targeted-test/build manifests, SHA-256 `d8114d9995d957a3d74d213a7fc9326ac937bc5259366e401467f7468826e5e9`. No production app, real notification, HID command or media query was used. Earlier separately approved redacted battery diagnostics are recorded in the Bluetooth plan.

Evidence: `/Volumes/Data/tmp/BT-checkin-full-20261101.log`, `BT-threshold-debounce-verification.json`, `BT-threshold-debounce-matrix.log`, `BT-checkin-postbuild.sha256`, `hidhogg-bt-checkin-release-20261101.log`; current per-input hashes are in ignored `dist/build-info.json`.

## Next focus and remaining gates

D200X resumes next, replacing Logitech Bluetooth as the immediate priority without cancelling that roadmap. [Fresh parity review](d200x-next-parity-review-2026-11-01.md) recommends bounded ordered multi-actions; feature-code implementation awaits scope confirmation. Combined icon/message notifications and badges remain queued. Physical pages stay deferred, and custom encoder display commands remain evidence-blocked. No new D200X feature code is included in this checkpoint.

Actual battery notification delivery/cache freshness, final native typing and unrelated device hardware gates remain owner checks; they are not claimed by offline results. [Previous preparation record](checkin-preparation-2026-10-28.md).
