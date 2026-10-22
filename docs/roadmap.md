# Roadmap

Reviewed 2026-10-22. TaskView Personal / HIDhogg project **5** owns task status, criteria and dependencies. This file is the current index; earlier verification reports retain the chronological evidence.

## Accepted checkpoint

Local commit **6ce6b23** on `next/logitech-slice` contains the accepted Logitech application checkpoint. Signed app: `dist/Hidhogg.app`, build **9e322504174b**. Final frozen suite: **316 passed**, zero failures. Source/resource hashes match that verified build; no push has been made.

The current functional baseline is usable and owner-accepted. This does not establish every failure, resource-soak or boot-login case. Older broad acceptance tasks remain open only for their documented residual scope; they do not block UI planning.

| Area | Stable IDs / TaskView | Current evidence |
|---|---|---|
| Native foundation and TOML/XDG configuration | NX-01 / 417; NX-02 / 418 | Complete |
| Back/Forward bindings, native editor, immediate application and autosave | NX-03 / 419; NX-04 / 420 | Owner reports working; broader acceptance/resource cases remain |
| Vertical direction and input resolution | NX-05 / 421; NX-06 / 422 | Implemented and tested; retain specific physical comparison limits |
| Thumb-wheel direction and amount | NX-08 / 424; NX-09 / 425 | Both owner-confirmed; apparent amount defect was excessive baseline multiplier |
| Vertical scroll amount | NX-11 / 427 | Owner-confirmed working |
| Reusable HID++ request IDs | NX-12 / 428 | Regression-tested; extended physical-use evidence remains limited |
| Traceable Recent Activity | NX-13 / 429 | Implemented; visual refinement can be checked during UI alignment |
| Single-instance Restart and native navigation | NX-14 / 430; NX-15 / 431 | Accepted / Done |
| Sleep/wake reconnection | NX-16 / 432 | Accepted / Done; current latency acceptable for now |
| Permission-aware menu status and window-dependent Dock/⌘Tab | NX-21 / 437; NX-22 / 438 | Accepted / Done |
| Launch at login | Part of existing startup work | Owner sees Enabled without error; actual login launch untested |

NX-17–20 / tasks433–436 are closed as **superseded historical icon work**. Rejected or missing-dot designs are not retrospectively accepted.

Current evidence: [window presentation](workspace-presentation-verification.md), [menu status and login follow-up](status-and-registration-followup.md), [thumb wheel and request IDs](thumbwheel-verification.md), [vertical amount](scroll-amount-verification.md). [Acceptance boundaries](logitech-acceptance.md).

## Next: NX-M2 — Native UI alignment

TaskView **list67**, milestone **439**. Use the selected device-workspace mockups as a visual reference, with native Swift components, accessibility and efficiency taking precedence over pixel matching.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| UI-01 | 440 | Complete: contract and 1B/2A/3A choices approved | Accepted NX22 |
| UI-02 | 441 | Implemented and tested; owner interaction/visual acceptance pending | UI-01 |
| UI-03 | 442 | Window-open sizing correction verified:324 regular checks +2 native cases; signed build97d79d553024 ready for owner acceptance | UI-02 |

Preserve per-app inheritance, outlined full-area control selection, connection dots beside status text, gold accents, immediate application/autosave and visible errors. Identify mockup-only Actions, notification history and MCP capabilities as separate functional work; do not imply those engines already exist or silently include them in visual alignment.

**Current action:** owner retries the corrected signed UI checkpoint using the [short checklist and verification record](ui-alignment-validation.md). Build17e2cfd76146 failed owner window-open acceptance; build97d79d553024 removes two explicit sizing constraints and passes real-window tests at default/minimum sizes twice. 1B/2A/3A remain implemented. Owner visual/physical acceptance is pending; no source commit or push. D200X remains gated.

## Then: NX-M3 — D200X functional vertical slice

TaskView **list66**, milestone **443**. **UI-03 owner acceptance blocks DX-01**; TaskView dependency edges record this order.

| Stable ID | TaskView | Deliverable | Dependency |
|---|---|---|---|
| DX-01 | 444 | Native bounded transport, correct HID collection and identity | UI-03; reviewed interface |
| DX-02 | 445 | One page and incremental display update | DX-01 |
| DX-03 | 446 | Mapped controls and representative configured native action | DX-02 |
| DX-04 | 447 | Independent GETBASE maintenance, reconnect and focused Swift acceptance | DX-01–03 |
| DX-05 | 448 | Later brightness, fonts, wide status/telemetry and optional screensaver | DX-04; separate feature plans |
| DX-06 | 449 | Resolve knob/encoder evidence gaps before implementation | DX-04; further evidence |

Deliver D200X alongside Logitech in the **same app**, with device-specific transport and controls. Research vendor/Python acceptance is not Swift proof. Preserve the latest 2026-10-21 research lifecycle results without repeating accepted vendor tests. No D200X code or hardware work has started. [Research basis, scope and gates](d200x-roadmap.md).

## Deferred and follow-up work

- **SmartShift:** NX-07 / 423 remains deferred.
- **Scroll continuation:** NX-10 / 426 is deferred; the inertia characterization was retracted, so it is not a confirmed outstanding defect.
- **Wake discovery speed:** leave unchanged unless the accepted delay becomes a problem.
- **Resource and recovery evidence:** overnight CPU/memory, abrupt device removal/crash cleanup, other-mouse isolation and exceptional native failure cases remain unverified. Do not repeat a large test campaign without agreeing scope.
- **Login at boot:** Enabled status is confirmed; actual launch after login is a distinct follow-up.
- **Later product capabilities:** shared action management, notification receipt/delivery history, device-level notification routing and MCP need separately scoped functional slices. Additional device types remain future work.
- **Excluded D200X scope:** firmware installation, vendor plugin compatibility and cloud services.

Historical lists48/49 and prior v1/v2 acceptance records remain preserved; this checkpoint does not close them. Design decisions: [contract](logitech-slice-contract.md). Research and visual history remain under `docs/product-redesign/` and the linked verification reports.

UI-02 native mouse checkpoint (2026-10-22): approved vector/linked controls integrated; signed dist buildf71eb46cbf95. Native2/2 window tests and324 regular checks passed; synthetic narrow/wide renders inspected. Automated AX button presses were not established because the isolated host tree was empty; owner clicks/keyboard/physical acceptance remain pending. No transport changes; external-state enable failure remains separate. UI-02/03 and D200X gate stay open.

Connection diagnostic checkpoint (2026-10-22): owner accepted native mouse UI and approved diagnostic-first investigation of external-state enable failure. CONN-01 in progress: typed enable-stage context, privacy-safe stage display/logging, fake-transport regression; all device-state/cleanup guards unchanged. Exact hardware cause remains unknown; signed build will require a controlled reconnect by owner. Owner approved deferring single-page Settings until connection issues are fixed: one scrollable page with General, Permissions, Configuration and Diagnostics; Open Permissions should scroll to its section. No Settings implementation in the diagnostic checkpoint.

CONN-01 diagnostic build357bb2389311 ready2026-10-22;9typed enable stages, no device behavior change. Independent328 ordinary checks passed on retry; first existing thumbwheel snapshot assertion failure preserved/unresolved. Owner reconnect needed to identify exact stage. Signedfixedpath dist/Hidhogg.app; docs/diagnostics.md contains reproduction and evidence. Single-page Settings remains deferred.

CONN-01 recovery approved2026-10-22: Connect preflights all relevant states, clears recognised existing button/wheel diversion preserving other mode bits, verifiesreadback, then normalreconciliation applies savedsettings. Unknownflags/remaps remainblocked. Boundedreclaimjournal/cleanup andcancel safety required; no inputadmissionduringrecovery. Executor owns transport/reclaimtests, independenttesterwaitsfreeze. No live recovery run yet. Single-pageSettings remainsdeferred.

CONN-01 reclaim implementationready2026-10-22: signed dist buildce930217a62c, strictsignaturepassed,107-input provenance. Actualbehaviorred→green plus independent340ordinary tests passed (193XCTest/2native skipped+149SwiftTesting). Recognised4-controldiversion reclaimedbeforeReady; unknownstate/malformedinfo blocksbeforewrites, cancellation/partialcleanupcovered. Ownerhardwareacceptancepending; noactualrecoverydevicewrites. Normalreconciliationthumbbyte1bits1/2loss remainsseparatedeferredfinding. Nextownerreconnect/buttons/wheels, thenSettingssinglepage.

CONN-01 accepted2026-10-22: owner reports everything working after reclaim buildce930217a62c. Connection correction complete;340ordinary automated checks previously passed. Next approved scope: one scrollable native Settings page preserving permission jump.

UI-04 InProgress2026-10-22, TaskView451: ownerapproved one-pageSettings afterCONN-01acceptance. OnegroupedForm, nochildFormwrappers; General→Permissions→Configuration→Diagnostics, repeatOpenPermissions scrollrequest. Bounded5viewexecutor; mainmodeltoken/test; independentregression/nativefakewindows. No runtime/HID/schema changes.

UI-04readyownercheck2026-10-22: signedbuild33da0970c776, oneForm/repeatpermissionjump, duplicateRestartremoved.341ordinarychecks+2nativewindowtests passed; realscrolljump/keyboardmanualcheckpending. Task451 staysInProgress untilowneracceptance.

UI-02 artwork follow-up in progress, 2026-10-22: owner approved `15-smooth-band.svg` after generated-reference tracing and manual curve cleanup. Replace the top-down/inset canvas with the approved angled artwork drawn as cached native paths; four native region buttons and labels remain. No image decoder, SVG runtime parser, dependency or device behavior change. Narrow/wide synthetic renders and existing native window gates precede delivery. Other sidebar/accent/save-status refinements remain separate.

UI-02 angled artwork ready for owner check, 2026-10-22: SVG20/20 path geometry/colours/strokes independently matched; native cached paths, displayed-size Canvas and shape-based buttons implemented. Compact full-width labels and visible straight leaders corrected after render review.341 ordinary checks passed before final layout-only correction; final focused9/9 and native2/2 passed, then background/non-key native2/2 passed after harness correction. Signed fixed bundle build5a564e91901e; strict signature verified. Owner physical-region/label clicks, keyboard and resize acceptance remain pending. No commit/push/device behavior changes. [Verification and previews](ui-alignment-validation.md).

Owner accepted the angled mouse UI on2026-10-22. INFO-01/02 now in progress: read-only battery/mouse-firmware with menu/sidebar battery and device-page refresh, plus optional below10% native alert. No continuous polling or serial/receiver-firmware scope. [Plan, decisions and gates](device-information-plan.md).

INFO-01/02 ready for owner check, 2026-10-22 (TaskView452/453): signed fixed bundle build050d02547bd0,114-input provenance and strict signature verified. Device page shows battery/firmware/manual refresh and saved optional alert; menu/sidebar share battery presentation. Offline metadata tests18/18; full retry379 ordinary passes after one previously recorded wheel-snapshot timing issue; background native2/2. No production live readback or notification prompt/delivery yet. Keep tasks InProgress until owner confirms values, refresh/connection continuity and opt-in permission. Receiver firmware remains deferred. [Verification and owner checklist](device-information-plan.md#verification-checkpoint--2026-10-22).

Presentation refinement ready, 2026-10-22: signed build42d2e843700e names the menu battery device, aligns sidebar name/status with one connection+battery line and centred icon, moves battery/alerts into overview and firmware/refresh to page bottom. Background native2/2 passed; static audits found no material defect. Only presentation views changed; owner visual acceptance pending. [Updated verification](device-information-plan.md#presentation-follow-up--2026-10-22).

Permission/firmware follow-up ready, 2026-10-22: signed build76acd0ab10d4 places the device alert checkbox beside battery and app-global authorization in Settings. Main firmware and secondary components are named, validated packed BCD shows numeric versions; hardware revision retained from existing payload without new requests. Focused24XCTest+18selectedSwiftTesting and background native2/2 passed, with fake notification adapter prohibiting prompt/post. Strict signature and116-input provenance verified. Owner visual/Options+ value comparison and real alert-delivery gate remain. [Evidence and decisions](device-information-plan.md#permission-scope-and-firmware-presentation-follow-up--2026-10-22).

### 2026-10-23 — Sidebar alignment and contrast follow-up

In progress: approved shared native icon-column alignment and darker sidebar selection gold; retain brighter control/text accent. Existing background native workspace gate and signed fixed bundle pending. Owner visual acceptance remains required. Firmware type-5 investigation is separate and unchanged in this visual scope.

Sidebar follow-up implemented and signed bundle updated; background native2/2 passed. Owner visual acceptance pending.

### 2026-10-23 — Sidebar vertical alignment correction

In progress, owner approved: centre mouse glyph against both text lines, preserve shared horizontal icon column, add modest Settings vertical padding. Background native verification and signed bundle refresh planned.

Sidebar centering/padding implemented, signed bundle updated, background native2/2 passed. Owner visual check pending.

### 2026-10-23 — Accepted sidebar checkpoint

Owner confirmed final sidebar centering/padding looks good and authorized check-in of native UI, artwork, device information, notification support and tests. Type-5 identification and real notification delivery remain open follow-ups.
