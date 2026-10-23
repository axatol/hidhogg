# D200X native first slice

Approved 2026-10-23; branch next/d200x-slice from master a2b7c83. Research re-reviewed: inventory, handoff, Swift specification and latest 21 October lifecycle addendum in external ulanzi-studio investigation.

## Checklist

- [x] Owner approves code boundary and judgment-based routine decisions.
- [x] Re-review research and device-workspace mockup.
- [x] DX-01 bounded native codec, transport and identity (offline verified).
- [x] DX-02 page/archive and incremental display (offline verified).
- [x] DX-03 native editor, persistent bindings and injected shortcut delivery.
- [x] DX-04 independent GETBASE maintenance, cancellation/reconnect (offline verified).
- [x] Independent offline regression and background native checks.
- [x] Signed fixed dist/Hidhogg.app.
- [ ] Owner native hardware acceptance.

## Boundaries and decisions

| Decision | Chosen | Alternative and justification |
|---|---|---|
| Ownership | Independent UlanziD200X module/session in same process | Extending mouse BindingSession couples incompatible protocols; separate daemon violates single owner goal |
| Configuration | Optional top-level d200x table in existing TOML; old mouse documents unchanged | Reusing mouse-only DeviceBindings distorts validation; another config file adds conflict/autosave machinery |
| Interface | Device sidebar route, actual 13 square plus wide key, 2 side buttons, 3 dials; native inspector | Mockup deck geometry is illustrative, physical investigation is authoritative |
| First action | Keyboard shortcut via existing native sender; explicit disabled/inherit | Shared action library and plugin execution are independent unbuilt engines |
| Gesture semantics | Keys/side/dial press dispatch once, release never triggers; held rotations explicit | Synthesized releases/stateful held derivation contradict captured events |
| Images | Native generated PNG labels/color, content-derived names, bounded STORED ZIP | DEFLATE closer vendor but new dependency unnecessary: both encodings accepted |
| Maintenance | Five-second GETBASE independent of renders; bounded timeout and lifecycle epoch | Redrawing whole grid wastes traffic; command5 wake unproven |
| Scope | No device commands during automated verification | Python success is not Swift proof; real display/input checks require owner gate |

## Verification limits

No firmware/screensaver writes, custom encoder command17, mode100 guesses, serial logging/persistence, vendor plugins or cloud services. Do not rerun accepted vendor/Python wizard. Swift IOHID report convention, physical image appearance, native inputs and replug/sleep recovery remain new hardware gates.

## Review checkpoint — 2026-10-23

Independent review found appearance-edit cancellation could close an in-flight frame; model now coalesces edits and completes the active transfer before deriving the next diff. Actual last-transferred page, not latest desired draft, forms the incremental baseline. The held-transfer regression passed. Reviewer also identified reader blocking on a queued font response and GETBASE deadline starting before its queued write; both paths were corrected and their suspended-write regressions passed. These are offline findings, not observed hardware failures.

Configuration compatibility: schema stays1 with an optional strict d200x table. Older app binaries reject that new table rather than silently ignoring it; preserve a backup before downgrading. Initial slice has one page, baked native PNG labels/colors and keyboard shortcuts; image-file import, multiple pages, shared action library and encoder displays are deferred. No archive/frame/serial is persisted.

## Native-window correction

The background820-point route-switch test reproduced AppKit UpdateConstraints failure after entering the new deck page. Removing only the D200X inspector modifier passed; restoring it reproduced the same failure. Final correction uses the existing page ScrollView with a conditional inline native inspector and no nested inspector ScrollView. Alternative native inspector sidebar was rejected for a measured constraint/preference-bridge failure; no fixed split-view/inspector widths added. This deviates from the mockup side panel to preserve native stability and reachability. Final background native2/2 passed.

## IOHID callback lifetime evidence

Apple published IOKitUser/hid.subproj/IOHIDDevice.c implements immediate aborted callbacks during UnscheduleFromRunLoop (763–782;2110–2126), invalidates callback registrations and suppresses a duplicate late completion (1697–1719). Transport cleanup unschedules before close; callback owns and releases its report buffer. This is source-level evidence, not a native device run. Source: https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDDevice.c . Apple report API: https://developer.apple.com/documentation/iokit/1588661-iohiddevicesetreportwithcallback .

## Additional lifecycle decisions

Connection on launch applies only after the user adds a D200X configuration; legacy configurations remain inert for the deck. Explicit Disconnect suppresses retries. Unexpected failures use at most three automatic retry delays (1,2,5 seconds); a successful identity alone does not reset the allowance when the desired page keeps failing. A successful page transfer resets it. On reconnect, render-task state is retired and the complete desired14-slot page is restored before incremental updates resume. No multiple-page or same-model device-selection UI is claimed; ambiguous matching decks are rejected.

The first native action posts a paired shortcut on key/side/dial press, with release/repeat suppression; dial rotation/held-rotation use explicit wire gestures without invented hold state. Editing application context never changes the runtime foreground target. No key remains held between events.

## Owner validation checklist

1. Quit Ulanzi Studio, open the fixed signed Hidhogg bundle, choose Ulanzi D200X, then Connect (the initial configuration is created automatically). Confirm the deck identity/firmware and connection status. No hardware validation was performed by automated tests.
2. Verify all14 displayed keys (including wide key), edit a label/background and confirm only that slot changes. Compare app layout against physical key and side/dial locations.
3. Assign a harmless shortcut in a disposable document; verify key/side press once, dial left/right and held-left/right, app override versus inheritance, and mouse bindings still work independently.
4. Leave the page awake for a short bounded check, then Disconnect/reconnect and unplug/replug; confirm desired-page restoration and no duplicate actions. OS sleep/wake and long-duration efficiency remain separate checks.
5. Restart app and Reload from File; confirm deck edits persist, disabled bindings stay disabled and Logitech preferences remain intact. Existing physical displays may be replaced when Connect sends the configured page; there is no original page backup/restore claim.

## Final offline verification — 2026-10-23

- Focused deck model10/10, including held-transfer coalescing, failure-event-before-write-throw replacement after reconnect and persistent page failures bounded to3 retries.
- Final full suite233 XCTest executed/2 opt-in skips/0 failures plus186 Swift Testing passes =417 ordinary checks. No retry needed for this final gate.
- Background native window2/2 passed at820x560 and980x680 with deck route, representative key/wide/side/held-dial inspectors, Settings, resize and reopen. Visible/non-key assertions retained. Screenshot caching has native vibrancy/text artifacts and one980-point black pane; do not infer pixel fidelity or owner visual acceptance from these captures.820-point deck capture shows corrected square proportions.
-18 dedicated protocol/archive/session cases passed within full gate, including blocked font response allowing identity/input consumption and response deadline beginning after queued query write.
- Signed fixed bundle build f9a33324270e5ca80a3fb0ff77aadd4d617d04cbd351d2bfe320897f040427af. Strict codesign passed. Executable5662720bytes;132-input provenance dist/build-info.json. Native HID convention, physical page appearance/inputs/recovery and memory/CPU soak remain untested.
- Logs /Volumes/Data/tmp/hidhogg-d200x-{model-iteration3,full-final,native-final,release}.log. Native crash red/remove-green/restore-red/final-green logs retained separately.

Source remains uncommitted on next/d200x-slice; no push, production launch, device queries/writes or real keyboard events. DX444–447 remain InProgress for owner hardware gates; DX05/06 features remain deferred.

## Owner first-use and physical-layout correction — 2026-10-23

Owner reports disabledConnect and suppliesfront-onD200Xreference. Approved correction: manualConnect addsmissingemptyconfiguration throughcanonicaledit/autosave, thenconnects. Alternative separateSetUpstep madefirstuseunclear. Startup usesconfigureIfNeededfalse andmustnotadd/queryanunconfigureddeck; errorblockersremainvisiblebesideConnect. This preserveslegacyupgradeinertness.

Frontcontrolsarephysicallytwo smallbuttonsleftofthreeknobs; earlierSide labels/placementswereincorrect. DisplaytitlesbecomeFrontbutton1/2; persistedside0/side1 andwire15/16 stayunchanged. Nativeflatcolour-blockillustrationadoptsmousepalette; knobselectionusesexistingfive-gestureinspectorinstead offifteenbuttonpanelsinsideartwork. No protocol/inputmappingchanges. Focusedmodel/setup/integrationgates andexistingbackgroundnative2/2 plusisolated320/600deckrendersplanned; no realhardwaretests.

Follow-up verification:36/36focusedpassed (20AppModel,10deckmodel,6setup), plus existingliteral wire15/16contract1/1. Backgroundnative2/2passed; isolated320/600rendersvisuallycheckedforlayoutandselection.320frontcaptionscanellipsize;600fitandfullaccessibilitylabelsremain. No click-driven hardware orUIinteractionproof. Signedfixedbuild0c34ade6203984c2fd657f181917ee3c290a7673b9bfdb81c896c2a79e90e321, strictsignaturepassed; executable5694560bytes,133inputprovenance. LogsData/tmp/hidhogg-d200x-{setup-focused,front-native,front-mapping,front-release}.log. Priorfull417gate retainedforpreviouscheckpoint; no fullsuiterepeatforboundedConnect/presentationfollowup.

## Approved deck settings-layout alignment — 2026-10-23

Ownerclarifiesstylemeanssurroundingsettingslayout, particularlymouseappselector. Approvedcompactnativeappselectorwithsearchablepopover/name+icon, mouse-likeoverview/cardspacing,15percentdeckwidthreductionandlargertilegapsbasedfrontreference. Boundaries: threeD200Xpresentationfiles only, no mouse/runtime/config/protocol changes; inlinecontrolsettingsretainedbecause nativeinspectorcrashed. Checklist: [x] selector/cardalignment; [x] smallergrid/widergaps; [x] backgroundnativewindow/renderverification; [x] signfixedbundle; [ ] ownervisualcheck.

Layoutfollow-upverified:exactly3presentationfileschangedagainst133-inputpreviousmanifest. Unifiedoverview/mousecard24ptspacing/760ptcontent; selectorcompactcard+configured-appname/iconsearchpopover+nativeappbundleimporter, metadataonlyconfiguredIDs. Noinstalledscan/runtime/model/schema/transportchanges. Deck630ptcap,gaps12pt. Backgroundnative2/2passedafterinitialsandboxbuildcachedenial/resolvedscopedescalation. Parentinspected320/600deckand980workspacecaptures; geometry/gapsvisible.320frontcaptionscanellipsize; cachedworkspaceheadingsshowvibrancy/overprintartifacts, sopixel/actualpopoverselection/importer/VoiceOveracceptanceremainsownercheck. No full/modelretakeforpresentation-onlyscope. LogData/tmp/hidhogg-d200x-layout-{native,release}.log.

## Application-context removal — approved 2026-10-23

The owner requested an icon-only minus-in-circle button beside both app selectors. Mouse removal was hidden inside the popover; deck removal was absent.

- [x] Approved visible action and confirmation before deleting overrides.
- [ ] Both selectors expose the action with tooltip and accessibility label; All apps is disabled.
- [ ] Deck removal uses canonical edit/autosave, returns to All apps, preserves other contexts/defaults/tiles.
- [ ] Focused removal/persistence tests and background native windows.
- [ ] Signed fixed bundle; owner dialog/pointer check.

Confirmation snapshots the selected bundle ID and override count; confirming after the selection changes must not remove another context. Removal affects only device bindings, never the installed application. No HID session restart, page redraw, protocol or schema change is required.


Application-context removal verified 2026-10-23: both selectors expose minus.circle with help/accessibility labels, disabled for All apps/noneditable state, confirmation and stale-selection guards. Deck removal flows through canonical edit/autosave, returns to All apps and preserves defaults/other apps/tiles. Focused removal/persistence/UIAlignment/D200XModel20/20; background native2/2; signed fixed dist/Hidhogg.app and strict signature passed. Build dfa4626fed9f49cc75bcf36b5b61752d95fe02a79b282e35b8cd4558ee9a9b9b;134-input manifest refreshed. No production launch or hardware operations. Owner pointer/dialog/Cancel checks pending. Source remains uncommitted/unpushed. TaskView446 update failed (task not found/update failed); sync pending. Logs /Volumes/Data/tmp/hidhogg-application-remove-{focused,native,release}.log.

## Approved dropdown-row removal placement — 2026-10-23

Owner accepted removal behavior and approved moving the minus.circle into every configured app row in both dropdowns, with no remove control for All apps. Separate sibling buttons preserve selection versus removal hit areas. Confirmation targets the clicked row, Cancel preserves current editing context, and deletion uses existing canonical model methods. No model/schema/device changes. Checklist: [ ] implementation; [ ] focused/background native gates; [ ] signed bundle; [ ] owner dropdown interaction check.


Dropdown-row removal checkpoint 2026-10-23: owner accepted previous removal behavior and approved placement inside each configured application row. Both selector views now expose sibling selection/minus.circle controls, no external minus and no minus for All apps. Pending row ID is pinned; confirmation checks membership/editability before selecting/removing it; Cancel preserves original selection. Stable outer confirmation uses existing popover-dismiss handoff. No model/schema/runtime/hardware changes. Focused20/20 and background native2/2 passed; signed dist/Hidhogg.app strict verification passed. Build 2e4fe94affff17cef3c0c99e9f908c68d9054100f60588c1e67c302f1861b553;134-input provenance refreshed. Actual dropdown/Cancel/destructive pointer interaction remains owner check. Uncommitted/unpushed; TaskView sync previously unavailable, no new task state claimed. Logs /Volumes/Data/tmp/hidhogg-remove-row-{focused,native,release}.log.

## Approved default window and mouse-control presentation — 2026-10-23

Owner approved1280×800 default window (prior980×680), minimum820×560 retained. Requested control order Scroll wheel, Thumb wheel, Back, Forward in both presentations; Scroll wheel replaces visible Vertical wheel wording only, persisted IDs unchanged. Checklist: [ ] source changes; [ ] background minimum/default native gate and default mouse render; [ ] signed bundle; [ ] owner launch-size check. Existing restored macOS window geometry may supersede the initial default; do not clear user preferences.


Window/control presentation checkpoint2026-10-23: default1280×800, minimum820×560 unchanged. Shared wide/compact control order Scroll wheel,Thumb wheel,Back,Forward; visible inspector/accessibility naming updated, persisted IDs/geometry unchanged. Native minimum/default2/2 passed with background non-key windows; parent visually reviewed /Volumes/Data/tmp/hidhogg-mouse-workspace-1280w.png and confirmed controls remain left of artwork in requested order. Capture has existing text/vibrancy artifacts; not pixel-accuracy proof. Signed fixed dist/Hidhogg.app strict signature passed. Build 7af6bc662a5d96cb26a0bd4ba931c1c2e2b414fc4c58976498cfbc23e2384f33;134-input provenance refreshed. Owner launch-size check pending; restored macOS geometry may override initial default. No real launch/HID operations. Source uncommitted/unpushed. Logs /Volumes/Data/tmp/hidhogg-window-size-{native,release}.log.

## Approved shared inspector improvement — 2026-10-23

Owner approved wider/resizable native mouse and D200X right inspectors, adaptive shortcut controls, and moving D200X settings out of the main page. Prior explicit-width/deck inspectors caused AppKit constraint loops; architecture review and bounded background native open/resize/reopen gates required before adoption. No device/config/protocol changes. Checklist: [ ] choose native attachment boundary; [ ] adaptive controls; [ ] mouse/deck inspector integration; [ ] background regression and actual width-change evidence; [ ] signed bundle; [ ] owner divider drag/control visibility acceptance.

Inspector decision checkpoint: use one inspector outside WorkspaceView NavigationSplitView with route-switched mouse/deck content; separate per-device visibility bindings, hidden for Settings. Flexible320/360/480 range on inspector content per Apple docs. Alternatives: repeated route-level attachments rejected as retaining prior constraint-loop boundary; native HSplitView fallback reserved if root probe fails. Responsive controls retain one active capture subtree; ordinary preset/manual controls use adaptive horizontal/vertical arrangements. Close-only identity reset requests existing D200X onDisappear cancellation; this path remains an assumption pending evidence. Source syntax checks passed; native verification pending.

Inspector root probe failed: first test helper compile needed NSView accessibilityIdentifier() call; preserved compile1 log. Next native run opened1280 but pane discovery found no identifier-matched rightmost direct view, before divider mutation; then820 test process exited signal5 with no explicit constraint exception text. This does not prove crash cause, and no resizability claim is established. Rejected shipping root .inspector probe; coordinated native HSplitView fallback within approved adjustable-panel scope. Failed run retained at /Volumes/Data/tmp/hidhogg-resizable-inspector-native-root-probe.log. Tester will use actual split pane geometry rather than SwiftUI AX identity in NSView tree.


Resizable inspector checkpoint2026-10-23: approved mouse/D200X right-panel work complete in source and signed bundle. One native HSplitView inside navigation detail, flexible main and right child320/360/480; route-specific visibility, Settings omits editor, tile/front/dial reselect opens editor. Mouse preset/manual adaptive row stacks at narrow width; capture/Cancel vertical single capture subtree both devices. Shared WorkspaceInspectorView fills standard background. Rejected root .inspector probe:1280 helper discovery failed then820 process signal5 (cause unproven), retained root-probe log. Final HSplitView native2/2 minimum820/default1280 passed; actual requested320/360/480 produced320/359/479 at1280 for mouse Back/deck key0/dial0HeldLeft,159-point delta. At820 mouse initial337/max request473; deck429. Focused20/20 passed. Initial test accessor compile error and sandbox denial corrected/preserved. Parent reviewed mouse320 full action labels and deck1280 right panel renders; native bitmap text artifacts remain elsewhere. Signed dist/Hidhogg.app strict signature passed, build 9bb0daca1af3810534228c7241f3d33b8ebc124f818c5632eeb468e3341c5061,135-input provenance refreshed. No model/schema/protocol/HID operations. Owner still check pointer divider drag, hide/show, reselect, recording/manual cancel on hide/route/close. D200X close-only identity resets rely on onDisappear cancellation; actual capture teardown not directly tested. Source uncommitted/unpushed. TaskView previously unavailable; no task completion claimed. Logs /Volumes/Data/tmp/hidhogg-resizable-inspector-{native,focused,release}.log.

## Approved narrower initial inspector — 2026-10-23

Owner confirmed resizable panels work, requested initial width matching second screenshot (~320points). Approved ideal width360→320 with min320/max480 retained, both devices. Checklist: [x] preferred width source change; [ ] actual initial native width gate at1280 plus minimum/resize/reopen; [ ] signed bundle; [ ] owner opening-width review. No device/runtime/config changes.

START320 preferred-width probe failed: untouched1280 mouse and first deck panel both480points, expected320±3;820 checks and later divider movement passed. HSplitView idealWidth is insufficient to establish start size. Retained failed log hidhogg-inspector-start320-preferred-width-probe.log; coordinated bounded native one-shot initial-divider adapter via ancestor split-pane lookup, no persistent preference/config changes or continuous width enforcement. Native rerun must keep initial-width assertions and adjustable range probes.

One-variable ideal321 probe also failed unchanged actual initial480 on both1280 panels. Rejected equal-min/ideal degeneracy hypothesis; failed log retained as hidhogg-inspector-start320-ideal321-probe.log. Proceed with bounded one-shot public NSSplitView initial position helper, not a continuous constraint. Keep actual initial320±3 and subsequent divider motion assertions unchanged.

One-shot initializer native iteration3 passed2/2: initial320 on both mouse/deck at820/1280, later320/359/479 resize probes and close/reopen passed. Source review then caught a reentrant scheduling race (task marker cleared before native layout, permitting second task); correcting helper before final gate. Adapter uses nearest trailing arranged pane/public bounds and divider setter, eight bounded readiness retries, cancellation on detach. No continuous resize enforcement. Hide/remount initializes320 again; slow initialization beyond bounded retries remains a limitation.


Initial inspector width checkpoint2026-10-23: owner confirmed adjustable panels work and approved starting narrower at320. Preferred320 and321 both measured480, retained failed probe logs; implemented WorkspaceInspectorInitialWidthAdapter one-shot public native NSSplitView trailing-pane ancestor lookup, bounded8×20ms readiness attempts and detach cancellation. Source review caught reentrant layout scheduling; corrected task marker lifetime and completion recheck. Final native2/2 passed: initial320 mouse/deck at820/1280, later320/359/479 width probes, resize and close/reopen. No focused/full repeat or live HID operations. Settings/control identity unchanged, range320–480; fresh panel mount starts320 again, later user drag unforced. Rare slow layout exceeding bounded retries remains limitation. Signed fixed dist/Hidhogg.app strict signature passed; build 22ae6f3c0b62d1491bdae2e6a192c20e0a4784cd93df0b9c31cd78e01ef70d0d,136-input provenance. Owner opening-width/pointer check pending; source uncommitted/unpushed. Logs /Volumes/Data/tmp/hidhogg-inspector-start320-{native,release}.log; source-only approval and final runtime evidence kept distinct.
