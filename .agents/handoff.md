# Current checkpoint — master and README, 2026-10-23

Local master contains accepted checkpoint70b6068; next/logitech-slice points to the same checkpoint before README follow-up. No push. README refreshed with selected logo and current feature/build scope; local links checked. Type5 identification and physical notification delivery remain follow-ups. Local-only untracked files remain untouched.

# Accepted checkpoint — 2026-10-23

## 2026-10-23 — Owner-accepted checkpoint

Owner confirmed sidebar layout and authorized check-in of accumulated native UI, mouse artwork, device information, notification support, tests and documentation. Background gates/build evidence recorded above; real notification delivery and firmware type5 remain follow-ups. Local .envrc/.codex/macos, Python cache and compiled spike binary excluded without inspection. No push requested.

# Current checkpoint — sidebar centering

## 2026-10-23 — Sidebar vertical centering and Settings padding

Owner screenshot showed native default Label placed mouse icon at first text line. Approved shared SidebarLabelStyle explicitly centres the20x20 icon against complete title VStack, preserves matching horizontal columns, and adds4pt vertical padding to Settings. Nested battery label keeps standard titleAndIcon style. WorkspaceView only changed in this follow-up. Independent static review and background native2/2 passed; no pixel assertion, owner visual acceptance pending. Fixed signed bundle build09ea131e8d5468b40c8f6d7fe3ab396c940bf1fce73d5ca8c9e9d1174b70a83a; strict codesign and provenance updated. No production launch, device/config/notification operation, commit or push.

# Current checkpoint — sidebar follow-up

## 2026-10-23 — Sidebar alignment and contrast

Approved equal centred20x20 native Label icon slots for device and Settings; preserved name/status/battery. Sidebar-only #8F651F has calculated white contrast5.19:1, global accent unchanged. Independent review and background native2/2 passed. Signed fixed bundle build373fb2d693b6bb7019e95256f45ade50b9f570dbc9296730778188f4ad25063a; strict codesign passed and provenance updated. Owner visual acceptance pending. Firmware type5 unchanged. No production launch, live device operations, commit or push.

# Current checkpoint — notification scope and firmware display ready, 2026-10-22

Signed fixed bundle `dist/Hidhogg.app` build `76acd0ab10d46cf6bd0438dda058b039e0b85790c9a1d4f38d31ef01d5a9660a`, strict signature verified. Executable4,238,784bytes SHA25673ae87afe5e694598e71d2d0d46c82c0616ddf5c526e0bd3819d99104f124461. Updated116-input provenance includes final native fixture/test hash. Source uncommitted/no push.

Device page has “Notify below10%” checkbox beside battery, with narrow fallback and original model setter; timestamp remains below. Notification permission status/errors/actions now in app Settings Notifications section, no device permission block. Firmware main rows named MX Master3S, secondary bootloader/hardware/unknown under disclosure; valid packed BCD decoded into unpadded numbers, e.g22.1.6. Preserve duplicate main rows and activity; invalid BCD/unknown layouts unavailable. HardwareRevision optional byte1 retained from existing response, no additional request.

Independent focused gate passed24 XCTest +18 selected Swift Testing, zero failures. Background native2/2 passed with isolated notification center/latch fixture; prompt/enqueue methods fail tests and were never called. Native fixture now renders conditional checkbox and Settings Notifications branches. No real labels/Options+ parity/pointer/UN delivery assertion. No full-suite repeat for this pure formatting/presentation + typed raw-byte preservation change; previous full379 evidence below remains scoped to prior checkpoint.

Explorer/tester found no blocking defect. Logs Data/tmp/hidhogg-info-format-{tests,native,release}.log; pre-fixture native log retained separately. Owner next: reopen fixed bundle, check inline checkbox, app Settings Notifications section, and compare human firmware version with Options+ value. Real notification delivery remains owner gate. No production app/HID/UN/config/login operations. TaskView452/453 InProgress owner acceptance pending. Details/primary sources/decisions: docs/device-information-plan.md.

# Implementation record — notification scope and firmware display, 2026-10-22

Owner requests checkbox beside battery, app-global notification permission content in Settings, and meaningful firmware component names/numeric versions. `notification_permission_layout` finished DeviceBatteryOverviewView, LowBatteryNotificationSettingsView and PermissionsSettingsView (known-untracked baseline, no staging); no service/model/config change. `firmware_display` owns presentation, footer view, BCD tests and optional raw hardware revision preservation from existing payload. Tester `device_info_verification` waits for final source freeze, then focused parser/model/notification/formatter suites and background native gate. Parent owns docs/build/provenance.

Primary evidence newly verified: https://lekensteyn.nl/files/logitech/x0003_deviceinfo.html explicitly defines packed BCD firmware number, revision and build, and main/bootloader/hardware types0/1/2. Solaar implementation corroborates hardware raw byte1 and type low-nibble. Example raw0x2201/build0x0006 must display22.1.6, not8705 or hex. All records remain layers of the same selected mouse, never inferred receiver firmware. Invalid BCD must be unavailable; preserve multiple records, active flag and unknown kinds honestly. New evidence supersedes earlier cautious rawhex presentation.

Checklist: [x] owner-requested scope; [x] primary encoding evidence; [x] bounded delegation; [x] notification UI freeze; [ ] firmware freeze/focused tests; [ ] independent/background gate; [ ] signed fixed bundle; [ ] owner visual/version comparison. Current delivered build remains42d2e843700e until verified replacement. No production app/HID/notification/config operations. All tests background/non-key; no new polling or transport requests. Source remains uncommitted amid earlier UI work.

# Previous checkpoint — device information layout ready, 2026-10-22

Signed fixed `dist/Hidhogg.app` build `42d2e843700e096c772d3b14220ee0eba61c3aaa42e5344de2f3c8c5a8261fc0`, strict signature verified. Executable4,171,968bytes, SHA256dcc30948235f3c8db19eec960b5dee3484ebd17ec06141b5a86eef96deece279. Updated115-input provenance in dist/build-info.json.

Requested presentation is implemented: named menu battery; sidebar centred icon beside device name and one connection+battery line; battery/timestamp/alerts in the top overview; firmware/refresh at bottom after configuration status. Four existing views plus new DeviceBatteryOverviewView only. Executor frozen, independent tester and explorer found no material defect. Background native window gate2/2 passed, zero failures; no activation/front-order calls. Logs Data/tmp/hidhogg-info-layout-{native,release}.log. Prior functional379-pass-on-retry evidence remains below; full suite not repeated for layout-only changes. Menu/sidebar placement is source-reviewed, not a live visual or label-assertion proof.

Owner should quit/reopen the fixed bundle and check these arrangements at normal/narrow window widths. Current layout visual acceptance pending. No runtime/config/protocol/notification-policy changes, live device or notification operations, commit or push. Source remains dirty alongside earlier verified UI work. Docs device-information-plan/structure updated; TaskView452/453 retain owner acceptance gates.

# Implementation record — device information layout refinement, 2026-10-22

Owner reports INFO-01/02 looks good and asks for a named menu battery item, a two-line sidebar row (name, then connection + battery) with a vertically centred mouse icon, battery/alerts in the top overview, and firmware/refresh at the page bottom. `device_information_layout` owns only MenuBarView, WorkspaceView, DevicesView, DeviceInformationView and optional DeviceBatteryOverviewView. Parent owns docs/build; `device_info_verification` waits for source freeze, then performs static review and the existing background native gate. No new tests or full-suite repeat needed for this presentation-only change; previous functional evidence remains below. Current delivered bundle remains050d02547bd0 until replacement is signed and checked. No runtime/model/config/notification-policy changes; do not restore explicit sidebar/inspector width constraints. No production app/HID/notification operations.

Checklist: [x] requested layout confirmed by owner instruction; [x] bounded executor/tester assigned; [ ] source freeze/static review; [ ] background native gate; [ ] signed fixed bundle/provenance; [ ] owner visual acceptance. Plan: docs/device-information-plan.md presentation follow-up.

# Previous checkpoint — INFO-01/02 ready for owner check, 2026-10-22

- Fixed signed `dist/Hidhogg.app` build `050d02547bd017b8aed3dff83f1f7586f952a466b0d15b2c7929a136da15ec8e`, strict signature verified. Executable4,112,272bytes SHA2569a8295d4deff24827e881ad0aec7fd0b8132c7b5eef194bf8bfd166aa1129515. `dist/build-info.json` has114source/test/packaginghashes, exactgate/loghashes. Sourceuncommitted/nopush.
- Implemented: typedread-onlybattery1004cap/status+events andbounded0003mousefirmwareentities, selectedconnectionserialized/cancellationguards, reserve2IDspersignature, narrowoptionalmatchedprotocolerrorlocality withrealIOfatalityunchanged. Onceperconnection/manual/eventrefresh, no polling. Batteryinmenu/sidebar anddevicepage; rawhexfirmwareversion/build, refresh; deviceleveldefaultfalseTOMLalerttoggle.
- Alerts: explicitopt-inonlypermissionrequest; promptfreeload/reloadsync, validatedfresh0–9%knownnoncharging,5minfreshnessbound, durablelogicalprofilelatch, rearm>=20%. Independentreviewcaughtheldenqueue→recovery→newlowfalse-latch; corrected immutableinvalidation+singlelatesteligiblereplacement, successfulenqueuebeforelatch. Tests usefakeUN/latches; productionserviceinjectiononlyconvenienceAppModelinit.
- Verification: metadata18/18; firstfull214XCTest(2native skipped)0fail+167SwiftTesting1issue inexistingBoltThumbwheelTests451snapshotrace, samepreviouslyrecorded. Isolated1/1pass then onefullretry212+167=379passes,0fail. Backgroundnative2/2passed (820×560/980×680, non-key/orderBack). No existingwheeltest softened. Noactualmenu/sidebarvalueviewassertion; no liveHID/UNprompt/post/configread/loginchange. Runtime memory unmeasured.
- Logs Data/tmp/hidhogg-info-{tests,tests-retry,thumbwheel,native,release}.log; focused /tmp/hidhogg-info01-focused-final.log. Details/decisions/ownergates docs/device-information-plan.md. TaskView452/453InProgress acceptancepending.
- OWNER NEXT: quitold/openfixedbundle; connect,comparebattery/chargingmenu-sidebar-card; refreshfirmware andverifybindings/scrollcontinue; disconnecthidescurrentvalues/reconnectrefreshes. Enableopt-inandgrantnotificationpermission, confirmpersistence. Realalertdeliverywaitsnaturallowbattery(noforceddischarge). Actualsupportedvalues,chargingtransitions,broadcasts,notificationdeliveryunverified.
- Acceptedpreviousangledcanvas remainsnative; no explicitcolumnwidths restored; alltestingbackground. OtherUI04scroll/keyboardgate, sidebar/gold/saveblockrefinements remainseparate. Preserveexcludedlocals/.config/env/PIIboundaries. Mainalonewrites.agents.

# Implementation record — INFO-01/02, 2026-10-22

- Owner approved battery/mouse-firmware readback and asked for battery in menu-bar menu/sidebar, then optional below10% native macOS notification. TaskView452 INFO-01 and453 INFO-02 InProgress, project5/list67. Plan/criticaldecisions: docs/device-information-plan.md.
- Workers: `bolt_device_information` heavy owns metadata model/controller/transport/focused tests; `low_battery_alerts` owns savedflag/codec/nativealertpolicy+tests (sourcefrozen, firstcompilefixreturnedswitchapplied); `device_info_research` explorer brief done; `device_info_verification` tester owns new AppModelDeviceInformationTests and independentfull/backgroundgates afterfreeze. Parent owns AppModel/nativeviews/docs/build.
- Implemented source in progress: defaulted BoltStatus.deviceInformation; serialized optional1004cap/status and bounded0003firmwareentities; no serial/receiver/DPI/setters. Narrowrequest path suppresses ONLY matchedprotocolrejection's sessionfailure; realIO/disconnectguardretained; reserve2IDspersignature; validateeveryawait. Battery unsolicitedfunction0event uses cachedcapabilities; no polling. Parent triggers onceperconnection (notbindinggeneration)+manual, displays menu/sidebar and DeviceInformationView.
- Alerts: TOML low_battery_notifications_enabled defaultfalse; optionalproduction-onlyinjectedservice in AppModel avoids liveUN infixtures. Explicitenableonlypermissionrequest, no-promptload/reloadsync; freshvalidated0...9knownnotcharging, rearm>=20persistedlogicallatch, no serialkeys. Parentfreshnesslimit5min; actorpolicy handles pending disable/newdata. No realUNpost/prompt run.
- Checklist: [x] ownerapproval/research/seams/delegation/plan; [x] parentinitialUIglue; [ ] focusedcompile/tests (runtimeworker running coordinatedscratch); [ ] independentreview/full/backgroundwindows; [ ] signeddist+manifest; [ ] ownerhardware/opt-inacceptance.
- Latest DELIVERED bundle remains acceptedangledcanvas build5a564e91901e; do not confuse in-progresssource with delivery. No liveprobe/productionlaunch/HID/config/login/keychain operations. No env/secrets/PII reads. EarlierUI+newsource uncommitted/no push. All tests must staybackground/non-key; actualforegroundclick/notificationdeliveryremainownerchecks.

# Owner acceptance — 2026-10-22

Owner reports the integrated angled mouse UI is working. Artwork/control interaction accepted. Battery and firmware version requested as the next device-information follow-up; no implementation or live getter run authorized yet. Existing research describes Feature1004 battery status and Feature0003 mouse firmware entities; connected-device support must still be checked. Receiver firmware is separate and unresolved. Current source remains uncommitted; do not claim UI04 actual-scroll-offset validation from this general acceptance statement.

# Previous checkpoint — angled mouse integration ready for owner check, 2026-10-22

- Signed fixed bundle `dist/Hidhogg.app`, build `5a564e91901e7e82ce1437fe0bd4fc32e7605ce76e941ade59958e916598c3a2`, strict signature passed. Executable3,848,112bytes SHA25605252319845e5fab7966d1397c5e56b022adaea4394fb1a7c8d74e60e85be251. Updated105-input `dist/build-info.json`, exact gate/log hashes and source-artwork hash.
- Checklist: [x] SVG15 artwork approval; [x] bounded delegation; [x] exact20/20 path/colour/stroke static audit; [x] ordinary341 passes before final layout correction; [x] final focused9/9/native2/2 and narrow/wide renders; [x] signed bundle; [x] owner-requested background test harness/non-key assertions2/2; [ ] owner click/keyboard/resize acceptance.
- Native artwork replaces top-down+inset; cached20Paths, Canvas at displayed dimensions, exact path-shaped physical native buttons and four labels. Front-left crescent verticalwheel; side cylinder thumbwheel; upper-right Back/lower-left Forward. Stable8 region/label accessibilityIDs. No runtime parser, bitmap or dependency; runtime memory unmeasured.
- Render review caught compact2column word splits and hidden leaders. Final compact uses4fullwidthlabels; wide straight leaders above artwork with endpointdots. Preserved synthetic previews `16-native-angled-{narrow,wide}.png` in mockups/mx-master-3s. Actual pointerclicks/AXtree not tested. Owner should quit/reopen fixedbundle, click each physicalregion/matchinglabel, check inspector/gold and keyboard/resize.
- Tests now run background: removed activate/makeKeyAndOrderFront in nativefixture, use orderBack and assert non-key initial/reopen. Native2/2 passed after change; log `hidhogg-angled-native-background.log`. No productionapp/HID/config/login operations or foregroundclick test. Release binary unaffected by test-only change; manifest includes final testhash.
- Source uncommitted/no push; TaskView441 remainsInProgress owneracceptancepending. UI04 Settings owner scroll/keyboardcheck remainspending. Other sidebar/richergold/saveblock refinement requests are not implemented in this scope. No explicitcolumnwidths restored. Docs validation/structure/roadmap and mockupREADME updated.

# Implementation record — approved angled mouse integration, 2026-10-22

- Owner approved `docs/product-redesign/mockups/mx-master-3s/15-smooth-band.svg` and native integration. Revision15 is canonical; preserve its smooth curves, distinct surfaces and broad dark thumb-wheel band. Revision09 trace was noisy,10 over-flattened,11 angular;12–15 manually restored smooth contours/band.
- Checklist: [x] artwork approval; [x] bounded executor/tester/explorer delegation; [ ] source freeze and geometry audit; [ ] full/native regression and narrow/wide render inspection; [ ] signed fixed bundle; [ ] owner click/keyboard/visual acceptance.
- Executor `angled_mouse_integration` owns mouse geometry/artwork/presentation/palette/button files and removal of obsolete thumb-side views. Tester `angled_mouse_verification` waits for freeze; explorer `angled_mouse_scope_audit` handles final static audit. Parent owns durable docs, build/sign delivery and integration review.
- Important mapping: FRONT LEFT crescent near350,500 is vertical wheel; SIDE cylinder near950,390 is thumb wheel; upper-right side button Back, lower-left Forward. Executor's initial verbal wheel reversal was corrected before implementation freeze; independently check code.
- Chosen native cached paths avoid runtime SVG parser/bitmap/dependency. Keep canonical SVG geometry rather than risky further path merging for negligible source-size savings. Native labels remain large alternatives to tight nonoverlapping physical click regions. Do not restore explicit column-width modifiers. Runtime/transport/model/settings remain out of scope; earlier sidebar/gold/save-block requests remain pending separate work.
- Latest delivered bundle remains UI-04 build33da0970c776 until new build verified. No production launch/HID/config/login operations. Source remains dirty from earlier UI milestones; no broad staging or excluded-local access.

# Previous handoff — UI-04 ready for owner check, 2026-10-22

- Current signed dist/Hidhogg.app build33da0970c776268951ccafe15ce9b92fc4a5a798a0dbaab81a0cbe92794610f8. Strictsignaturepassed; executable3,877,664bytes SHA256b0ebaf5552149f617f9ccbe0f6cc4d3a9422529f491937451a0122dbdf6435de.107-inputprovenance dist/build-info.json.
- UI-04: onegroupedForm General/Permissions/Configuration/Diagnostics; childFormwrappers/tabsremoved. TransientsettingsScrollRequestID UUID bumpedforeveryopenPermissions; taskyield/cancelguard scrollsanchor, directcategorychange supported. RestartonlyPermissions; identicalDiagnosticsbuttonremoved. Existingactions/refresh preserved.
- Scopeaudit7expectedinputhashchanges versusacceptedreclaimbundle:5Settingsviews+AppModel+UIAlignmentTests. No runtime/HID/schema/fixednavigationwidth changes. Sourceuncommitted alongsidemainUIwork; previousconnectionfixcommitted18b23a1, nopush.
- Independent341ordinary checks passed (194XCTest,2native skipped+149SwiftTesting); explicitnative2/2 at820x560/980x680 passed. Nativefixturecoverslifecycle/modelselection, notFormactualscrolloffset/clicks. Logs Data/tmp/hidhogg-single-page-settings-{tests,native,release}.log. No productionapp/device/config/login operations.
- NEXT OWNER CHECK: reopenfixedbundle; scrollallsections; OpenPermissions thenmanuallyscrollawayandrequestitagain; minwindow/keyboardreachability. TaskView451 remainsInProgress untilacceptance. Do notclaimrealFormscrolljumpverified. CommitverifiedUIonlyafterowneraccepts.
- CONN01 acceptedbyowner, Task450Done, checkpoint18b23a1. SinglepageSettingswasapprovedafterconnectionfix andisnowimplemented. EarliernativeUIacceptedbutnotyetcommitted.
- Docs/ui-alignment-validation.md,docs/structure.md,docs/roadmap.md updated. Mainonly .agentswrites; preserveexcludedlocals/noenv/config/PII/secretreads.

---

# Latest acceptance checkpoint — 2026-10-22

CONN-01 owneraccepted and committed as18b23a1; TaskView450 Done. No push. EarlierUI changes remainuncommitted. Signeddist bundlece930217a62c remains current. Nextapprovedchange: single-pageSettings with permissionsectionjump.

# Current handoff — 2026-10-22: CONN-01 reclaim ready for owner check

- Branch next/logitech-slice; source remains uncommitted, no push. Prior native mouse UI accepted by owner.
- Current signed fixed bundle dist/Hidhogg.app buildce930217a62cb107be086313c35e0358aa0557362d30522ec7674e5a6a06e243. Strict signature passed; executableSHA2562e969ecfe7589ab17ae540ee271f10b3733d47d94c8b6a25e230622418f1faf3;107-input manifest dist/build-info.json.
- Owner approved getter-only hardware checks: Back/Forward diverted flags1/remap0; verticalmode1; thumb[1,0]; feature roots/capabilities valid. This explains initial baseline-back error and wheel unavailable, but setter origin remains unknown. No recovery writes or production launch performed by agents.
- Owner then approved Connect reclamation. Source now preflights recognised states/capacity, revalidates capability/feature associations, clears diversion only, verifies native beforeReady, then existing savedsettings reconciliation. Unknown/malformed state rejects; normalselfCID remap remains recognised. Dedicated attempted-write journal permits bounded native-only cleanup, never restores abandoned diversion. Cancellation can leave unattempted diversion but neverReady/admission. Status copy intentionally truthful; no Views/schema changes.
- Verification: actual-checkout behaviorred26issues→green.12new testfunctions/27parameter-or-singleton cases. Independentfull193XCTest(2native intentional skipped)+149SwiftTesting=340ordinary passed,0failures, no retry. Existing pause/readinjection shifts preserve their targetedoperations. Logs Data/tmp/hidhogg-reclaim-{red,final,independent,release}.log. New source app/Tests/LogitechBoltTests/BoltConnectRecoveryTests.swift; production BoltController/BoltProtocol. Prior DiagnosticsStore stage projection retained.
- Next required OWNER check: quitolderinstance/openfixedbundle; Connect or configuredlaunchconnection; Back/Forward shortcuts and bothwheel settings; Disconnect/reconnect. If failure reportstage/code/id/build. TaskView450 staysInProgress untilhardwareacceptance; do notclaimhardwarefixed yet or notify milestonecomplete.
- After connection accepted: implement owner-approved single scrollable Settings page (General,Permissions,Configuration,Diagnostics), OpenPermissions scrollsjump. Keep nativeautomatic sidebar/inspector sizing (prior crashfix); no widthmodifiers.
- Deferred finding: existing normal thumb preference encoding may drop acceptedsecondbyte bits1/2; reclaim preserves them. No broaderprotocolfix made. Prior intermittent capture assertion preserved in precedingdiagnostic logs, not reproduced in currentfullgate.
- Decisions/evidence docs/diagnostics.md. Only main writes .agents. Preserve unrelated excludedlocals (.envrc,.codex,macos,etc); no env/config/PII/secret reads. No hardwaremutation/testing without authorised scope.

---

## Prior checkpoint history (superseded by current block above)

# Handoff — 2026-10-22

## Current checkpoint

Branch `next/logitech-slice`. Last owner-accepted source commit `6ce6b23`; roadmap checkpoint `bf95c02`. UI-02/03 source/docs are uncommitted, no push, owner acceptance pending.

**Use corrected `dist/Hidhogg.app`, build `97d79d553024cf7551b4e3446963205bc51656d781e652703a07c72690ae8e99`.** It supersedes crashing build17e2cfd76146 and accepted pre-UI build9e322504174b. Arm64/macOS26, strict signature verified. Executable3,796,256 bytes, SHA256 `0fdfc18c425efb8f2f24a5870f842f29fd0059650ca31ae42483cea2d846826a`. `dist/build-info.json` records99 source/test/packaging input hashes; manifest `/Volumes/Data/tmp/hidhogg-window-fixed-source.json`. Release log `/Volumes/Data/tmp/hidhogg-window-fixed-release.log`.

Regular suite:190 XCTest passed,2 opt-in native cases skipped,134 Swift Testing passed; zero failures (324 ordinary checks). Explicit native gate:2 cases at980×680 and820×560 passed in each of two fresh processes. Covers real WorkspaceView with fake services, wheel inspectors, Settings/categories, permission routing, resize, close/reopen. Forward is not separately selected. Logs/hashes in [validation record](../docs/ui-alignment-validation.md); native log `/Volumes/Data/tmp/hidhogg-window-fixed-native.log`; repeat `hidhogg-window-fixed-native-run2.log`; regular `hidhogg-window-fixed-tests.log`.

## Window crash diagnosis and correction

Owner reported a crash opening the UI. Scoped report extraction showed main-thread AppKit constraint updates/SwiftUI SplitViewChildController; executable UUID matched delivered17build. Owner approved native reproduction and correction, plus optional production launch. Native harness reproduced actual constraint-pass exception before source changes.

One-variable experiments: removing WorkspaceView.navigationSplitViewColumnWidth cleared original980 opening; restoring it failed again; preferred-only and fixed220 also failed. Supported820 opening still failed with explicit DevicesView.inspectorColumnWidth; removing that modifier passed, restoring it failed, removing again passed. Final production correction removes **two explicit width modifiers**, using automatic native sizing. Other original98 input hashes unchanged except these two view files; new native regression test added. No broad framework blame: source-level layout interactions demonstrated on tested host. Sidebar/inspector features, history, lifecycle, minimum820×560 and device behavior retained. Custom inspector width bounds no longer specified.

Lifecycle bridge removal, equal-route guard, detail Group removal, toolbar removal and static Devices detail did not solve original crash; probes reverted. A plain-sidebar probe exited signal5, not green evidence. A780×520 test request was outside supported minimum, preserved separately and not a basis for correction. Diagnostic minimization cases and NATIVE_STAGE prints removed. Only test-class argument opt-in remains.

## Approved UI contract

Owner approved UI01–03 and1B/2A/3A. Four full-area outlined targets; only Back/Forward shortcut-bindable; wheels open device-wide inspector. Last editing app retained. Search configured contexts with bounded metadata cache/Add picker/confirmed Remove. Final Inherit retains app; empty context real store round-trip tested. Capture UUID guards commit/cancel; cancel on logical editor/app/window exit, preserve manual sheet handoff and visible offline editing. Manual chooser re-presentation blocked until previous dismissal cleanup. Typed config load/save/conflict UI; failed load editing read-only. Four Settings categories preserve existing operations; no transport/runtime/schema/defaults/package/polling changes.

## Next action / tasks

- UI01#440 Done; UI02#441/UI03#442/NX-M2#439 remain InProgress for owner visual/physical acceptance.
- Owner should quit existing copy and open corrected dist bundle, verify window and short checklist in validation doc.
- After owner acceptance, commit verified scope and close UI milestone; D200X remains blocked until then.
- No new code approval question pending; no source push performed.
- No milestone Discord notification yet because acceptance/completion pending.

TaskView Personal/HIDhogg project5 authoritative. D200X list66/milestone443:444 transport/identity→445 display→446 controls→447 independent maintenance/reconnect; later448 appearance/449 encoder evidence. Research external `/Users/axatol/Workspace/ai/rea/investigations/ulanzi-studio/inventory.md` previously checked through21Oct17:38 addendum; no fresh research/device claims. Vendor/Python acceptance is not Swift proof; do not repeat accepted vendor tests. No D200X work started.

Existing Logitech bindings, amounts/direction, Restart, current wake, menu styling and window-dependent Dock/CmdTab previously owner-accepted. Login UI Enabled confirmed; actual login boot untested. SmartShift423/continuation426 deferred; inertia characterization retracted. Actions/notification/MCP engines separate future slices.

## Limits and protection

Native verification used fake device/login, denied event-post preflight, temporary configuration and Console-suppressed diagnostics. No production app launch/HID/owner config/input posting/login registration was necessary. The owner authorized manual production launch if useful, but isolated native reproduction sufficed. Owner production/physical acceptance remains distinct. Resource soak, exceptional recovery/removal/isolation and boot login remain unverified.

Build requires scoped escalation, existing approved signer SHA1 `BD088C6A3D3855EA8F47857A604894BF98E3CF98`, no ad-hoc fallback. Use known SwiftPM command; do not retry scratch paths or inspect auth/env. Native test invocation: `swift test --disable-sandbox --build-system native --package-path app --scratch-path /Volumes/Data/cache/hidhogg-workspace-independent --filter NativeWorkspaceWindowTests`. Default full suite skips native opt-in tests. Native-build-system deprecation warning persists.

Do not run `xcrun xctest --help`: unsupported invocation emitted process environment into tool output during diagnosis. Values were not used or copied into project artifacts. Never inspect that output or environment. Use known valid SwiftPM invocation.

Excluded locals untouched: `.envrc`, `.codex/`, `macos/`, diagnostic Python cache, `spikes/go-hid-d200x/d200xprobe`. No broad staging/secret/config reads. Workers finished; native test windows closed; no production diagnostic mode added.

## 2026-10-22 — Mouse SVG review pending

Owner rejected rounded-box/grid canvas in favor of recognizable simple mouse vector with physical shaped controls or leader labels. Owner requested SVG render review BEFORE integration; do not integrate yet. Created docs/product-redesign/mockups/mx-master-3s/01-mouse-review.svg, VectorCraft-rendered PNG, and neutral transparent mouse-artwork.svg. Viewed product photo and official Logitech control overview; original simplified drawing, four editable controlIDs, Back selectedgold onreviewboardonly. VectorCraft import/export no warnings; visually inspectedPNG. Native callouts/hitregions remainfutureintegration. Current signed bundle/source unchanged at97d79d553024. README records design/reference/reviewstate.

Connection diagnosis authorized: parent scoped escalated last-hour query found3 external-state failure events, source BoltController.swift:511 in17/97 builds. This narrows to performEnable catch; exact guardunknown (capabilities, wheelownership, reportingbaseline/readback). No evidence anotherapp causedit; genericmessage misleadinglybutton-specific. No HID/config mutation. Keep diagnosis separate from SVG integration; no productionfix authorizedimplicitly fromartreview.

## 2026-10-22 — Reference-aligned SVG revision02

Owner rejected revision01 as unlike mouse and supplied top-view photo /Volumes/Data/tmp/codex-clipboard-A3ZOos.png. Main redrew silhouette/proportions/main-button seams and wheels as pure vector in docs/product-redesign/mockups/mx-master-3s/02-reference-aligned-mouse.svg. Rendered VectorCraft side-by-side comparison02-reference-comparison.png/.svg (photo embedded only in comparisonboard). VectorCraft noimport/exportwarnings; mainvisuallychecked. TopviewhidesBack/Forward, notinventedtopbuttons; callouts/sidedetailafter silhouetteapproval. Rev01 rejectedhistory. Rev02 awaitingreview, noappintegration orsource/bundlechange.

## 2026-10-22 — Simplified mouse revision03 awaiting review

Owner accepted revision02 shape, requested less detail. Created03-simplified-mouse.svg and VectorCraft-rendered03-simplified-comparison.png/.svg in docs/product-redesign/mockups/mx-master-3s/. Exact outer silhouette path unchanged (compared), nine paths after removing texture/palm contours/wheel grooves/layered shading. Main visually checked render, import/export no warnings. Shape accepted; simplified styling awaitingreview. No app integration/source/bundlechanges.

## 2026-10-22 — Combined control selection preview04

Owner agreed to both shaped diagram regions and leader-line labels selecting the same target. Main rendered04-linked-controls-review.svg/.png through VectorCraft: approved simplified silhouette, outlinedwheelregions/maincallouts and enlarged schematicthumb-sideinset forForward/Back, Backselectedgold. Decorative dashed connector identifies hidden sidecontrolarea. Staticreviewonly, notclickprototype; actualnativebuttons/keyboardhitareas awaitintegrationapproval. No appsource/bundlechanges. README currentrevisionupdated, XML/renderchecked.

## 2026-10-22 — Approved mouse vector integration started

Owner approved simplifiedSVG03 and combinedcontrolpreview04, thenconfirmed integration. Checklist: [x] designapproved; [x] boundedcanvas/artworkexecutor +independenttester delegated; [ ] integrationreview; [ ] actualnativebuttonpress/820+980gates; [ ] signedbundle; [ ] ownervalidation. ExactSVG geometry willbe nativeSwiftUI paths; noSVGengine/WebView/bitmapdecoding. EightnativeButton IDs (label/region x4targets), samepairselection/openinspector; sideinsetBack/Forward, outlinedwheels, compactnativecallouts notdownscaledtext. Protected AppModel/transport/schema/defaults/lifecycle. No explicitcolumnwidthconstraints. Connectionfailure separatelynarrowed toenablecatch511 remainsunresolved anduntouched.

## Approved native mouse integration — 2026-10-22

Implemented owner-approved simplified SVG03/linked controls04 as native SwiftUI paths and buttons. Independent audit confirms nine path geometries and correct four-target mapping. Parent added full-area label hit shapes and corrected side inset to112×148 so44pt hit areas do not overlap. No transport/model/config/lifecycle change. Automatic native column sizing preserved.

Verification:324 regular checks passed (190 XCTest+134 SwiftTesting;2 opt-in native skipped); native2/2 at820×560 and980×680 with all4 editor selections/Settings/resize/reopen. Synthetic240/600pt renders inspected and preserved under docs/product-redesign/mockups/mx-master-3s/05-native-canvas-*.png. AX click attempt found empty in-process host/window tree; no system AX request, failed helpers removed. Actual clicks/keyboard remain owner check.

Signed dist/Hidhogg.app buildf71eb46cbf95f4d2607238741358b64df8541356ab9eac04be039b507c8ebc4e, executableSHA256 f0a267d829cc0214792bc55eb47023f593522a6d3d994fdb6fccde7d9276d930; strict verification passed.106-input provenance in dist/build-info.json. Native/regular/release logs: /Volumes/Data/tmp/hidhogg-mouse-canvas-{native,tests,release}.log. UI-02/03 remains InProgress in TaskView441; owner acceptance pending; D200X blocked. No commit/push/production app launch/liveHID/ownerconfig/login operations. Separate connectionfailure narrowed to performEnable catch511; cause remains unresolved, guard unchanged.

Next: owner click each label/region, verify same inspector/gold; resize/scroll and keyboard; confirm production open/no crash. If accepted, commit only verified UI scope. Continue separate connectionfailure diagnosis under its authorization; do not infer Options+ caused it.

## CONN-01 diagnostic-first investigation — 2026-10-22

Owner accepted the integrated native mouse UI, requested connection correction and approved diagnostic-first instrumentation. TaskView450 InProgress. Existing evidence is external-state failure at performEnable catch511; exact guard/hardware cause unproven. Executor owns typed enable-stage context/controller capture/DiagnosticsStore projection and representative fake-transport red/green tests. Independent tester waits for freeze; main reviews scope/builds signed dist bundle. No safety/cleanup/admission/request behavior change or live device operations authorized by this implementation.

Checklist: [x] static seam mapped; [x] diagnostic code plan approved; [x] executor/tester delegated; [ ] stage red/green; [ ] scope review/full regression; [ ] signed bundle; [ ] owner controlled reconnect and exact stage; [ ] causal correction plan. Settings one-page request explicitly deferred by owner until connection issues fixed. Approved direction is General/Permissions/Configuration/Diagnostics on one scrollable page with permission jump; no Settings edit now.

## CONN-01 diagnostic checkpoint ready — 2026-10-22

Signed dist/Hidhogg.app build357bb2389311cf48a3fc64958566fb273cc3c38c8b03f5a8612459ffc4f8a19c, strict signature passed, executable3,861,536bytes SHA256128573404055509073383bfc0dfa7066a209619485d1844f826a188368635797.106-input provenance in dist/build-info.json.3production+4test diagnostic files only: BoltProtocol optional9stage enum/context; BoltController performEnable localstage/fail context; DiagnosticsStore stage suffix and neutralforeignState text. Requests/guards/cleanup/admission unchanged. No Settings changes.

Test evidence: first compile-red was copied fixture, not actualcheckout; final actualcheckout full193XCTest(2intentional native skipped)+137SwiftTesting passed. Independent firstfull had existing intermittent capture snapshot assertion at BoltThumbwheelTests451; preserved /Volumes/Data/tmp/hidhogg-connection-diagnostic-regression-attempt1.log. Retry /Volumes/Data/tmp/hidhogg-connection-diagnostic-regression.log passed328ordinary tests. Cause unproven; no unrelated fix. Executor logs connection-stage-green/diagnostics. Parent release log /Volumes/Data/tmp/hidhogg-connection-diagnostic-release.log.

Next required: owner launches signed fixedpath bundle, reconnects once, reports Failure stage +code/eventID/build from Settings Diagnostics Recent Activity. Underlying connection issue not yet fixed/proven; no speculative guard relaxation. TaskView450 staysInProgress. Source uncommitted/no push/productionlaunch/HID/config/login operations. Settings one-page layout approved for after connection issue fixed. Prior mouseUI accepted by owner.

## CONN-01 cause narrowed by approved getters — 2026-10-22

Owner approved bounded read-only device checks. Parent reviewed opt-in temporary directIOKit transport harness and executed11request then15request getter-only sequences; both passed. Actualstate: Back/Forward diverted(flags1/remap0); vertical2121 supportedmode1(diverted,not highres/notinverted); thumb2150 validinfo, mode diverted=true/inverted=false. All rootversions/flags valid. This explains buttonbaseline-back failure and bothwheelunavailable; originofdiversion remainsunknown. Exactprocesscount1Hidhogg,0logioptionsplus_agent/0logioptionsplus, notproof allcompetingsoftwareabsent. No processes stopped; no setters/devicechanges.

Probe removedfromapp tests; preserved /Volumes/Data/tmp/hidhogg-readonly-bolt-probe-20261022.swift. Logs /Volumes/Data/tmp/hidhogg-readonly-bolt-{probe,modes}-20261022.log. Docsdiagnostics updated. Existingdist diagnosticbuild357bb2389311 unchanged.

Next: pendingownerchoice approve reclaimonConnect vsmanualrecovery. ProposedConnect reclaimsrecognised diversion on4controls,verifyreadback thennormalapplysavedsettings; rejectunknownflags/remaps; intentionallyexclusiveownership mayoverrideothermapper. Explorer reviewingbounded insertion/preflight/budgets/partialfailure safety. Nofixwritesyet. Settings remainsdeferreduntilconnectionfixed.

## CONN-01 reclaim implementation approved — 2026-10-22

Owner asked meaningofdiversion and approvedreclaim. Explained nativeevents→macOS versus diverted→software; currentdeviceall4diverted causesbaseline rejection, setteroriginunknown. ApprovedConnecttakeover ofrecognisedstates, unknownflags/remapsstillrejected. Executorheavy connect_reclaim_implementation ownsBoltController/BoltProtocol/reclaimtests; independenttester preparesmatrix/waitsfreeze; explorerprovidedread-onlysafetybrief.

Chosenplan: allreadpreflight andaggregatepoolcapacitychecks beforeanysetter; recoveryinsertedafterreadCapabilities beforeReady, eager supportedwheel/thumbstate. Dedicatedjournal tracksattemptednative-targets only; preserve2121otherbits andentirevalid2150secondbyte (doNOTroundtripthroughMode.parameters). Onpartialfailure/cancel boundedcleanup onlyknownpre/targetstate, neverrestoreabandoneddiversion, unknownstate→uncertain/noReady/noadmission. Captureoperationrevision/disable/shutdown aroundawaits; existingcheckActivealoneinsufficient. Existingnormalpreferenceencoding notbroadenedwithoutprovenneed. Supportedfeatureunknownmodebecomesfatalpreflight; unsupportedrootremainslocalunsupported. UserSettingsonepage afterfix, noUIeditnow.

Checklist: [x] ownerapproval [x] delegatedplan/matrix [ ] failingreclaimtests [ ] implementationreview [ ] independentregression [ ] signedbundle [ ] ownermanualConnect/physicalcheck. No furtherhardwarechecks or mutations performed.

## CONN-01 accepted and committed — 2026-10-22

Owner reports everything working after reclaimbuildce930217a62c. Connectionfix accepted; TaskView450 Done. Commit18b23a1 onnext/logitech-slice contains9 explicitlystaged connectiondiagnostic/reclaim source,test,evidencefiles. No push. Earlier nativeUI work remainsuncommitted/separate. Previous340ordinary checks passed; no testsrerun solelyforacceptancedocupdate. Nextapprovedscope single-pageSettings (General,Permissions,Configuration,Diagnostics), permissionjump preserved. No additionalhardwareactions.

## UI-04 single-page Settings — 2026-10-22

OwnerapprovedimplementationafterCONN-01acceptance. TaskView451 InProgress. FiveSettingsviews nowonegroupedForm, noTabView/nestedForms. Mainaddedtransient settingsScrollRequestID UUID bumpedonopenPermissions forrepeatjump, plusonefocusedrequesttest. Hashcomparisonagainstacceptedreclaimbundle shows7expectedinputchangesonly (5views,AppModel,UIAlignmentTests). Boundedexecutorcomplete/sourcefrozen; independenttester runningfull/nativefakegates; parentreleasebuild inprogress. Existingnativeautomaticcolumns unchanged. No runtime/HID/schema/config changes. Owneractualscroll/keyboardvalidationpending; no productionlaunch.

## Angled mouse review artwork — 2026-10-22

Ownerproposedside-anglephoto /Volumes/Data/tmp/codex-clipboard-iRGVeu.png toshowall4controlswithoutinset; approvedrenderedvectorreviewbeforeintegration. Executorangled_mouse_vector owns06-angled-mouse.svg and06-angled-controls-review.svg only. MainVectorCraftimport/renderfirstpasswarningsnone; parentrejecteditswedgeoutline/wheelplacement/occludedleaders andsentphoto-coordinatecorrection. Iteration2inprogress. Noappsource/bundlechanges. PrimaryLogitechdiagram https://secure.logitech.com/en-gb/software/mx-software confirms4Forward/5Back; inrotatedphotoForwardlower-left/front,Backupper-right/rear. Actualmappingviewedusingofficialdefault.jpg atData/tmp/hidhogg-logitech-controls.jpg.

RequestedUIrefinementsstillpendingintegrationplan: replaceinsetwithoneangledmouse, labelsleft, simplifySavedonThisMacblock/linktoSettings, richergold, sidebarConnectedalignedwithdevicetext andmouseiconverticallycentered. Currentapprovalcoverspreviewonly. UI04Settingsbuild33da0970c776 remainscurrent; realpermissionjumpmanualchecknotyetreported.

## Angled vector preview ready — 2026-10-22

Reviewonlyartifacts06-angled-mouse.svg,06-angled-controls-review.svg/.png underdocs/product-redesign/mockups/mx-master-3s. Parentrevisedfirstpassagainstphotooutline/coordinates, elongatedsidebuttonregions, replacedlongboxleaderloopswithshorterpathsaboveart. VectorCraftimport/exportwarningsnone; finalPNGvisuallyinspected. Standalone15paths/noimages/norenderedtext, referencephotoembeddedonlyboard. Leftlabels4targets, Backricher#D8A52E, nosecondaryinset. PrimaryLogitechdiagrammappingverified. Ownerartreviewpending; noappsource/bundle/test changes, signedcurrent33da0970c776 unchanged. Otherrequestedsidebar/save/accentrefinementspendingintegration. READMErecordsreviewscope.

## Revision07 artwork ready — 2026-10-22

Ownerrejected06lines/shapes. Sourceworkerowned07standalone; mainadjustedbroadfrontpanel/seamsandbuilt07reviewboard with4single-straightlineleaders(noelbows), widerwheels/smaller14x4sidebuttons, curvedplanes, photoonlyboard. VectorCraftimport/exportwarningsnone; parentvisuallycheckedrender/linecrossings. Files07-angled-mouse.svg and07-angled-controls-review.svg/.png; READMEupdated. Ownerreviewpending; noappsource/bundlechanges. OtherUIrefinementsremainpending.

## Artwork acceptance failure / photo trace checkpoint — 2026-10-22

Ownerrejected07notclose; stopintegration/freehandshapeguesses. MainusedVectorCraftimageTraceactualphoto(5colors/noise25,44paths),selected14neutralregionsandphoto-derivedcontourmask for08-photo-contour-mouse.svg;08-photo-contour-review.svg/.png comparesphotoandbaretrace. No leaders/interactionlabels. Renderingwarningsnone; mainvisuallyinspected. ThisisROUGHgeometrycheckpoint, lightingboundaries/edgeirregularitiesstillneedcleanup, NOT finalapprovedsimplifiedvector. No app/bundlechanges. Failed07silhouette/planes/capsulewheelsdocumented; primaryreasonfreehandgeometrydeviated. Nextownerreviewgeometrythencleanpathswithoutalteringproportions; addlabelsaftershapeacceptance. ArtifactsREADMEupdated. Temporary reproduciblescript /Volumes/Data/tmp/hidhogg_trace08.py andrawtrace /Volumes/Data/tmp/hidhogg-reference-trace08-simple.svg. No furtherproductionworkuntilshapeapproved.
