# D200X display controls and notification icons — 28 October 2026

## Approved boundary

Implement the seven investigated built-in wide-display modes, explicit custom screensaver image management, and static notification text or an installed-app icon. Execute a separate Now Playing feasibility/rendering spike. User approval does not authorize agent-operated device writes, screensaver replacement, live media capture or permission prompts. The user launches the signed app and explicitly applies screensaver changes.

Flashing backgrounds/borders are deferred. The initial notification implementation is static. Unverified mode100/command17, a screensaver timeout setting, restoration of the original screensaver, and firmware operations are excluded.

## Deliverables and verification gates

- [x] Typed persisted device-wide wide mode and 12/24-hour choice; custom content remains the default.
- [x] Status command6 framing for modes0/1/2/200/201/202/203, including the final date/weekday field and empty trailing separator where required.
- [x] Availability-dependent CPU/RAM/GPU sampler with initial CPU warm-up and no fabricated GPU0; physical accuracy remains uncalibrated.
- [x] Serialized mode/page/notification coordination, selected-mode restoration after wide notifications, reconnect and existing sleep policy.
- [x] Separate bounded screensaver crop/preview and root-JPEG ZIP command9, sent only by explicit confirmed Apply. No automatic screensaver reapply on reconnect.
- [x] Optional validated `app_id` in notification API, `--app-id` in CLI, notification form and static notification actions; legacy text remains valid.
- [x] Main-actor installed-app icon lookup with bounded cache and PNG snapshots passed to detached rendering; missing icons fall back to supplied text or the bundle identifier. No app launch, external URL/image loading or arbitrary file path from the notification sender.
- [x] Existing TTL, replacement, clear, dismissal, profile and authorization behavior covered for icon notifications.
- [x] Now Playing primary-source report plus an executed synthetic 458×196 rendering spike; no real playback queries.
- [x] Focused offline tests, independent review and test process cleanup, frozen-source signed build, build provenance and owner checklist.
- [ ] Owner physical acceptance of modes, screensaver placement/persistence, notification icons and lifecycle.

## Decisions and alternatives

Wide-mode and screensaver controls belong in the central device-wide settings area. The existing model remains the device/page writer; a second independent display writer would race notifications and lifecycle transitions.

Use firmware built-in clock modes where investigated rather than continuously replacing their display with host-generated images. Metrics use availability-dependent real system counters; disabled/unavailable output is preferable to invented values. The exact GPU registry property was sampled in the investigation, but availability is not a universal macOS guarantee.

Screensaver files use their own archive representation. The ordinary page manifest is not a screensaver format. A 1220×708 crop canvas matches the investigated host pipeline; it is not asserted to be physical screen resolution. Removal of a local candidate does not restore unknown device content.

Notification `app_id` identifies an installed application. It is separate from the subscription topic and is not an executable/path or script variable. Static rendering avoids guessing GIF playback support or introducing an unmeasured physical animation cadence.

Now Playing information is a content mode, with playback actions remaining separate. Universal metadata access, per-player automation and artwork/progress sources must be compared before claiming support. A visual progress bar does not imply seeking support.

## Ownership

`d200x_display_controls`: D200X model/device view, display/domain configuration, Ulanzi session/codec/archive, and only the `D200XDocument` part of the TOML codec. `notification_app_icons`: notification wire/store/CLI/action/editor/render/preview flow and only `NativeActionDocument` in the TOML codec. Root prepared the model icon bridges; display owner preserves and completes them. `now_playing_feasibility`: isolated spike and cited report only. Root owns integration, `.agents`, roadmap, provenance and signing. Workers must not overwrite each other's sections or run builds until the shared source is frozen.

## Evidence

- [Mode payload and image pipeline](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/session-display-investigation.md).
- [Accepted seven modes and wide fixture](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/run-190830-analysis.md).
- [Later screensaver and telemetry observations](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/run-002917-analysis.md).
- [Real counter sources and availability limits](/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/feature-investigation.md:53).

The later observations supersede older pending-appearance notes. Original screensaver readback/restoration and power-cycle persistence remain unverified. Native Swift hardware acceptance is separate from the investigation's earlier Python/device observations.

## Delivered software and limits

Signed build `13f34555eca71132786b3b421ba6e46174d4339ce8e2bef2175c609b6be2b4ea` passes strict app/CLI signatures. The independent broader fake-only gate passes 206 tests: 168 XCTest, 35 D200X Swift Testing and 3 protocol functions (including 21 malformed-input vectors). Focused21 checks overlap that broader gate. All 84 scoped input hashes match before/after testing and after the build; no owned test/compiler processes remain. Five CLI smoke cases cover help, invalid input and valid icon syntax against an explicitly nonexistent socket, without contacting the running app. `dist/build-info.json` records 225 source/resource/test inputs and the synthetic spike artifacts.

Evidence: `/tmp/dx-display-icon-independent-focused.log`, `/tmp/dx-display-icon-independent-broader.log`, `/tmp/dx-display-icon-independent-post.sha256`, `/Volumes/Data/tmp/hidhogg-d200x-cli-smoke-20261028.json`, `/Volumes/Data/tmp/hidhogg-d200x-displays-icons-release-20261028.log`. No app launch, real endpoint, HID write, native event capture or real media query was performed.

Clock updates send status only, avoiding repeated PNG rendering and notification revision changes. Crop previews coalesce edits into one cancellable renderer. Host sampler rights are scoped/released. A small metric-quality limit remains: the sampler retains its CPU tick baseline through a sampling pause, so its first post-pause delta can cover that interval; subsequent samples resume the two-second cadence. This does not fabricate a value or establish calibration against Activity Monitor.

Now Playing is an isolated [completed spike](d200x-now-playing-spike.md), not a live provider in the app. The preview contains synthetic data. Recommended production follow-up is explicit opt-in Music Automation, with system-output mute kept separate from playback state. Hardware appearance, GPU availability, screensaver placement/persistence and native icon lookup remain owner checks in [the validation checklist](d200x-parity-owner-checks.md).


## 28 October 2026 — approved temporary on-device screensaver preview

- [x] Owner approved hiding the app image after confirmation and previewing the confirmed screensaver on the deck for approximately five seconds before restoring active tiles.
- [x] Implement serialized latest-crop preview, five-second reset after each displayed crop/zoom update, and lifecycle-safe restoration of the current page/mode.
- [x] Fake-only verification and background signed build; no agent-operated hardware writes.
- [x] Correct default artwork to fit entirely within the bottom-right screen window and inspect against the overlay (offscreen widths320/620).
- [ ] Owner physical acceptance of immediate preview and restoration.

Confirmed first selection authorizes later crop/zoom uploads of that selected source. A new image requires confirmation. Preview must not be resumed by a stale timer after lock/sleep/disconnect, and must not put the guide into the JPEG. The approved boundary restores the active tiles, not the prior saved screensaver image.


Implementation decisions: screensaver activation uses recovered empty `(0,4)`, followed by full ordinary page replacement and selected wide-mode restoration; no command5 wake guess. Retained SendScreenData disassembly selects4 at desktop-runtime-disassembly.txt:25140 and constructs empty fields at25239; transport analysis in docs/archive/v2/ulanzi-studio-analysis.md:52 establishes zero-length logical payload. Immediate physical effect remains owner verification. Maintenance and status updates pause during preview; notifications/profile changes are retained and included in current-page restoration. A successful render-completion revision, rather than byte inequality, restarts uploads even when a new crop encodes identical JPEG bytes. Production lock observers are explicitly enabled; fake model tests leave native observation disabled. Lock invalidates an active preview and defers page restoration until unlock; this does not add general lock-to-screensaver behavior outside the preview. Sleep/disconnect invalidate preview and use existing lifecycle recovery. Confirmed-source retry is available through Preview on Deck. Large app image hides after confirmation; crop controls remain.

Worker focused validation:32 checks passed (26XCTest,6SwiftTesting), fake only; custom-wide restoration test caught and corrected the missing explicit mode2 reset. Log /Volumes/Data/tmp/hidhogg-saver-live-20261028-tests.log. Independent verification passed the same32checks after final source freeze, with17input hashes unchanged through testing/build. Final signed build7d5d9017151f73528ba39683425fe29c7e4eb782b8baef0f878fe461c8c40f58; strict app/CLI signatures pass. Log /tmp/dx-saver-live-independent.log and /Volumes/Data/tmp/hidhogg-screensaver-live-release-20261028.log. Crop burst uses identical JPEGs; active app-profile switching during preview is source-reviewed rather than directly exercised. Hardware activation/timing and native lock-event delivery remain owner checks.


## 28 October 2026 — wide-mode transition fix and retained preview

Owner reports CPU/RAM/GPU stays visible after selecting another mode, with counters turning zero. Approved scope: diagnose against the accepted investigation sequence, fix and run focused offline tests; retain the last successfully sent screensaver locally in a collapsed accordion across settings/app reopening. No device readback is available, so an image uploaded by an earlier build cannot be reconstructed retroactively.

- [x] Compare known-good wire payload/order and build a red-capable regression.
- [x] Correct mode transitions without presenting missing metrics as available telemetry.
- [x] Retain exact last sent JPEG in local assets; reopen preview without device writes.
- [x] Focused independent checks, offscreen UI inspection and signed release build.
- [x] Owner reports wide-mode switching and retained-preview follow-up working (28 October 2026).

Ranked candidates: empty numeric fields in nontelemetry status differ from the accepted probe; stale timer writes; page SmallViewMode metadata. Root owns preview store/asset methods/UI and persistence tests; wide_mode_transition_fix owns mode/model/protocol/tests and adds three small store hooks. Preserve existing screensaver timer/lifecycle/notification behavior. No live agent HID/app/endpoint operation.


Diagnosis: accepted run-190830 mode transitions use command6 with numeric CPU/RAM/GPU fields for every mode after one initial wide-background fixture; no page metadata change between modes was required. Swift nontelemetry payloads used empty numeric fields, an unobserved shape. Two model regressions failed27 assertions and one protocol regression failed6cases in /Volumes/Data/tmp/dx-wide-transition-red.log. A second observed source/model defect reused the clock timer on selecting system status and omitted the initial metric sample. Fix: numeric0 fillers only for absent ignored fields in nontelemetry modes (domain nil remainsnil; supplied validvalues remainallowed); mode0 still requires allrealmetrics. Selection/format changes restart scheduler with revision/epoch/cancellation guards; reconnect cancels old scheduler. Physical parsing failure remains an inference until owner rechecks hardware.

Root retained-preview checks: exact JPEG persists under assets/d200x-screensaver.jpg after successful command9, before optional immediate-activation failure; opening disclosure is read-only. Two synthetic tests cover newest image across reopen and invalid/symlink protection. Store load uses revision guards; forcing a seeded old-image load/send race is source-reviewed rather than a separate test. Offscreen collapsed/expanded native component layout inspected, fake disk store only; no foreground app or device access.

Final follow-up gate:38 independent checks pass (31XCTest,7SwiftTesting),25input hashes unchanged before/after tests and build, no ownedcompiler/test processes. Signed app/CLI build `d26b3a0e331884035af4a9eb43fdf13af9b9a0aeb822e548b7133b0cdffae7cd`; strict signatures and git diff --check pass. Logs /tmp/dx-wide-store-independent.log and /Volumes/Data/tmp/hidhogg-wide-store-release-20261028.log. No physical device operation. This is the current signed checkpoint, superseding earlier build references above.
