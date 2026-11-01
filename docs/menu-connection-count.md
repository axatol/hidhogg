# Menu connection count — 1 November 2026

Approved scope: show Hidhogg icon plus connected/enabled registration count (for example 4/5), without per-device menu-bar icons or visibility toggles. Disabled/removed registrations do not count. Ordinary disconnections are neutral to an otherwise healthy aggregate; actual errors and permission warnings remain visible. All disconnected is neutral. Device details remain in the existing dropdown.

Connection count is independent of health: a connected device with a permission or report error still counts as connected, while its warning remains visible. Missing battery data alone is not an error. Native keyboard connection requires the keyboard-online flag, not only a responding receiver.

Also approved: editable generic-device low-battery threshold alongside stepper, range 1–100. A 1 November correction adds saving after a 200 ms typing pause; Return and focus loss still commit immediately. Invalid input never changes the stored threshold and returns to the current value on commit. Existing persisted threshold and alert policy are unchanged.

- [x] Count and aggregate presentation with fake policy tests.
- [x] Threshold text field and stepper implementation.
- [x] Focused verification, offscreen threshold layout and signed build: 19 tests passed, zero failures.
- [x] Owner accepts menu/count/layout and requests local check-in. Debounced typing is verified separately with a never-shown synthetic control; new native typing remains an owner check.

Owner accepted the BT-04 sidebar/menu layout on 1 November 2026. This does not establish actual notification delivery or cache freshness.


## BT-05 connected-device count — 1 November 2026

Owner chose a simple connected/enabled count beside the Hidhogg icon instead of per-device menu-bar icons or visibility toggles. Disabled/removed UUIDs are excluded. Connection and health are separate: physically connected devices count even if permissions or battery-report errors are surfaced. Mouse ready/enabling/enabled counts connected; FlowLite requires keyboard-online rather than receiver-only connection. Ordinary disconnections do not degrade a healthy aggregate. All inactive is neutral; explicit inventory/report errors and permission failures remain visible. Missing battery readings and cancellation are neutral. Bluetooth permission warnings identify Bluetooth access rather than incorrectly directing users to input permissions.

Generic battery threshold now supports text entry alongside the Stepper, range 1–100. Return or focus loss commits valid input; invalid input restores the current model value. Control identity is per registration so draft/focus state does not carry across devices. Offscreen actual control rendered clearly at 10% and 100%; native typing/focus interaction remains owner acceptance.

Independent focused gate: 19 XCTest cases pass, zero failures (14 menu status/count, four device-information/model, one D200X aggregation). Tests cover 4/5, disabled/stale IDs, all inactive, error/permission matrices, connection-count independence and aggregation order. No full-suite rerun for this bounded presentation change; prior BT-04 full812 results are historical, not current-change full proof. No production app, OS prompt, inventory/report, actual notification or device operation was exercised.

Signed build `2dfb8047f522721bd9060c6183b02ae2a1185a6eca71251837804825aeb7d7b1` passes strict app/CLI signatures. All 252 Swift/package/script inputs match through final test/build; manifest SHA-256 `7fed0de0bea4e93e923162e1bc49f90ecd6a1016150b195260225dc80b43336e`. Evidence: `/Volumes/Data/tmp/BT-05-focused.log`, `BT-05-verification-result.json`, `BT-05-postbuild.sha256`, `hidhogg-bt05-release-final-20261101.log`. Owner should restart the updated app, check the count and disconnect/error indicator, and type valid/invalid thresholds with Return/focus loss. Source remains uncommitted on master after4bf494a; no push. Preserve all earlier Bluetooth work and approved test readiness fixes. Owner accepted BT-04 layout, but actual notification delivery/cache freshness remain unverified.
