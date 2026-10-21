# Milestone index

Current artifact: [window-dependent app-switcher verification](workspace-presentation-verification.md). Prior [permission-aware menu status and investigations](status-and-registration-followup.md). Prior [head-only eye status verification](head-eye-status-verification.md). Prior [dual menu icon/status verification](dual-menu-icon-verification.md). Prior [larger menu/status verification](menu-bar-status-verification.md). Prior [wake/icon verification](wake-icon-verification.md). Prior NX13/14/15 evidence: [workspace verification](workspace-verification.md). Prior NX08/09/12: [thumb-wheel/request-ID verification](thumbwheel-verification.md). Prior NX11: [scroll amount verification](scroll-amount-verification.md). Prior NX-06 evidence: [resolution verification](resolution-verification.md).

Updated 2026-10-21. TaskView Personal / HIDhogg project 5 owns task status, criteria and dependencies: list65 Logitech, list67 native UI alignment, list66 D200X. Historical list 49 and its pending v2 acceptance records are not closed by this reset. No new project created.

## NX-M1 — MX Master 3S Back and Forward bindings

User deliverable: discover already-paired mouse over Bolt, configure Back and Forward shortcut bindings using native UI, save defaults/one application override, execute once per press, recover saved configuration after reopen and stop cleanly.

| Stable ID | TaskView | Deliverable | Status |
|---|---|---|---|
| NX-01 | 417 | Recoverable reset, native app/build foundation at dist/Hidhogg.app | Complete — compile/package/audit gates; no GUI/hardware claim |
| NX-02 | 418 | Device-neutral Back/Forward configuration and persistence | Complete — isolated codec/store/path gates |
| NX-03 | 419 | Bolt session, control discovery and action integration | Implemented and fixture-tested — physical acceptance pending |
| NX-04 | 420 | Native editor, owner acceptance and resource gate | Implemented and packaged — owner/resource acceptance pending |
| NX-05 | 421 | Device-side scroll direction | Implemented — physical acceptance pending |
| NX-06 | 422 | Native scroll-input resolution | Implemented and packaged — owner comparison pending |
| NX-07 | 423 | SmartShift modes and automatic-switch threshold | Deferred by owner |
| NX-08 | 424 | Horizontal thumb-wheel direction | Direction owner-confirmed; broader lifecycle gates open |
| NX-09 | 425 | Horizontal thumb-wheel scroll step | Amount owner-confirmed; baseline multiplier was excessive |
| NX-10 | 426 | Scroll continuation investigation | Deferred — inertia characterization retracted |
| NX-11 | 427 | Adjustable vertical scroll amount | Owner reports working — broader lifecycle gates remain open |
| NX-12 | 428 | Reusable request IDs without ordinary-use disconnect | Red→green and packaged — owner check pending |
| NX-13 | 429 | Left-aligned traceable Recent Activity | Implemented/packaged — owner visual check pending |
| NX-14 | 430 | Single runtime owner and bounded Restart handoff | Owner confirms single-instance Restart works |
| NX-15 | 431 | Page Back/Forward presets and new-file defaults | Complete — owner confirms presets and native navigation work (2026-10-21) |

| NX-16 | 432 | Restore pre-sleep session after wake with bounded retries and diagnostics | Owner accepts current behavior; latency work deferred |
| NX-17 | 433 | Selected A1 menu-bar template icon | Implemented/packaged — owner appearance check pending |

| NX-18 | 434 | Larger menu-bar A1 plus aggregate connection dot | Superseded — owner found dot missing; NX19 correction |

| NX-19 | 435 | Smaller head/swirl trial and single-image status rendering | Packaged; owner confirms harness dot visibility; final app check pending |

| NX-20 | 436 | Final head-only circular eye status with transparent clearance | Built and tested — final appearance awaits owner acceptance |

NX-01 blocks NX-02, which blocks NX-03; NX-02 and NX-03 block NX-04. Detailed roles, boundaries and gates are in TaskView. The foundation does not establish a completed vertical slice. Existing LogiBridge research tasks remain separate and are not closed or duplicated by these production tasks.

## Checklist

- [x] Owner approved Bolt-only scope and Back plus Forward.
- [x] Owner approved new branch and old production-source retirement.
- [x] Recoverable v2 checkpoint `4b3248d` and `next/logitech-slice` branch.
- [x] Old compiled dist app removed with owner approval.
- [x] Native app and fixed-path signed packaging independently verified.
- [x] Preservation/reset audit complete: 147 preserved files match checkpoint.
- [x] TOML configuration, native editor/history and Bolt/action integration implemented.
- [x] Signed arm64 Release app packaged at the fixed path.
- [ ] NX-M1 physical user deliverable accepted.

Current implementation decisions: [contract](logitech-slice-contract.md). Verification evidence: [report](logitech-verification.md). Remaining owner checks: [short checklist](logitech-acceptance.md).

Owner feedback corrections implemented and independently verified (2026-10-19): retain idle connection on document operations, explicit Disconnect, consistent native accent, reserved-shortcut chooser, visible permission blocker, permission-settings/app drag affordances and bounded diagnostics. Corrected package suite62/62 passes; updated signed app at the fixed dist path. GUI/hardware acceptance remains open; corrections are uncommitted pending owner check.

Implemented and independently tested: owner-approved clean Restart, bundled icon in drag item, separate Accessibility/event-post diagnostic results, activation refresh, process/build identity and full-tile Back/Forward click area. Latest package suite75/75 passes. Direct signed permission-only probe reported both checks granted; normal Launch Services probe failed -10810, so owner GUI permission disagreement remains unconfirmed. Restart/drag/hit-target acceptance remains open.

## Next device-setting slice

NX-05#421 — device-side vertical scroll reversal implemented, physical acceptance pending. Existing LogiBridge v6 evidence records inversion and verified restoration; no duplicate spike required. Native control, saved optional preference, explicit ready-only Apply, preserved unrelated mode bits, capability/readback gates and owned baseline restoration on disconnect/quit. No keyboard-permission dependency or global scrolling preference change. Reconnect/button-enable handle replacement settles wheel ownership before closing the transport; no automatic reapply. Final independent package gate111/111 passed; signed app rebuilt and verified. [Evidence and owner checklist](wheel-verification.md). Physical direction/isolation/lifecycle acceptance remains open; changes uncommitted pending owner check.


## 2026-10-19 — Immediate preferences and lifecycle correction in progress

Owner approved replacing manual Save, Enable Bindings and wheel Apply with immediate connected application and a one-second trailing autosave debounce. Explicit Connect/Disconnect and Reload remain. Disconnected edits persist and apply on the next explicit connection; Reload must reconcile without closing the handle. Missing permissions and disk/device errors remain visible. Previous explicit-Apply and active-Save-stop policies are superseded for this correction.

- [x] Capture restart duplication report and existing process stack evidence.
- [x] Approve revised behavior and implementation boundary.
- [x] Reconcile buttons and wheel on one connected handle.
- [x] Implement serialized immediate preferences and debounced persistence.
- [x] Correct asynchronous AppKit termination and test coordinator ordering; native process-exit check remains open.
- [x] Independent129-test gate and signed fixed-path package.
- [ ] Owner quick checks, including native Restart/Quit and physical behavior.

The parent process sample showed NSApplication.terminate nested inside RestartCoordinator’s main-actor async task; the replacement was in its normal event loop. Existing tests did not exercise native AppKit termination. No running owner instance has been stopped. Bindings working is owner-confirmed; lifecycle behavior remains unaccepted.


## 2026-10-19 — Immediate correction ready for owner check

Supervised runtime/model/termination work integrated; independent suite129/129 passed, zero failures. Signed fixed-path Release build`49360ba4cc8f`, executable SHA256`2bf83b437ba796a67f41e8550005c84a23fb1adfb4db4b7bf5738247cc920e0d`, verified signature/certificate/arm64/macOS26/resources and frozen source hashes. Native termination probe failed before callback, so process exit remains an owner gate. Known finite request-budget and capability-cache tradeoffs are in decisions38–42. No owner process stopped or physical operation executed. Five-item owner checklist updated; source remains uncommitted pending acceptance. NX-03/04/05 remain InProgress for their owner gates.


## 2026-10-19 — Menu-bar-only interface ready for owner check

Owner approved a simplified monochrome serpent-head template icon and no Dock icon. Native menu: connection status, Open Hidhogg, Connect/Disconnect, Quit. The same app/model/device owner persists after closing its single workspace window. No new runtime process, automatic connection, launch-at-login or idle polling.

- [x] Owner approved icon treatment and menu-bar-only behavior.
- [x] Add native menu and singleton workspace with delegate cleanup available before any window opens.
- [x] Render/inspect template icon at menu-bar sizes and verify no-Dock bundle metadata.
- [x] Independent132-test regression gate and signed fixed-path package.
- [ ] Owner native menu, focus, close/reopen, background bindings and Quit checks.

Historical signed build`23f36efd6f39` was current at that checkpoint at dist/Hidhogg.app; signature/certificate/LSUIElement/arm64/macOS26/resources and frozen source fingerprints verified. Independent74 XCTest+58 SwiftTesting tests passed; explicit delegate defaultinit fixed after negative genericconstruction control reproduced a trap. Native icon18pt/light-dark preview inspected. No owner configuration/HID access or normal app launch. docs/menu-bar-verification.md records evidence and checks; earlier corrections remain uncommitted pending owner acceptance.

## 2026-10-20 — Launch connection and login item ready for owner check

Owner approved Connect on launch (default on), one attempt after valid initial configuration load including Restart, and optional native Launch at login with actual OS status/errors and Login Items Settings link. Existing Bolt uniqueness/capability/permission gates remain; no repeated background discovery loop. The same menu-bar-only app is registered; no helper process or LaunchAgent plist.

- [x] Approve behavior and implementation boundary.
- [x] Persist root connect_on_launch in XDG TOML, default true when absent.
- [x] Attempt connection once after initial load, with lifecycle cancellation; preference changes affect the next launch.
- [x] Add native login-item adapter/status/settings controls with injected-only verification.
- [x] Independent checks, signed fixed-path package, updated owner checklist.
- [ ] Owner startup, Restart and native login registration checks.

Current signed build `c61c9133f5e5` replaces the prior menu checkpoint. Independent159-test gate passed (101 XCTest +58 Swift Testing). [Current evidence and owner checks](startup-verification.md). Earlier no-automatic-connection/login-item and Restart-disconnected policies are superseded. Broader physical/resource acceptance remains open.

## 2026-10-20 — Persistent ownership and login recovery ready for owner check

Owner approved persistent device wheel settings by default, optional restoration, continued release of button interception on exit, and explicit login registration from the not-found state.

- [x] Confirm correction boundary and assign supervised workers.
- [x] Persist per-device restoration policy, default off; reconcile live policy and direction changes.
- [x] Retain verified wheel settings on ordinary disconnect while preserving failure safeguards and button cleanup.
- [x] Allow explicit login registration from not-found with regression/error reporting.
- [x] Independent combined verification and signed fixed-path package.
- [ ] Owner direction retention, restoration opt-in and native login registration checks.

Current signed build `d45cde0bd9ea` at the fixed dist path supersedes `c61c9133f5e5`. Independent177/177 passed; signature/certificate/target/resources/frozen hashes verified. [Current evidence and three owner checks](ownership-verification.md). Native notFound cause/registration, device behavior and broader acceptance remain open; source is uncommitted.

## NX-06 — Scroll-input resolution ready for owner check — 2026-10-20

TaskView422 owns the owner-approved resolution-only slice; TaskView423 / NX-07 records SmartShift wheel modes and automatic-switch threshold as explicitly deferred.

- [x] Narrow approved scope and resolve/create task records.
- [x] Optional per-device wheel_high_resolution with strict TOML/default/round-trip checks.
- [x] One serialized mode transaction for direction/resolution/restoration; preserve partial-unmanagement behavior and rollback safeguards.
- [x] Native input-resolution picker and observed readback, immediate connected reconciliation and autosave.
- [x] Independent synthetic regression gate, source/preservation audit and signed fixed-path package.
- [ ] Owner low/high reporting comparison in target apps; no animation-free claim before observation.

Deferred NX-07#423: advertised SmartShift automatic/ratchet/free-spin and automatic-switch threshold, exact packet/transition semantics and owner checks. This does not authorize SmartShift implementation or hardware experiments now.

NX-06 signed build `0d561b8fb66a` supersedes the ownership package at the fixed path. Independent188/188 passed; signature/certificate/target/resources and50 frozen hashes verified. No native device/UI/owner process operation. Task422 remains In Progress for owner comparison, Task423 remains TODO/deferred.

## 2026-10-20 — Horizontal wheel backlog

Owner requested NX-08#424 (independent horizontal direction reversal) and NX-09#425 (horizontal scroll step/movement amount). Both are deferred TODO tasks in TaskView. NX-09 must define step units and distinguish movement distance from report resolution before implementation; protocol support and physical effects remain unverified. Coordinate both settings to preserve each other, vertical wheel behavior and existing ownership/restoration policy. No implementation or hardware action performed.

## 2026-10-20 — Original stepped-scrolling goal remains unmet

Owner reports resolution changes enlarge scroll movement but inertia remains. Record this as user evidence, not a diagnosis or complete acceptance of NX-06. NX-10#426 tracks a bounded reproduction in the target app, including whether movement continues after the physical wheel stops, before selecting a mouse-scoped implementation. No code/device action authorized by this observation. SmartShift and horizontal-wheel tasks remain deferred.

## 2026-10-20 — Vertical scroll amount clarified

Owner estimates Low resolution scrolls about3 lines and High about60; approximately3 lines is near the desired amount, but it should be adjustable independently. NX-11#427 records vertical scroll amount/speed, distinct from resolutionNX-06 and residual inertiaNX-10. Target app, normalized wheel increment, units and acceleration semantics remain to be established before implementation. Device-side versus mouse-scoped host processing is unverified. No production/package/device changes.

## 2026-10-20 — Options+ scroll-processing evidence

Read [/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/scroll-behavior.md](/Users/axatol/Workspace/ai/rea/investigations/logi-options-plus/scroll-behavior.md). Its static report traces a host-side scroll pipeline and independent speed coordinate; it does not establish a firmware lines-per-step setting or diagnose current inertia. NX-11#427 and NX-10#426 notes updated to coordinate a shared mouse-scoped host-processing investigation. Prefer assessing a simple fixed-amount/no-added-tail policy before Options+ acceleration parity; routing/suppression and physical/target-app measurements remain unverified. No implementation or permission/device action performed.

## NX-11 — Functional host scroll amount in progress — 2026-10-20

Owner corrected the inertia description to likely multiplier and authorized implementation where evidence suffices. Implement the previously proposed fixed-amount policy, not exact Options+ acceleration/filter parity.

- [x] Reconcile owner correction and mark NX-10 deferred/unconfirmed.
- [x] Review static report, primary protocol sources and independent architecture boundaries.
- [x] Optional multiplier intent, validation and native posting sender with injected tests.
- [x] Mouse-scoped wheel routing with independent admission, neutral inversion and mandatory routing cleanup.
- [x] Native opt-in amount control, permission gate, autosave and failure reporting.
- [x] Independent synthetic gate, preservation audit and signed fixed-path package.
- [ ] Owner suppression/sign/normalization/amount and lifecycle behavior check.

No global event tap, added tail/acceleration, SmartShift or horizontal control scope. Static report format and suppression semantics still need physical validation; no agent device/input operation authorized.

NX-11 signed build `88191e0457c7` supersedes the resolution package at the fixed dist path. Independent final220/220 passed (117 XCTest +103 Swift Testing); adversarial fixes, request-budget boundaries and permission-revocation regression verified. Signature/certificate/arm64/macOS26/resources and53 frozen hashes verified. [Evidence and three owner checks](scroll-amount-verification.md). Task427 remains In Progress pending physical suppression/sign/amount/lifecycle validation; no native action or commit.

## NX-08/09 — Thumb-wheel direction and fixed amount — 2026-10-20

Owner approved the proposed combined functional slice after reviewing the new static2150 report. Exact Options+ gesture/acceleration/filter parity remains out of scope. Vertical amount works in the owner’s current setup; broader lifecycle gates remain separate.

- [x] Approve combined boundary and begin supervised design/config work.
- [x] Confirm reporting/status/capability wire contract and lifecycle design.
- [x] Independent thumb-wheel direction/amount intent, native controls, autosave.
- [x] Serialized2150 ownership, capture, guarded delivery and mandatory cleanup.
- [x] Independent synthetic verification, preservation audit and fixed-path signed package.
- [ ] Owner physical direction/amount/suppression/coexistence checks.

Owner feedback during NX08/09: label inverted direction Natural to match macOS. Existing tokenExhausted failure screenshot confirms editing/activation capacity policy is user-visible; exact triggering sequence not instrumented. Additional transport request-ID reuse correction is proposed separately and awaits confirmation; thumb-wheel implementation continues.

Owner approved request-ID transport correction on2026-10-20: replace lifetime15-request allowance with serialized reuse after matched completion, retire ambiguous IDs and retain cleanup capacity. Architecture/implementation to follow; no silent handle renewal. Natural terminology correction included. Final thumb package gate waits for combined correction.

Thumb app/sender source frozen:7 injected sender tests+3 model tests passed; runtime15 declarations/25cases passed before approved tokenpolicy correction. Independent architectural reinspection found prior cancellation-policy and start/end timestamp fixes correct. Additional tokenpolicy implementation is active; final combined suite/package remains pending.

NX-12#428 tracks the approved transport correction in the existing Personal/HIDhogg project/list. Red regression proved premature close; shared-ledger green and focused109 Bolt tests passed before final fixture-fidelity correction. Final independent combined gate/package and owner continued-use check remain.

Combined NX08/09/12 ready for owner check: signed build `f4523d8eb766` at fixed dist path, independent256/256 (124 XCTest+132 Swift Testing), final architectural/preservation audits clean; signature/certificate/target/resources and59 frozen hashes verified. [Evidence and three owner checks](thumbwheel-verification.md). No native action or commit; Task424/425/428 remain In Progress pending owner acceptance.

## NX13/14/15 — Diagnostics, ownership and navigation — 2026-10-20

Owner approved left-aligned traceable activity and atomic startup ownership with cleanup-first Restart, then explicitly included Page Back/Forward presets/new defaults. Existing configurations remain unchanged; brief restart process overlap allowed, no two cooperative runtime owners. Current dist remains f4523d8eb766 until final gate/package.

- [x] Read current diagnostics/bootstrap/restart/binding code and verify macOS browser convention.
- [x] Obtain approvals, create stable TaskView429/430/431 and assign bounded supervised workers.
- [x] Review startup lock/security/handoff design and preserve module ownership.
- [x] Implement structured codes/IDs, safe Console correlation and leading Recent Activity.
- [x] Acquire per-user lease before AppModel; duplicate activation/exit, bounded restart/recovery.
- [x] Named presets and missing-file defaults preserving existing bindings/overrides.
- [x] Independent tests/review/preservation audit and signed fixed-path app.
- [ ] Owner Recent Activity layout/Console, duplicate/restart and browser checks.

NX13/14/15 source frozen68files; independent combined suite started. Startup architectural review fixed private-parent replacement exposure and release-error recovery without ownership, with targeted fixtures; final review no findings. Named-preset domain/store isolated builds passed; app tests unrun until combined gate. Earlier test attempts stopped before execution on transient entry/diagnostic syntax integration and sandbox access; no pass inferred. Artifact remains previousbuild until gate/package.

NX13/14/15 ready for owner check: build `33a3a579798d`, independent291/291 (157 XCTest+134 SwiftTesting), signature/certificate/target/resources and68hashes verified; preservation and bounded reviews pass after recorded fixes. [Current evidence/three checks](workspace-verification.md). No native app/device/live-owner operation or commit; Task429/430/431 remain In Progress pending owner gates.

## NX21 — Status correction and bounded diagnosis — 2026-10-21

- [x] Owner approved larger beside-head status and yellow incomplete-permission warning.
- [x] Implement one composite image, explicit permission state, accessible warning, exhaustive phase/permission tests.
- [x] Independent311-test gate and signed fixed-path app.
- [ ] Owner larger-dot appearance and permission-warning check.
- [x] Read-only amount investigation; no verified defect, physical comparison remains open.
- [x] Read-only login metadata/API investigation; no cause established. Scoped live reproduction approval pending.

Task437 owns menu correction, build7d0895c00fff awaits owner appearance acceptance. Owner-confirmed direction and single-instance Restart recorded; current sleep/wake retained. Prior NX17–20 icon layouts are historical/superseded by NX21.

## Owner acceptance and approved polish — 2026-10-21

Owner confirms thumb-wheel amount works; previous multiplier was already too large. No amount defect established or fix needed. Beside-head menu styling accepted. Login item now reports Enabled without error; actual launch after login remains untested, prior error cause unknown. Stop planned live registration diagnosis unless it recurs. Owner approves6→7.8pt statusdot,9ptslot retaining3ptgap, and suppressing only Enabled explanatory paragraph. Worker owns MenuBarIcon.swift/SettingsView.swift; parent builds/audits. No runtime/amount/loginregistration behavior changes.

## NX22 — Window-dependent app-switcher presence

Task438 built/tested, native owner check pending: regular activation while workspace is open, accessory afterclose; retain minimized/background windows and menu-only launch. Injected lifecycle and independent tests, then fixed signed app and owner native check.

## Ordered next milestones — 2026-10-21

```text
Current Logitech / NX22 checkpoint
              |
              v
NX-M2: Native UI alignment — Task439 / list67
              | owner acceptance
              v
NX-M3: D200X functional slice — Task443 / list66
```

| Milestone | Tasks | Deliverable | Status |
|---|---|---|---|
| NX-M2 / 439 | UI-01#440, UI-02#441, UI-03#442 | Align existing functions with selected mockups using native components | Planned; before D200X |
| NX-M3 / 443 | DX-01#444 through DX-04#447 | Connect/identity/page/controls/independent maintenance/reconnect alongside Logitech | Planned; blocked on NX-M2 acceptance |
| Later D200X | DX-05#448, DX-06#449 | Appearance/status features; resolve knob/encoder evidence gaps | Backlog |

[Task boundaries, research basis and acceptance gates](d200x-roadmap.md). D200X roadmap-only request does not authorize new production source or hardware operations. Latest research lifecycle results are preserved; native Swift behavior remains a separate gate. UI alignment does not silently include notification/MCP engines.

NX22 build9e322504174b packaged:316 tests pass; native Dock/CmdTab/close/reopen check remains open. TaskView now contains dependency edges for NX22→UI01→UI02→UI03→DX01→DX02→DX03→DX04, plus UI milestone→D200X milestone. No UI alignment or D200X implementation started.
