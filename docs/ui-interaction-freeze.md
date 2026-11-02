# UI-FREEZE-01 — UI interaction CPU/freezing

2 November 2026. Owner reports CPU above100% and freezing on any window interaction. Diagnosis/fix takes priority over the proposed interactive mouse canvas. Owner approved bounded Hidhogg-only numeric CPU/RSS counters, five-second thread samples and offline reproduction/fix; no process arguments, environment, raw memory, private config/logs or HID reports.

## Checklist

- [x] Identify Hidhogg and match loaded image UUID to signed df12cc3.
- [x] Capture the actual interaction spike:99.7%CPU.
- [x] Minimize to a fake hosted settings view with only force pressure supported.
- [x] Rank/test hypotheses with a failing liveness command before the source fix.
- [x] Fix confirmed cause and pass same-case/full-domain regressions.
- [x] Independent review, full offline gate, strict signed delivery.
- [x] Owner reports the freezing seems resolved on the delivered fix.
- [ ] Commit accepted dependency-closed scope automatically.
- [ ] Return to shared interactive3S/MX4 canvas proposal after layout-plan confirmation.

## Evidence and cause

Initial idle sample/counters did not capture the symptom; coordinated owner interaction did. The matched running image showed99.7%CPU, with busy main-thread stacks dominated by SwiftUI size/alignment computation and SliderMarkLabels. Physical footprint measurements alone do not establish a memory leak.

Ranked hypotheses: (1) unbounded automatic slider ticks; (2) settings-card hierarchy measurement; (3) model/session publication storm. The reduced view keeps the hierarchy/model unchanged and varies only the advertised force range. It reproduces the stall with fake operation counts unchanged; rendering needs no hardware/update storm. Removing only the force Slider step argument resolves the same case, supporting hypothesis1. [Apple documents automatic ticks for stepped sliders](https://developer.apple.com/videos/play/wwdc2025/323/).

The native control now draws continuously; its unchanged binding rounds to UInt16 within the exact advertised range. Device ranges, pressure values, backend ownership and settings are unchanged.

| Range | Before initial layout | After initial layout |
| --- | ---: | ---: |
|0...100|0.098s|0.070s|
|0...4095|4.726s (fails3s bound)|0.021s|
|0...65535|not run before fix|0.023s|

The earlier0...16383 attempt was stopped by its owned90s watchdog; smaller sweeps established a bounded failing4095case. All owned test groups were verified gone. Exact unchanged-case GREEN passed before fullUInt16 coverage was added. Resize passes dropped from about2.4s to about0.002s. Hidden/non-key and unchanged fake-operation assertions pass. The regression covers layout/resize, not drag, keyboard or VoiceOver.

## Verification and delivery

Source delta since prior df12cc3 checkpoint: one production line (remove force Slider step), one layout regression test, and one setup-test readiness correction. The full gate initially found that the setup test observed target discovery before its AsyncStream ready status reached the model. It now waits for selectedID, verified owner and ready phase; false-management and zero-write assertions remain independent.

Final gate:642XCTest+456SwiftTesting =1,098 passed; exactly WakeConnectionTests/NativeWorkspaceWindowTests excluded. Model suite11/11 and setup suite22/22 pass;333 frozen inputs match before/after tests/signing; source review clear and whitespace check passes. No failures hidden; first failed full log/manifest preserved.

Signed app/CLI build 4013fd4d3be6127aace690c63cc5b511a27a6550e4aa03c360ce2f5a4a03a8eb is at dist/Hidhogg.app and dist/hidhoggctl. Strict signatures and CLI help pass. Agent did not launch the new app or issue device/input/config writes. Owner-visible verification remains pending; a memory leak is not established.

Evidence: /Volumes/Data/tmp/hidhogg-ui-freeze-{inputs.json,red-final.log,green-same-case.log,green-perf.log,green.log,targeted-setup.log,full.log,full-iteration2.log,release.log,cli-help.log}. Approved private thread samples are outside the repository with owner-only permissions; report only whitelisted numeric fields/redacted symbols, not raw paths.

## Next action

Quit the existing Hidhogg process, open the rebuilt dist/Hidhogg.app and repeat ordinary clicks/scrolling/resizing. Commit accepted scope automatically after owner confirmation. Pointer speed remains deferred; DPI V2 remains read-only pending its contract. The interactive model/artwork proposal remains queued and was not mixed into this fix.

## Owner feedback — 2 November 2026

Owner reports: does seem to be resolved, i still cant set dpi though. Record the CPU/window-interaction fix as accepted. No post-fix CPU/heap profile was collected; other device controls and physical edge cases were not individually accepted by this statement. DPI remains a separate implementation gap. The local check-in is dependency-closed because the pressure control belongs to the new settings implementation; the checkpoint retains explicit incomplete hardware/DPI/pointer acceptance gates.
