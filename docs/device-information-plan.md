# Device information and low-battery alerts

Approved scope, 2026-10-22: read battery and mouse firmware; show battery in the menu-bar menu and workspace sidebar; show detailed information/manual refresh on the device page. Optional native macOS alert below10%. No receiver firmware, serial collection, firmware installation or new device ownership.

## Checklist

- [x] Owner approves information slice and battery display locations.
- [x] Owner requests optional low-battery alert.
- [x] Existing protocol/lifecycle reviewed; bounded workers assigned.
- [x] Typed readback/parser and optional-error transport boundary verified offline.
- [x] Native displays, refresh and saved alert toggle integrated.
- [x] Background/offline regression and non-key native window checks.
- [x] Signed fixed bundle.
- [ ] Owner battery/firmware/permission and eventual alert-delivery checks.

## Decisions

| Topic | Choice | Alternative considered |
|---|---|---|
| Freshness | Read once per connection and manually; consume validated battery events | Repeated polling adds traffic/wakeups and is unnecessary for first slice |
| Optional failures | Information unavailable locally; real disconnect/I/O errors retain existing session safety | Treating every HID++ error as fatal makes optional metadata disruptive |
| Battery | Feature1004 capabilities decide whether percentage is meaningful; unknown charging never triggers alerts | Trusting an unadvertised percentage or guessing charging state could issue false alerts |
| Firmware | Bounded Feature0003 reads; named components and validated BCD version/revision/build | Original raw-only display avoided guessing; later primary protocol evidence now supports numeric formatting |
| Feature versions | Validate the documented minimum payload layout without inventing a numeric version whitelist; feature-version byte is not retained in this slice | An unverified whitelist could reject working devices; version-specific extensions require further evidence |
| Privacy | Do not request serial function or retain identity payload fields beyond entity count | Serial is unnecessary for one supported logical profile |
| Notification opt-in | Per-device TOML boolean, defaultfalse; request permission only when explicitly enabled | Prompting on connection/startup is intrusive |
| Alert boundary | Valid fresh0–9%, known discharging; suppress charging/unknown/invalid/stale | Inclusive10% differs from owner’s “below10%” |
| Repeat suppression | Persist one logical-profile latch, rearm at fresh>=20%; mark only after successful enqueue | Rearming at10% can spam on boundary oscillation; charging alone does not prove recovery |
| Persistence | User preference in XDG TOML; one app-local operational latch separate from configuration | Notification history/config chatter is unnecessary |
| Test interaction | Fake services and non-key background native windows | Foreground/device/notification prompts require a separate deliberate owner check |

## Evidence and limits

Existing local research: [device reads](/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/device-readback-protocol.md), [battery outputs](/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/dpi-thumb-battery.md). Primary protocol corroboration: [Logitech HID++ packet/feature discovery](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst), [Linux HID++ implementation, Feature1004](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c). Linux capabilities use byte1 bit1 for percentage; status uses byte0 percentage, byte1 level, byte2 charging, byte3 external power. Function0 battery notifications use the same fields. These describe protocol paths, not current connected hardware support.

Read-only capability/readback validation is owner-approved, but no live request has yet been run for this slice. Do not obtain device identity/serial fields, change hardware settings for a test, force discharge, or send real notifications without explicit owner interaction. Optional firmware entity enumeration is bounded to prevent unbounded traffic. No feature-version compatibility claim is made: lookup retains the dynamic index, not the version byte; the documented base payload fields are the parsing gate. An absent feature is explicitly unsupported. A matched protocol rejection, timeout or malformed payload is unavailable; the current transport does not retain a more specific protocol-error reason for presentation. Independent static audit identified these limits; version-specific interpretation and finer error classification remain follow-ups.

## Verification checkpoint — 2026-10-22

- Metadata focused suite18/18 passed. Tests cover dynamic feature lookup, bounded/malformed reads, independent optional failures, request-ID retirement/reserves, selected-slot battery events, event/read ordering, cancellation, disable revision and genuine transport failure.
- Native notification/controller and codec checks use injected adapters and in-memory latches. Independent review caught low→recovered→new-low during a held enqueue incorrectly latching the new episode; fixed with per-request invalidation and a single replacement enqueue, whose success is required before latching. The deterministic regression passed in the full gate.
- Full suite first run:214 XCTest cases (2 intended native skips), zero XCTest failures;167 Swift Testing checks with one issue in the previously recorded asynchronous snapshot assertion at `BoltThumbwheelTests.swift:451`. Isolated case passed; a single full retry passed212 XCTest +167 Swift Testing =379 ordinary checks, zero failures. No existing wheel test or runtime behavior was changed to hide the issue. Logs `/Volumes/Data/tmp/hidhogg-info-tests.log`, `hidhogg-info-thumbwheel.log`, `hidhogg-info-tests-retry.log`.
- Background native window gate2/2 passed at820×560 and980×680. Harness uses `orderBack` and visible/non-key assertions, no activation/front-order calls. Log `/Volumes/Data/tmp/hidhogg-info-native.log`. Existing canvas snapshots are synthetic; actual menu/sidebar values have no view-level assertion and no live hardware evidence yet.
- Signed `dist/Hidhogg.app` build `050d02547bd017b8aed3dff83f1f7586f952a466b0d15b2c7929a136da15ec8e`, strict signature verified. Executable4,112,272bytes, SHA256 `9a8295d4deff24827e881ad0aec7fd0b8132c7b5eef194bf8bfd166aa1129515`. Release log `/Volumes/Data/tmp/hidhogg-info-release.log`. No production app launch, hardware request, system notification prompt/post, owner configuration read, login change, commit or push.

### Owner check

1. Quit the older instance and open the fixed bundle. Connect; compare battery percentage/charging in the menu-bar menu, sidebar and device information card.
2. Refresh information while connected; confirm firmware values or honest unavailable state, and verify bindings/scrolling continue. Disconnect: battery must not look current; reconnect: information should refresh once.
3. Enable the below10% alert on the device page; macOS should request notification permission only then. Confirm toggle persistence and permission refresh. Real low-battery delivery remains untested until a natural eligible reading; do not force discharge.

## Presentation follow-up — 2026-10-22

Owner reports the information slice looks good and requests these presentation changes:

- [x] Name the mouse in the menu-bar battery item.
- [x] Sidebar: one centred mouse icon beside two aligned text lines; device name above connection and compact battery status on the same line.
- [x] Keep battery, its timestamp and alert controls in the top overview card.
- [x] Move firmware and information refresh to the bottom of the device page.
- [x] Verify with the existing background native window gate, then rebuild the signed fixed bundle.

No readback, notification policy, configuration, transport or navigation-sizing changes are included. Sidebar percentage stays compact, with charging conveyed by the battery symbol and full status available through help/accessibility text.

The follow-up changes four existing views and adds `DeviceBatteryOverviewView`. Independent static review found no material defect; background native window tests passed2/2, zero failures. The menu/sidebar arrangement is source-reviewed; no view-level label assertions or live visual acceptance are claimed. No full-suite repeat was needed for this presentation-only change. Log `/Volumes/Data/tmp/hidhogg-info-layout-native.log`.

Updated signed fixed bundle build `42d2e843700e096c772d3b14220ee0eba61c3aaa42e5344de2f3c8c5a8261fc0`; strict signature passed. Executable4,171,968bytes, SHA256 `dcc30948235f3c8db19eec960b5dee3484ebd17ec06141b5a86eef96deece279`;115-input provenance in `dist/build-info.json`. Release log `/Volumes/Data/tmp/hidhogg-info-layout-release.log`. Owner visual acceptance pending; no commit/push or live device/notification operations.

## Permission scope and firmware presentation follow-up — 2026-10-22

Owner requests a device alert checkbox beside battery, app-level notification permission controls in Settings, component labels instead of entity ordinals, and numeric firmware versions matching Options+ conventions.

- [x] Move only the per-device opt-in beside the battery; retain its existing setter and permission-request timing.
- [x] Move notification authorization status/errors/refresh/settings actions into app Settings, alongside the existing input-permission sections.
- [x] Label the mouse’s main firmware and secondary components rather than “Entity1/2/3”; preserve multiple records without inventing receiver/device associations.
- [x] Decode validated packed decimal version/revision/build. Do not reinterpret the complete stored value as an ordinary hexadecimal integer.
- [x] Focused formatter/parser/controller tests, background native gate and signed bundle.

New evidence resolves the earlier deliberate raw-value limit: the [manufacturer Feature0003 document, mirrored](https://lekensteyn.nl/files/logitech/x0003_deviceinfo.html) names main application(0), bootloader(1), hardware(2) and explicitly specifies packed BCD firmware number, revision and build. Thus `0x2201` plus build `0x0006` should display `22.1.6`, not decimal8705 or rawhex. All four build nibbles and both version bytes must contain decimal digits; otherwise show unavailable rather than a guessed version. [Solaar’s implementation](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/hidpp20.py) corroborates these component types and treats hardware separately. Hardware revision is the distinct raw byte1 field, not the firmware-version fields. No extra HID request is required to preserve it from the existing payload.

These records are layers of the same selected mouse. A type label is not evidence of another physical device or Bolt receiver firmware. Main device firmware is the primary row; secondary information may be disclosed separately. Notification/readback policy and transport requests remain unchanged.

Implementation preserves all main firmware rows with stable source-index identities and active flags. Main rows read “MX Master 3S firmware”; bootloader, hardware revision and unknown components are under “Additional version information”. Unknown firmware layouts and invalid BCD are unavailable. Hardware’s optional raw revision byte is retained from the existing response; no extra device request is added.

Verification:24 XCTest +18 selected Swift Testing checks passed, zero failures; new examples include10/99 boundaries,22.1.6, build leading zeros, invalid BCD, separate hardware interpretation, duplicate main rows, active flags and unknown types. Background native tests passed2/2 after their model fixture was given an isolated notification adapter and in-memory latch. The adapter fails if a permission prompt or notification enqueue occurs; neither occurred. Native layout rendering does not establish live label appearance, pointer interaction or Options+ value parity. Logs `/Volumes/Data/tmp/hidhogg-info-format-tests.log` and `hidhogg-info-format-native.log`.

Signed fixed bundle build `76acd0ab10d46cf6bd0438dda058b039e0b85790c9a1d4f38d31ef01d5a9660a`, strict signature verified; executable4,238,784bytes SHA256 `73ae87afe5e694598e71d2d0d46c82c0616ddf5c526e0bd3819d99104f124461`. Updated116-input manifest; release log `/Volumes/Data/tmp/hidhogg-info-format-release.log`. Source uncommitted/no push. Owner should check checkbox placement, Settings → Notifications and the displayed version against the value previously seen in Options+. Real notification delivery remains a separate owner gate.
