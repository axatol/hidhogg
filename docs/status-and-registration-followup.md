# NX21 — Status correction and unresolved native behavior

## Owner evidence — 2026-10-21

Thumb-wheel direction works. Amount is difficult to distinguish and appears ineffective; it remains unaccepted. Single-instance Restart appears to work. Sleep/wake reconnection is acceptable for now, and its timing is unchanged.

Launch-at-login registration still fails: the screenshot shows `notFound` and `SMAppServiceErrorDomain`, code `22`, Invalid argument. This proves a reported registration failure, not its cause or the running build identity.

## Approved menu correction

Keep the current head size and restore its original eye. Add a larger status dot beside it inside the same original-color image, avoiding the previously observed missing second image. The head remains proportionally fitted within 22×18 points; a 3-point gap and 7-point slot hold a 6-point dot. These optical dimensions are implementation choices, pending owner visual acceptance. No neck/artwork editing is necessary.

Connected ready/enabled sessions with either Accessibility trust or event-post permission missing show yellow and an explanatory tooltip/VoiceOver label. Failure and cleanup uncertainty retain red priority; disconnected remains gray; transition states remain amber. Five colors and two appearances bound the cache to ten images. Existing permission refresh supplies state; no polling or new permission request is added.

## Thumb-wheel amount investigation

The slider calls `AppModel.setThumbwheelScrollAmount`; reconciliation requests capture, decoded `0x2150` reports reach `deliverThumbwheel`, and `ScrollSender` scales the horizontal axis by the selected amount. Existing tests cover these pieces separately, including fractional accumulation and amount persistence. No source defect or physical reproduction was established. Synthetic success cannot establish application-visible distance.

The remaining useful comparison holds direction and target application fixed, enables custom amount, checks that its state reads active, and compares substantially different amounts. If the visible distance still does not change, correlate raw rotation counts with admitted and posted line counts before selecting a fix. No per-event production logging or hardware experiment was added.

## Login registration investigation

The controller uses Apple's intended `SMAppService.mainApp` and permits registration from `notFound`. The current dist artifact passes strict/deep signing verification and has matching public bundle/executable/build metadata. Its identity does not prove which running copy generated the screenshot. Existing fake-service tests do not exercise native registration.

Apple defines [notFound](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/notfound) as inability to find the service; it does not establish the cause. The documented [mainApp service](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) is the appropriate API. No verified Apple mapping establishes a specific cause for this code22 result.

Next native diagnostic requires separate permission: identify the affected bundle/build, make one registration attempt, record pre/post status and a redacted underlying-error chain, and compare that bundle's metadata/signature. Do not unregister, clear Service Management databases, move the app, or substitute a LaunchAgent without evidence and approval. No live registration, owner OS-log scan, configuration read, app launch or input/device operation occurred in this investigation.

## Signed output and verification

Build `7d0895c00fff` (full `7d0895c00fffc5b77f10c66aadad2a45b87fa24f88aabcd2ef317a4eaed7df07`) is packaged at `dist/Hidhogg.app`. Signed executable SHA256 `b931ffff55f0140ad46349a2f7a2c10d9f2ed11beedd64bc794008768835343b`, 3,171,792 bytes. Strict/deep signature, approved certificate fingerprint, arm64/macOS26, menu-only metadata, unchanged head resource and executable/resource build identity verified.

Independent full suite passed **311 tests** (177 XCTest +134 Swift Testing), zero failures. Log `/Volumes/Data/tmp/hidhogg-nx21-tests.log`, SHA256 `e74e175b81b029e03dcc31953384fac60a0552c19c22215d28e99ad2b8c55ac2`. The worker focused attempt stopped before testing on sandbox_apply denial; the established scoped build route passed. The prior intermittent thumb-wheel observer assertion passed in this run; it is not declared fixed.

Manifest `/Volumes/Data/tmp/hidhogg-nx21-source.json`: 78 inputs, exactly five changed versus NX20, none added or removed. Only renderer, status mapping, label, label call-site and status tests changed. Runtime/configuration/transport/wake sources and artwork match baseline. No new native raster/helper launch attempted; final dot size, contrast and menu placement remain owner checks. No commit or push.

## Final polish — 2026-10-21

Owner confirms thumb amount works (prior baseline multiplier was excessive), beside-head styling accepted and login UI now Enabled without error. Actual launch after login remains untested; no live registration diagnosis needed absent recurrence. Approved statusdisc6→7.8pt (+30%) and slot7→9pt;3ptgap/head unchanged. Enabled login detail paragraph omitted; otherstatusdetails/warnings/errors retained.

Signed build883e4b12d0cc at dist/Hidhogg.app; fullID883e4b12d0cc659d0a96b3207160d9dfdcc5fcfbc44806dde4a6377b87fd86c0. ExecutableSHA2566f378e02ecbebfadda439dbcf5bfd1ac03b7491f0f03eaa44a457ccab4e611dd,3172848bytes. Releasecompile, strict/deep signing, approvedcert, headresource/buildidentity and diffcheck pass. ExactlyMenuBarIcon.swift+SettingsView.swift changed versus prior78-input manifest; all others match. The preceding311-test run predates this constants/conditional-only polish; no additional tests added or rerun. Finaldot optical acceptance pending. Log /Volumes/Data/tmp/hidhogg-nx21-polish-release.log; manifest /Volumes/Data/tmp/hidhogg-nx21-polish-source.json. No app/HID/input/loginmutation; no commit/push.

### NX21 midpoint dot — 2026-10-21

Owner approved6.9pt dot midway between6 and7.8; slot8pt, gap3pt unchanged. Only MenuBarIcon.swift differs from prior78-input manifest. Signed Release build31ea12d83d22 at dist/Hidhogg.app; compile, strict/deep signature and diffcheck pass. No additional tests for constant-only adjustment; previous311-test gate predates polish. Provenance dist/build-info.json; manifest /Volumes/Data/tmp/hidhogg-nx21-midpoint-source.json. Owner asks about native app switcher; proposed regular activation while workspace open/accessory afterclose, which also entails temporaryDockicon. Not approved or implemented yet. No runtime/nativeapp/device/login changes.
