# UI-02/03 validation

Implementation checkpoint, 2026-10-22. Owner reported a window-open crash in build17e2cfd76146. Current native-canvas buildf71eb46cbf95 is signed and independently verified with native windows; owner production-app/physical acceptance remains pending. D200X remains blocked. The original324 model/protocol tests did not exercise native window opening.

## Approved native mouse canvas — 2026-10-22

The approved simplified SVG is integrated as native SwiftUI paths, with four linked label/physical-region pairs and a separate thumb-side inset. Independent static review confirms the nine artwork paths and correct target mapping. One-point-wider side outlines preserve the preview positions; 44pt side hit areas have45pt center spacing. No runtime SVG parser, WebView, new dependency, device transport or configuration changes were introduced.

| Gate | Result |
|---|---|
| Native window lifecycle | 2/2 passed at820×560 and980×680, selecting all four targets, Settings, resize and reopen |
| Regression | 190 XCTest +134 Swift Testing passed;2 opt-in native cases skipped in the regular run; zero failures |
| Visual fixtures | Synthetic240pt and600pt canvas renders inspected; complete artwork, readable labels and side inset |
| Native button presses | Not established: the isolated hosting view/window exposes an empty in-process accessibility tree. Failed discovery assertions removed; owner click/keyboard check remains |
| Release | Buildf71eb46cbf95, arm64; strict signature passed |

Current app: `dist/Hidhogg.app`, build `f71eb46cbf95f4d2607238741358b64df8541356ab9eac04be039b507c8ebc4e`; executable3,840,192 bytes, SHA256 `f0a267d829cc0214792bc55eb47023f593522a6d3d994fdb6fccde7d9276d930`. The106-input manifest is recorded in `dist/build-info.json` and `/Volumes/Data/tmp/hidhogg-mouse-canvas-source.json`. Logs: `/Volumes/Data/tmp/hidhogg-mouse-canvas-native.log`, `/Volumes/Data/tmp/hidhogg-mouse-canvas-tests.log`, `/Volumes/Data/tmp/hidhogg-mouse-canvas-release.log`. [Narrow render](product-redesign/mockups/mx-master-3s/05-native-canvas-narrow.png) / [wide render](product-redesign/mockups/mx-master-3s/05-native-canvas-wide.png) are synthetic widths, not measured workspace columns.

Owner checks: click each label and matching region; verify same target/inspector and gold selection; resize and scroll; navigate targets with keyboard. Connection external-state failure remains separately unresolved at `performEnable` catch511; this UI does not bypass it. No production launch, HID/config/login operations, commit or push. UI-02/03 remains pending owner acceptance.

## Window-open crash follow-up

Owner authorized scoped crash-report inspection and native reproduction/correction. The latest exact Hidhogg report shows SIGABRT on the main thread during AppKit constraint updates; the exception backtrace includes NSHostingView.SizeConstraints.update and SplitViewChildController. This is evidence of the failing layout path, not yet proof of the triggering view. A native window harness with fake device sessions and temporary configuration is being built before production changes. Personal report metadata is omitted.

The crash executable UUID matches the delivered binary. Native reproduction fails with NSGenericException: the window exceeds its allowed constraint-update passes. The original WorkspaceView case fails in approximately1.4 seconds; DevicesView alone, DeviceControlCanvas alone, minimal NavigationSplitView, and NavigationSplitView with real DevicesView detail each pass in separate processes. These use fake device/login services, denied event-post preflight and a temporary config URL. The native test is opt-in through an explicit XCTest filter; ordinary unfiltered tests skip it. Initial red log: `/Volumes/Data/tmp/hidhogg-window-repro-red.log`; minimization logs: `/Volumes/Data/tmp/hidhogg-window-minimize-*.log`. Both inside-detail and outside-navigation inspector placement are supported by [Apple's inspector guidance](https://developer.apple.com/videos/play/wwdc2023/10161/); these results do not establish an invalid inspector placement.

### Demonstrated correction

Removing only `navigationSplitViewColumnWidth(min: 180, ideal: 220)` from WorkspaceView makes the original native test pass. Restoring the original modifier reproduces the failure; removing it again passes open/resize/reopen. Preferred-only and fixed220 variants also fail, so native automatic sidebar sizing is selected. Removing the lifecycle bridge, adding an equal-route guard, removing the detail Group/toolbar or holding Devices detail static did not solve the failure; those probes were reverted. A simplified-sidebar probe exited signal5 and is not treated as green evidence. Logs: `/Volumes/Data/tmp/hidhogg-window-probe-*.log`.

The stronger test then found a second sizing interaction opening at the supported820×560 minimum. Removing only `inspectorColumnWidth(min: 310, ideal: 360, max: 460)` from DevicesView passes the minimum-size/wheel/Settings/close-reopen flow; restoring that modifier reproduces signal5 before window opening; final removal passes again. Logs: `/Volumes/Data/tmp/hidhogg-window-inspector-probe-2-restored-red.log` and `/Volumes/Data/tmp/hidhogg-window-inspector-final-green.log`. A separate780×520 request was below the supported minimum and is preserved only as an out-of-contract probe in `/Volumes/Data/tmp/hidhogg-window-minimum-red.log`; the supported820 opening also failed independently, so the correction is not based on that invalid-size probe.

Final production correction: remove the two explicit sidebar/inspector width modifiers and use native automatic column sizing. This establishes source-level layout interactions on the tested host; it does not determine whether SwiftUI or AppKit has a framework defect. The inspector, navigation, lifecycle bridge, supported minimum and device behavior remain intact. Hash comparison against the98 prior build inputs shows only DevicesView and WorkspaceView changed; the native regression test is new. Independent checks passed at both980×680 and820×560 in two fresh processes. Diagnostic minimization cases and temporary stage markers are removed; the real WorkspaceView native regression remains as two opt-in tests. Native automatic sizing replaces custom inspector width bounds; exact column widths are no longer specified by this app.

## Short owner checklist

Run the signed `dist/Hidhogg.app`. These checks exercise existing features in the new layout; no overnight campaign is required.

| Check | Expected result |
|---|---|
| Select Back, Forward, vertical wheel and thumb wheel | Whole outlined target responds; selected outline is gold; the appropriate inspector opens |
| Choose All apps, add/select an app, set one override, return to Inherit | Effective default appears; app stays listed and selected; wheel settings remain device-wide |
| Record a shortcut, then navigate away or switch apps without accepting | Recording ends; prior binding is unchanged; button handling resumes |
| Choose a shortcut manually; Cancel once and accept once | Cancel preserves the old binding; accept changes only the selected app/button |
| Adjust one wheel preference and revisit after reopening | Autosaved preference is retained; existing physical scrolling behavior still works |
| Open Permissions from the device warning, then visit all Settings categories | Correct category opens; permission drag/refresh/restart, login, reload and diagnostics remain reachable |
| Resize to the minimum window size; use keyboard navigation | Controls remain reachable by scrolling/inspector toolbar; no essential action is clipped |
| Close and reopen the workspace | Menu-only background behavior and existing Dock/⌘Tab behavior remain intact |

No need to revoke permissions, modify external configuration or trigger a real disk failure for this checklist. Error/conflict/load cases use temporary-file fixtures in automated tests. Record any failure with the control/app context and diagnostic code/ID.

## Implementation decisions

| Decision | Reason / alternative |
|---|---|
| Separate transient editor target from domain MouseControl | Four selectable editors without inventing wheel shortcut bindings or a schema migration |
| Preserve empty application maps | Owner selected stable inherited contexts; automatic pruning was rejected |
| UUID-scoped capture commit and cancel | An old editor callback must not change or cancel a newer capture |
| Cancel on logical editor exit; preserve manual-sheet handoff | Prevent hidden paused shortcuts without breaking the visible manual chooser |
| Typed load/save/conflict presentation | Preserve existing store/revision policy; avoid classifying localized error strings |
| Configuration read-only after load failure | Preserve the last draft and provide Reload while leaving permissions/diagnostics available |
| Serialize manual chooser presentations until dismissal cleanup | Prevent an older sheet dismissal from reading a newer session ID; this was a source-review race, not a reproduced native failure |

## Verification record — corrected build

| Gate | Result |
|---|---|
| Native real WorkspaceView with fake services | Two tests at820×560 and980×680 passed in each of two fresh processes |
| Native interactions | Open; Back inspector and both wheel inspectors; Settings/categories; permission navigation; resize; close/reopen. Forward is not separately selected by this native test |
| Regular regression | 190 XCTest passed,2 opt-in native cases skipped;134 Swift Testing passed; zero failures.324 ordinary checks, plus2 distinct native cases passed in the explicit gate |
| Signature / architecture | Strict signature verification passed; arm64/macOS26 |
| Owner production-app/physical validation | Pending short checklist above |

Current bundle `dist/Hidhogg.app`: build **97d79d553024cf7551b4e3446963205bc51656d781e652703a07c72690ae8e99**; executable3,796,256 bytes; SHA256 `0fdfc18c425efb8f2f24a5870f842f29fd0059650ca31ae42483cea2d846826a`. Source/test/packaging manifest99 inputs in `dist/build-info.json` and `/Volumes/Data/tmp/hidhogg-window-fixed-source.json`. Release log `/Volumes/Data/tmp/hidhogg-window-fixed-release.log`.

- Native log `/Volumes/Data/tmp/hidhogg-window-fixed-native.log`, SHA256 `d46e100a74f603fa451a48c7f3393eaca07ca51498a529982b6b574e9374d660`.
- Repeat `/Volumes/Data/tmp/hidhogg-window-fixed-native-run2.log`, SHA256 `aa77dcbbd8052c460b725278b605e152c4cc0c4f333a0b358b7b4b0d42be248f`.
- Regular suite `/Volumes/Data/tmp/hidhogg-window-fixed-tests.log`, SHA256 `8712e0b073fd0b478ceaf1252430050c6ef06ecc4be02b79764e0b751123cd0f`.

No production app launch, live HID, owner config, keyboard posting or login registration was performed. Native windows used fake sessions/login and denied event-post preflight. The user authorized a production launch if needed, but the isolated reproduction was sufficient. No production debug probes remain. Source remains uncommitted; no push. UI-02/03 remains open for owner acceptance.

## Previous checkpoint — superseded, retained as history

- Automated suite: 8 focused tests passed; final frozen-source regression passed **190 XCTest + 134 Swift Testing = 324**, zero failures. The first full run caught one old assertion expecting “Save failed” instead of the new typed “File conflict”; the assertion was corrected and the final suite passed. Final log: `/Volumes/Data/tmp/hidhogg-ui-alignment-tests.log`, SHA256 `8793cbc470e0f0d958e58a07b732977eee2db6491b3c0433ddd95c350f11af90`.
- Signed fixed-path bundle: `dist/Hidhogg.app`, arm64/macOS26, build **17e2cfd761465676afcc13a40b1736e5cf1a2828c8f01830bafbbd6077c5a7d7**. Executable 3,804,656 bytes; SHA256 `4e4317175a5ecc9255c0de288b4ddef635d306d97e8fca77e77535da3c87fce1`. `codesign --verify --strict` passed. Build log `/Volumes/Data/tmp/hidhogg-ui-alignment-release.log`. `dist/build-info.json` records 98 source/test/packaging input hashes; source manifest also at `/Volumes/Data/tmp/hidhogg-ui-alignment-source.json`.
- Native visual/physical acceptance: pending owner checklist above.
- No production device or owner configuration operations were performed during implementation.
- No new polling, transport/runtime ownership or schema changes. Metadata cache is bounded by configured contexts. Native resize/focus/VoiceOver performance and resource-soak behavior have not been established by these tests.
- Changes remain uncommitted on `next/logitech-slice`; no push was performed. UI-02/03 and NX-M2 remain open for owner acceptance.

## UI-04 single-page Settings — 2026-10-22

Owner approved one-page Settings after accepted connection recovery. General/Startup, Permissions, Configuration and Diagnostics now share one native grouped Form, no tabs or nestedForms. Childviews contribute sections. Restart remains once beside Permissions; duplicate Diagnostics Recovery section removed. A transient UUID scrollrequest ensures repeated OpenPermissions remains observable evenwhen targetcategoryalreadyselected. Category state remains a transient anchor, not persisted config. No runtime/HID/schema/columnwidth changes.

Independent gates:194XCTest cases with2intentional native skips,149SwiftTesting passed (341ordinary checks); explicitnative2/2 at820×560 and980×680 passed. Nativefixture exerciseswindowlifecycle/modelselection; actualFormscrolloffsets and nativeclicks are not proven. Ownerchecks: scrollallsections, useOpenPermissions, scrollaway/useitagain, resize/keyboardreachability. Sourceuncommitted pendingacceptance.

Signed dist/Hidhogg.app build33da0970c776268951ccafe15ce9b92fc4a5a798a0dbaab81a0cbe92794610f8; strictsignaturepassed. Executable3,877,664bytes SHA256b0ebaf5552149f617f9ccbe0f6cc4d3a9422529f491937451a0122dbdf6435de. Logs /Volumes/Data/tmp/hidhogg-single-page-settings-{tests,native,release}.log; provenance dist/build-info.json. No productionlaunch/device/config/login operations.
# Angled mouse integration — 2026-10-22

Owner approved `15-smooth-band.svg`. Native cached paths replace the top-down drawing and separate thumb-side inset. Independent static comparison confirms all20 path commands/coordinates, seven source colours and inherited round caps/joins match. Canvas uses displayed dimensions; control hit paths and drawing share uniform scale/origin. No SVG parser, artwork bitmap, dependency or device behavior change.

The first synthetic render exposed split words in compact two-column labels and misleading leaders hidden behind the body. Corrected to four full-width compact labels and straight visible leaders with endpoint dots. Final [narrow240pt](product-redesign/mockups/mx-master-3s/16-native-angled-narrow.png) and [wide600pt](product-redesign/mockups/mx-master-3s/16-native-angled-wide.png) previews were visually inspected. These are isolated native fixtures, not production-window captures.

Verification: full suite before the final presentation-only correction passed192 XCTest, skipped2 opt-in native cases, and passed149 Swift Testing checks (341 ordinary passes, zero failures). After the correction, focused UIAlignmentTests9/9 and native window tests2/2 passed. Native windows cover820×560 and980×680, all four model selections, Settings, resize and reopen. Logs `/Volumes/Data/tmp/hidhogg-angled-{tests,ui,native}.log`; sandbox-only cache failures were preserved separately and passed on scoped escalated retries.

Owner check: open the signed fixed bundle; click each physical region and matching label and confirm the same inspector/gold outline; resize and check keyboard navigation. Actual pointer clicks/accessibility-tree assertions are not established by the synthetic harness. No hardware/config/login operation was performed. Runtime memory has not been measured; no numeric memory reduction is claimed.

Background-testing follow-up: owner requested that tests avoid foreground disruption. The native harness now uses `orderBack(nil)` rather than activation/front-order calls and asserts that initial and reopened windows are visible but non-key. Both native cases passed again, zero failures (`/Volumes/Data/tmp/hidhogg-angled-native-background.log`). This verifies non-key test windows, not a global macOS focus audit. Foreground interaction tests remain a separate scope.

Delivered `dist/Hidhogg.app` build `5a564e91901e7e82ce1437fe0bd4fc32e7605ce76e941ade59958e916598c3a2`: strict signature passed, arm64/macOS26; executable3,848,112 bytes, SHA256 `05252319845e5fab7966d1397c5e56b022adaea4394fb1a7c8d74e60e85be251`. Updated `dist/build-info.json` records source/test hashes and gate boundaries. No source commit or push; owner interaction acceptance pending.
