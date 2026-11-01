# Bluetooth UI follow-up — 31 October 2026

Owner reports generic sidebar icons have inconsistent colour/alignment, component battery text is clipped, menu popover has no device statuses, and startup shows Device Removed when the initial mouse route is absent. Approved scope also includes aligning Add Device with the device rows.

- [x] Use shared sidebar icon/title layout and primary icon colour.
- [x] Show all component readings without truncation at normal sidebar width; offscreen checked at 210 and 250 points.
- [x] Align Add Device icon/title with device rows.
- [x] Reproduce and correct menu content sizing; constrained proposals collapsed five rows to the same height as zero before the fix. The production container now retains height and caps scrolling at 420 points.
- [x] Repair invalid startup selection after successful configuration load; preserve valid selection. All 30 AppModelIntegrationTests pass, including four new startup cases.
- [x] Observe child device status updates directly in the menu content. The content now observes deck, keyboard and generic Bluetooth models as well as the registry model.
- [x] Verify fake startup behavior and offscreen layouts, build/sign app, update handoff. Final full gate: 812 tests passed; 30 focused startup/integration cases passed.
- [ ] Owner checks actual menu presentation, startup and sidebar.

No live app activation, private configuration/inventory inspection, device writes or actual notifications are part of agent verification. Earlier 808 offline tests did not prove native popover presentation.


## BT-04 UI corrections — 31 October 2026

Owner reported clipped sidebar component readings, inconsistent icon colour/alignment, absent menu status rows and Device Removed at boot. Approved correction includes matching Add Device layout. Generic/sidebar/Add Device now use shared SidebarLabelStyle, primary icon colour and wrapping component text. Actual extracted sidebar rendered offscreen at 210/250-point widths with all synthetic earbud readings visible.

Constrained NSHostingController sizing reproduced menu collapse: zero and five rows both requested 174.24 points before correction. MenuBarDeviceList now measures eager content and sets explicit height capped at 420 points; the same proposal yields 218.24 empty, 394.24 five, 594.24 twenty including fixture footer. Earlier ideal-size-only render missed the constrained case; actual native MenuBarExtra remains owner acceptance. Menu content now explicitly observes each child device model to refresh status values.

Successful initial configuration load replaces a missing native/generic route with the first registered route or Settings for an empty registry, preserving valid routes and avoiding phantom back history. Workspace shows Loading devices during load. Four new regression cases cover this; 30 focused integration cases pass. Final full offline gate passes 812 cases (492 XCTest + 320 Swift Testing), zero failures; WakeConnectionTests and NativeWorkspaceWindowTests excluded. No live app, device, inventory or notifications exercised.

Signed build `711bd1ab404b301654710c43b4fb21a6297a937fb117ed4c33dc8300ab9c9492` passes strict app/CLI signatures. All 250 source/package/script inputs are unchanged across final test/build; manifest `f2b6aa02b445a6e8e275f7a3e991b5bf48ca3894916269d98a7b2e00b5d159d1`. Logs/results: `/Volumes/Data/tmp/BT-04-verification-result.json`, `BT-04-full.log`, `BT-04-focused.log`, `hidhogg-bt04-release-final-20261031.log`. Owner should restart updated app and check first-device selection, sidebar/Add Device alignment, complete component readings, visible/updating menu statuses and navigation. Source remains uncommitted on master after4bf494a; no push. Preserve previous BT work and approved test readiness fixes. BT-03 owner UI acceptance is superseded by this correction trial, not presumed passed.
