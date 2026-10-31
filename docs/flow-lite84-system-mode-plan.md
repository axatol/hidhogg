# Flow Lite84 system mode and accessible controls — FL-03

## Current approved follow-up — 29 October 2026

Owner reports the previous controls work well and approved 200 ms debounce for both lighting and Mac/Windows selection. Remove mode Apply; keep serialized writes/readback and separate explicit Undo controls. Summary now contains device/connection/battery only; voltage/timestamps/firmware move into an initially collapsed Device information disclosure. Keyboard mode loses its redundant reported-selector row, lighting keeps icon choices/sliders/idle-off, and every section gets16pt inner padding. Earlier explicit-mode/500ms notes below are historical.

- [ ] Latest-only 200 ms lighting and mode queues with shared serialized writer.
- [ ] Mode rebase/in-flight revert, cross-kind fairness and failure/lifecycle cancellation tests.
- [ ] Compact consistent16pt sections and collapsed details, wide/narrow visual review.
- [ ] Independent focused gate and signed build.

No agent-operated device changes. User's general confirmation does not independently prove power-cycle persistence or every physical modifier/effect mapping.


29 October 2026. Owner approved adding explicit Mac/Windows mode switching with readback and separate restoration, icon-labelled effect choices, and five-stop brightness/speed sliders. Follow-up approval changes lighting to automatic application500 ms after the last user adjustment. System mode remains explicit Apply. Background fake checks and a signed build are authorized; the owner performs physical writes through the app.

## Transaction boundary

CurrentSystem is the paired scalar at 9416: Windows 0, Mac 1. Read/report Android 2, iOS 3 or unknown raw values without writing a guessed choice. User writes accept only typed Mac/Windows. Explicit restoration may write the exact previously captured raw pair. The system-mode original and restore flag are separate from lighting; each restore affects only its own region. Capture originals from fresh scoped reads, validate strict command 7 ack and exact command 8 readback before success. No write retries, automatic reconnect/profile application or keymap/macro/full-state access. Other flash addresses remain excluded. Physical modifier behavior and persistence are not established by static selectors/readback.

## Lighting interaction boundary

Labelled effect radio choices with icons/text and keyboard/accessibility support; brightness/speed sliders step1 within displayed1–5. Unknown readback stays visible; rendering/default slider state must not write a guessed value. All intentional lighting edits coalesce500 ms after the latest change. If busy, retain only the latest due edit; do not cancel an in-flight transport write. Rebase completed readback and overlay only fields edited after submission so a newly selected effect's untouched stored parameters are preserved. Failure does not retry automatically. Sleep/disconnect/suspension cancels unsent work and reconnect must not replay it. Explicit restore cancels pending lighting intent. System draft and Apply/Restore never participate in lighting debounce.

## Checklist

- [x] Typed Mac/Windows API and strict9416 write/ack/readback.
- [x] Independent session originals/restoration and lifecycle/battery propagation.
- [x] Accessible radio/icon choices and discrete sliders.
- [x] Latest-only500 ms automatic lighting application with no stale replay.
- [x] Focused independent fake tests and frozen-source build.
- [ ] Owner physical OS/lighting/restore/persistence acceptance.

## Evidence and ownership

Retained primary evidence: /Users/axatol/Workspace/ai/rea/investigations/lofree-flow-lite84/bindings-profiles.md:40 distinguishes the stored selector from editing views; macros-lighting-settings.md maps9416 and OS order; transport-swift.md supplies paired scalars, strict native validation and write/readback boundary. Existing FL-02 code is dirty on local master after base9d9b2c2; preserve it. flowlite_system_mode owns module/tests; flowlite_controls_ui owns keyboard model/view/model tests; root owns docs/integration/release. No foreground production app or agent HID writes.


## Verified delivery — 29 October 2026

Signed app/CLI build `b874794ee483170c425e0a777962baed19cc3a5a00f59a5ac8ced767b2854111`, strict signatures pass. Independent focused gate:92 module+25 model tests, zero failures; /Volumes/Data/tmp/hidhogg-fl03-debounce-independent-20261029.log. Functional-test15input hashes matched pre/post; after that gate a View-only responsive-layout follow-up changed FlowLite84DeviceView.swift, with all other14 inputs unchanged. Final15releaseinputs match pre/postbuild at /Volumes/Data/tmp/hidhogg-fl03-debounce-release-postbuild.sha256. FinalView SHA256ecf0bc01689a981b32d6f072ca0851af6b83918faf9c2a4d390a793ef5ebc692. FinalView compiled in signed build and was inspected offscreen at800/430px, including Retry/Restore error state; synthetic model/no-op actions and GroupBox style override, never-shown non-key window. This does not establish real interaction/native appearance or physical device behavior. No fullsuite rerun; earlier635check baseline historical.

Review caught a mode-failure queue issue: a due lighting edit could start after a rejected explicit mode write and clear its error. Both typed/generic device-write failures now cancel unsent lighting; a fake valid-NACK regression proves no lighting call, error remains, connection stays usable and draft stays dirty. New user adjustment/explicit retry can authorize later work. Rebase regression protects a newly selected effect's unedited stored speed when brightness changes during the first write.

Owner checks: restart dist/Hidhogg.app; adjust effects/sliders and pause500 ms, verify one settled change and actual lighting. Rapid edits while a write is active should settle to latest intent without replay after reconnect. Select Mac/Windows: selection alone must not write; use Apply system mode, test actual modifier behavior, then Restore previous system mode. Lighting Restore must leave system mode unchanged, and system Restore must leave lighting unchanged. Test physical persistence separately. No agent-operated device writes were performed.

## 31 October 2026 — lighting grid and startup issue

Signed build `4a69b2f6ecfff88a2820ce8d56f56553a3a38ea347f9d28a50ddda0410e1730d` adds a fixed four-column/two-row lighting grid: seven effects and Off eighth. Off changes enabled state only; selecting an effect enables lighting. Separate Backlight picker removed; unknown enabled state remains visible. Background release build and strict app/CLI signatures pass. Synthetic800px offscreen layout inspected; no production app/device operations. All220 non-view inputs match the previous128-test manifest; focused tests were not repeated for this view-only change. Build provenance refreshed.

Startup remains unresolved: owner reports a timeout after close/reopen, followed by successful manual Connect. No cause established and no automatic retry added. Bounded app diagnostic-log access requested; awaiting answer. Do not describe this as fixed. Existing Lofree controls have general owner acceptance, with physical persistence/edge cases separate. Changes remain uncommitted on master.

## Check-in acceptance — 31 October 2026

Owner reports the final lighting grid works and cannot reproduce the startup timeout; approves check-in now. Startup issue remains an observation, not a diagnosed/fixed bug. No retry changes or live agent device operations. Final build4a69b2f6 passes strict signatures; prior128 focused tests plus final view-only compile/offscreen review. Latest source manifest checked before commit. Documentation reconciled to200ms automatic lighting/system mode and4×2 grid. Registry/Bluetooth/hardware-focused roadmap recorded, implementation not started. No push authorized.
