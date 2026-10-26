# Roadmap checkpoint history

Archived on26October2026 before check-in consolidation. Dated entries are historical; use [the current roadmap](roadmap.md) and TaskView for present status. Relative evidence links remain in the same docs directory.

**26 October 2026 — owner accepted the improved458×196wide-tile rendering.** Retain this output; unrelatedphysical/lifecyclechecks remain separate.

## Higher-resolution wide tile trial — 26 October 2026

Signed build `3a7adfa11f7b` renders physical wide output at458×196 using the acceptedlogical layout andwidthcalibration; previewunchanged.18focused checks passed; hardwaremapping andanti-aliasing remain ownertrial. Based on UlanziSDK encoderdisplaycanvas, not a confirmedwide-key1:1mapping. [Evidence](d200x-workspace-evolution-plan.md).

## Wide title calibration trial — 26 October 2026

Signed build `03ca0bb45c48` narrows physical wide-tile text20% while preserving height/alignment and the app preview.16focused tests passed. Owner physical calibration remains; sleep trial and priorLogitech recovery preserved. [Evidence](d200x-workspace-evolution-plan.md).

## Retained D200X sleep trial — 26 October 2026

Signed build `b316e9c09582`: pause GETBASE and transient brightness0 on sleep, retain HID handle; wake resumes maintenance and restores savedbrightness or100fallback.88focused fake tests passed; physical black-display/sleep timing acceptance remains. Idle dimming, lock/screensaver and wide-tile calibration remain separate. Preserve the current Logitech recovery checkpoint. [Plan and evidence](d200x-workspace-evolution-plan.md).

## Logitech automatic recovery — 26 October 2026

Implemented and automated-verified; owner physical acceptance pending. Exclusive mouse ownership now retains automatic recovery after unexpected loss and uncertain cleanup, with fresh routing verification before action delivery and explicit cancellation. Final independent gate: 255 application tests and 149 Logitech test functions passed. Signed fixed-path build `7201f4cc38c4` is ready for relaunch. [Verification and owner checklist](logitech-reconnection.md). The broader package run had a separate D200X test failure, recorded there; no TaskView completion or physical acceptance is claimed.

## Active workspace evolution — 23 October 2026

**Wide-title/brightness follow-up, 24 October 2026:** owner confirmed action search and media controls. Approved wide-title normalization and bounded saved-brightness reapply after dial rotation are in signed build `2a5d55bb24e1`. Focused24/24 passed; device-side cause unproven and physical acceptance pending. No override means no rotation brightness writes.

**Action search correction, 24 October 2026:** signed build `723315930d51` replaces navigation-bar search with an inline field in the action chooser. Two background workspace checks and one inheritance check passed. Passive reproduction could not focus the SwiftUI control, so the original dismissal cause and search interaction remain owner-validation gates.

**Latest assignment follow-up, 24 October 2026:** signed build `cb88b450a46a` shortens knob labels and replaces deck assignment dropdowns with direct Record Shortcut/searchable Choose Action, current-value Clear and separate app inheritance restoration. One targeted inheritance and two final native window checks passed; pointer/capture interaction remains owner validation. Broad suite not repeated for this two-view change.

**Latest UI follow-up, 24 October 2026:** signed build `57231171afe7` replaces the knob gesture dropdown with directly visible Press/Rotate Left/Rotate Right buttons; Hold+Rotate is hidden without deleting saved bindings. Two background native window cases passed; no broad-suite repeat for this single-view change.

**24 October 2026:** DX-10 / TaskView476 core native actions and DX-08's compact Notifications/independent preset editor are ready for owner checks in signed build `715d2cc8ebfc`. Focused44, full retry528ordinary and4unique background native cases passed. The first full run's unchanged Logitech assertion remains recorded as intermittent, with cause unproven. [Action decisions](native-action-catalog-proposal.md), [manual checks](d200x-parity-owner-checks.md). Tasks remain In Progress pending owner acceptance; DX-09 payload safety spike remains deferred.

DX-08 / TaskView470 remains In Progress pending owner acceptance. The [workspace evolution](d200x-workspace-evolution-plan.md) and approved usability/history refinements are implemented. Signed build `557d230d712f` is ready; 503 ordinary checks and 3 background native cases passed. Owner confirmed baseline notification/script functionality; new UI, clearing, attribution, bulk appearance and physical text fitting remain owner checks. Physical pages remain deferred. [Owner checklist](d200x-parity-owner-checks.md).

## Current checkpoint —23October2026

DX-05 appearance and DX-07 local notification/script triggers are implemented and offline-verified on next/d200x-slice; owner physical acceptance remains open. TaskView448 and454 remain InProgress. Signed app+CLI are in dist. [Owner checks](d200x-parity-owner-checks.md), [decisions/checklist](d200x-parity-implementation.md). Pages/profiles, richer actions, wide telemetry/screensaver and unresolved encoder displays remain later slices. Earlier entries below are chronological records.

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

- **DX-10 / TaskView476:** owner approved the full core native action catalog on 24 October 2026. Implementation/verification is in progress alongside DX-08's compact Notifications and independent preset editor. [Action scope and decisions](native-action-catalog-proposal.md).

- **DX-09 / TaskView475:** deferred spike for safe notification payloads in actions. Compare literal arguments, structured stdin and restricted field templates; no production payload execution until findings and implementation scope are approved. DX-08 usability/history refinements are approved and in progress.

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

## D200X implementation started — 2026-10-23

Owner approved DX01–04 boundary on next/d200x-slice. Native UI acceptance no longer blocks this explicitly authorized slice. Research re-reviewed including latest21October addenda. See [implementation checklist and decision record](d200x-implementation-plan.md). Offline implementation/verification in progress; hardware display/input/recovery acceptance remains separate.

D200X DX01–04 implementation ready for owner hardware check on2026-10-23:417ordinary automatedchecks, model10/10 andbackgroundnative2/2 passed. Signedfixedbuildf9a33324270e5, no hardwareoperationsperformed. Nativeinlineinspector replacesmeasuredcrashinginspector modifier. TaskView444–447 remainInProgress; [decisions and manual gates](d200x-implementation-plan.md). Sourceuncommitted next/d200x-slice, nopush.

D200X first-use/frontfollow-up2026-10-23:manualConnectcreatesinitialconfig;startuplegacyinert;blockersvisible. Correctfrontbuttonsleftof3knobs,mousepaletteflatnativeartwork.36focused+mapping1+backgroundnative2passed;signedfixedbuild0c34ade62039.OwnerConnect/appearancepending;Task446remainsInProgress.

D200Xsettings-layoutfollow-up2026-10-23:mouse-styleoverview/compactsearchpopoverselector, deckcap630/gaps12;native2/2passed,signedfixedbuild39c8128d1456.Ownerpopover/visual/hardwarechecksremain. Scopeonly3presentationfiles.


Application-context removal verified 2026-10-23: both selectors expose minus.circle with help/accessibility labels, disabled for All apps/noneditable state, confirmation and stale-selection guards. Deck removal flows through canonical edit/autosave, returns to All apps and preserves defaults/other apps/tiles. Focused removal/persistence/UIAlignment/D200XModel20/20; background native2/2; signed fixed dist/Hidhogg.app and strict signature passed. Build dfa4626fed9f49cc75bcf36b5b61752d95fe02a79b282e35b8cd4558ee9a9b9b;134-input manifest refreshed. No production launch or hardware operations. Owner pointer/dialog/Cancel checks pending. Source remains uncommitted/unpushed. TaskView446 update failed (task not found/update failed); sync pending. Logs /Volumes/Data/tmp/hidhogg-application-remove-{focused,native,release}.log.


Dropdown-row removal checkpoint 2026-10-23: owner accepted previous removal behavior and approved placement inside each configured application row. Both selector views now expose sibling selection/minus.circle controls, no external minus and no minus for All apps. Pending row ID is pinned; confirmation checks membership/editability before selecting/removing it; Cancel preserves original selection. Stable outer confirmation uses existing popover-dismiss handoff. No model/schema/runtime/hardware changes. Focused20/20 and background native2/2 passed; signed dist/Hidhogg.app strict verification passed. Build 2e4fe94affff17cef3c0c99e9f908c68d9054100f60588c1e67c302f1861b553;134-input provenance refreshed. Actual dropdown/Cancel/destructive pointer interaction remains owner check. Uncommitted/unpushed; TaskView sync previously unavailable, no new task state claimed. Logs /Volumes/Data/tmp/hidhogg-remove-row-{focused,native,release}.log.


Window/control presentation checkpoint2026-10-23: default1280×800, minimum820×560 unchanged. Shared wide/compact control order Scroll wheel,Thumb wheel,Back,Forward; visible inspector/accessibility naming updated, persisted IDs/geometry unchanged. Native minimum/default2/2 passed with background non-key windows; parent visually reviewed /Volumes/Data/tmp/hidhogg-mouse-workspace-1280w.png and confirmed controls remain left of artwork in requested order. Capture has existing text/vibrancy artifacts; not pixel-accuracy proof. Signed fixed dist/Hidhogg.app strict signature passed. Build 7af6bc662a5d96cb26a0bd4ba931c1c2e2b414fc4c58976498cfbc23e2384f33;134-input provenance refreshed. Owner launch-size check pending; restored macOS geometry may override initial default. No real launch/HID operations. Source uncommitted/unpushed. Logs /Volumes/Data/tmp/hidhogg-window-size-{native,release}.log.


Resizable inspector checkpoint2026-10-23: approved mouse/D200X right-panel work complete in source and signed bundle. One native HSplitView inside navigation detail, flexible main and right child320/360/480; route-specific visibility, Settings omits editor, tile/front/dial reselect opens editor. Mouse preset/manual adaptive row stacks at narrow width; capture/Cancel vertical single capture subtree both devices. Shared WorkspaceInspectorView fills standard background. Rejected root .inspector probe:1280 helper discovery failed then820 process signal5 (cause unproven), retained root-probe log. Final HSplitView native2/2 minimum820/default1280 passed; actual requested320/360/480 produced320/359/479 at1280 for mouse Back/deck key0/dial0HeldLeft,159-point delta. At820 mouse initial337/max request473; deck429. Focused20/20 passed. Initial test accessor compile error and sandbox denial corrected/preserved. Parent reviewed mouse320 full action labels and deck1280 right panel renders; native bitmap text artifacts remain elsewhere. Signed dist/Hidhogg.app strict signature passed, build 9bb0daca1af3810534228c7241f3d33b8ebc124f818c5632eeb468e3341c5061,135-input provenance refreshed. No model/schema/protocol/HID operations. Owner still check pointer divider drag, hide/show, reselect, recording/manual cancel on hide/route/close. D200X close-only identity resets rely on onDisappear cancellation; actual capture teardown not directly tested. Source uncommitted/unpushed. TaskView previously unavailable; no task completion claimed. Logs /Volumes/Data/tmp/hidhogg-resizable-inspector-{native,focused,release}.log.


Initial inspector width checkpoint2026-10-23: owner confirmed adjustable panels work and approved starting narrower at320. Preferred320 and321 both measured480, retained failed probe logs; implemented WorkspaceInspectorInitialWidthAdapter one-shot public native NSSplitView trailing-pane ancestor lookup, bounded8×20ms readiness attempts and detach cancellation. Source review caught reentrant layout scheduling; corrected task marker lifetime and completion recheck. Final native2/2 passed: initial320 mouse/deck at820/1280, later320/359/479 width probes, resize and close/reopen. No focused/full repeat or live HID operations. Settings/control identity unchanged, range320–480; fresh panel mount starts320 again, later user drag unforced. Rare slow layout exceeding bounded retries remains limitation. Signed fixed dist/Hidhogg.app strict signature passed; build 22ae6f3c0b62d1491bdae2e6a192c20e0a4784cd93df0b9c31cd78e01ef70d0d,136-input provenance. Owner opening-width/pointer check pending; source uncommitted/unpushed. Logs /Volumes/Data/tmp/hidhogg-inspector-start320-{native,release}.log; source-only approval and final runtime evidence kept distinct.


Compact permissions checkpoint2026-10-23: baseline D200X/UI committed locallye2744ad on next/d200x-slice, no push. New approved settings edits remain uncommitted for owner acceptance. Single native Permissions section: Accessibility Required and Notifications Optional, compact status/actions, mismatch immediately below Access, notification errors local. Shared adaptive footer real app drag icon/current bundle URL, Refresh, Restart; single-page sections/anchors retained. Allow requests then opens existing relevant Settings deep link; denied/unknown notification states offer Open Settings (macOS prompt policy unchanged). Independent controller requestAuthorization() shares in-flight guard without enabling battery alerts or enqueue/latch mutation; setEnabled guarded behavior retained. Focused27/27 (18notificationcontroller+9UIAlignment) includes4newfake regressions; background minimum820/default1280 native2/2, fake automatic prompt count0. Parent reviewed /Volumes/Data/tmp/hidhogg-permissions-settings-1280x800.png; native runner displays fallback folder icon, production uses existing AppAppearance.icon. Signature strict passed. Build 2780fbd0a98f252378c770b78decd77cd37003153b5a9f5e99667d40b23b7485,137-input provenance refreshed. No real permission prompts/settings opening/drag/restart/HID tested. Owner verify Allow/OpenSettings, grant-and-return refresh, drag real app icon, Restart. Logs /Volumes/Data/tmp/hidhogg-compact-permissions-{focused,native,release}.log. Plan docs/settings-permissions-plan.md.


Deck appearance/parity planning checkpoint2026-10-23: owner reports compact settings working; approves removing decorative Ulanzi deck text and dial/front-button shadows. D200XDeckView only removes label/padding, side dark backer and dial offset ellipse; AX label now D200X control deck. Actions/selection/click regions preserved by source review. Native2/2 passed, parent reviewed600-point deck render: flat unbranded face; known320 front label truncation unchanged. Signed dist/Hidhogg.app strict verified, build fac97a84e6e5c0778f8b4ccc43822ceb10c02fe28f99a23d2e72fad48bd3ff2c,137-input provenance. No live HID/physical writes. New visual cleanup awaiting owner review; existing settings accepted generally, no new detailed live prompt proof. User requests aim toward Studio parity: read-only investigation+official feature overview reviewed, no22–23October researchaddenda found. Proposed brightness/static images/native title styling first, pages/profiles/native actions then wide/idle; firmwarefont/mode100 uncertainty and ecosystem boundaries documented in docs/d200x-studio-parity-plan.md. Feature code awaits concrete plan approval; existing excluded firmware/cloud/vendor binary-plugin scope not silently expanded. TaskView project5 resolved, but DX444–449 absent in current listing; do not reuse IDs until reconciled. Source remainsuncommitted since e2744ad, no push. Logs /Volumes/Data/tmp/hidhogg-deck-flat-{native,release}.log.


Parity selected-slice ready for owner review2026-10-23. DX-05 appearance and DX-07 local notifications/scripts implemented; TaskView448/454 InProgress (owner physical gates remain). Signed fixed dist/Hidhogg.app +dist/hidhoggctl, strict signatures and CLI --help passed. Build 1d3139b217262febb3e5b385dd08de734ea99b888d5114ccb9ad6cbe5a8a4860, 159source inputs, app 7312368bytes, CLI 901104bytes. Sourceuncommitted aftere2744ad, no push. Fullbaseline478ordinary tests passed (279XCTest incl2native skips +201SwiftTesting); finalpreviewfocused14+native2/2; finalassetreadbound9/9. Fullnotrepeatedafterboundedpreview/assetchanges. Parentinspected defaultdeck/settings snapshots; nativecachevibrancy artifacts remain so no pixelperfectclaim. Fakeprocess/device guards, isolatedtemporaryUnixsocket tests only; no actualuserapp/HID/configuredscript/permissionprompt tested.

Features: optionalcoalescedbrightness25–100; copiedboundedPNG/JPEG assets+host title styles onstandard/widekeys; sharedsmallasyncpreview; exactsource tileoverlays withcommit-timeTTL/replace/clear/captureddismiss; boundedmetadatahistory outcomes/control/eventIDs; configuredabsolute executable argv andtimeouts, queue/history; ownerlocalUnixAPI +signedCLI actionsinvoke/notifications/status/history. Mouse ControlBinding unchanged; D200X-specific scriptbinding type andstrict optionalTOMLfields keepoldconfigdecoding. SingleD200XModel remainsdisplaywriter. Criticalreview corrections: sourcemaptranspose, monotonicrawexpiry/catchup/saturation/historyeviction, capturedscript/notification/config identity, prewriteTTLauthorization, no normalcancellationofstartedwrites, publicreceiptoutcomes/IDs; regressiontests passed. Canonicalassetparent realpathfix handlesmacOSvaralias and rejectsassetleafsymlinks; storedPNGdimensionbound1024beforedecode.

Knownlimits: no fullStudio parityclaim; pages/profiles/media/textmulti-actions/widestatus/screensaver/encoderresearchremainroadmap. Script environmentempty, directchild cancellationonly, no capturedoutput; staleexistingUnixendpoint failsclosed requiresownerreview/manualcleanup. Ownerchecks docs/d200x-parity-owner-checks.md; implementationdecisions docs/d200x-parity-implementation.md. Nextaction ownerreopensbundle andtestsbrightness/importedimagepersist/scriptfromkey+CLI/notificationTTL+replace+clear+dismiss/reconnect+restart. Do notmarkmilestoneDone orsendcompletionnotification beforeownergate.


Compact menu checkpoint2026-10-23: owner approved one mouse battery/disconnected row and one D200X connected/disconnected row, with Connect/Disconnect removed from menu (device pages retain them). Only MenuBarView.swift changed versus prior159-input manifest. Mouse guards disconnected before cached battery; connected unknown/loading/unavailable statuses explicit, D200X alwayspresent childObservedObject forliveupdates. Open/Quit/config-save failure indication preserved. Sourceparse/diffreview and signedrelease typecheck passed; strictapp+CLI signatures passed. No full/native/runtime retake for presentation-only menu; actualmenu pointer/live status remainsownercheck. Fixed dist/Hidhogg.app build 04a51a7fba1382a442f543cd4d999b17dfa40c408b4fcf03df485ea37736738b;159-input provenance refreshed; uncommitted/unpushed. No app/device/scripts/permissions operated. Log /Volumes/Data/tmp/hidhogg-menu-compact-release.log. Existing parity physicalacceptance checklist remainsopen.
