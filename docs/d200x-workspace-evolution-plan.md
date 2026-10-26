# D200X workspace evolution — DX-08

2026-10-23. **Approved scope implemented and independently verified offline; ready for owner checks.**

TaskView Personal / HIDhogg project 5, list 66, task **470 (DX-08)** is In Progress. Physical acceptance is a separate final gate.

## Confirmed requirements

- Brightness must allow 1–100 throughout the UI, domain/configuration validation and transport. The previous 25 minimum represented tested research samples, not an established device limit.
- Put device-wide settings below the deck in the central pane. Keep the right inspector for the selected tile/control.
- Move script/action management into a dedicated Actions page, consistent with the mockup. The selected-control inspector retains action assignment.
- Add a dedicated Notifications page with integrated listening, topic filtering and reaction/delivery details.
- Owner confirmed the listener uses the existing local HidHogg API, not an external broker.
- Owner confirmed no integrations depend on the current `source` naming. Use `topic` consistently in CLI, API, configuration and UI, with no `source` alias or notification-naming migration layer.
- Topic filters use only `*`, matching any sequence of characters (including dots); exact filters remain exact and matching is case-sensitive. `build.*` matches both `build.finished` and `build.project.finished`; `*` matches all topics. Published topics are concrete names.
- Owner confirmed automatic app-specific profiles change both appearance and actions, with default fallback for unmapped apps. Existing per-app action overrides are not yet full profiles.
- Physical multi-page deck support is deferred.
- Reusable tile presets contain text/image/style and optionally actions; support copying and sharing.
- Add horizontal Left/Center/Right title alignment alongside existing vertical Top/Center/Bottom placement.

## Proposed navigation and ownership

```text
Devices             Main device pane             Selected-control inspector
  MX Master 3S      App/profile selector           Appearance / alignment
  D200X             Deck preview                  Action assignment
Actions             Device settings below deck    Topic subscriptions
Tile presets                                       Apply/save preset
Notifications
Settings
```

Actions manages reusable action definitions centrally. Notifications shows receipt, matched device/profile/control, reaction and outcome; routing remains configured on the control/profile. The live listener can show incoming text in a bounded volatile buffer while enabled; persistent diagnostics/history remain metadata-only. Include an in-page test publisher using the same validated local notification path. Do not turn notification content into executable instructions or silently add automatic action execution.

## Approved conventions

- Full D200X profiles have appearance, bindings and topic subscriptions. Editing selection is distinct from the active runtime profile. Existing mouse application overrides remain supported.
- Presets apply as independent copies by default. Copy/paste and versioned self-contained import/export include copied image assets; actions are optional and reviewed on import. Import never runs an action or silently overwrites an existing definition.
- Keep one private local endpoint with a CLI wrapper, so both entry points use the same validation and routing. The notification command uses `--topic`, the API parameter is `topic`, and saved subscription fields use topic terminology. No broker-specific wildcard syntax or legacy `source` alias.
- Keep native SwiftUI components and the current stable native split-view workspace; avoid reintroducing the crashing inspector bridge. No background UI polling.

## Recording and display regression

Reviewed the owner-provided 4.574-second recording, 1062×556, from 23 October 2026 at 20:37. A 2-fps contact sheet is at `/Volumes/Data/tmp/hidhogg-tile-size-contact.png`. The Title size slider changes while the deck grid visibly shrinks/reflows. Expected: fixed tile/deck geometry, with only text rasterization changing. Root cause is not yet proven.

After approval, first create a red-capable background native layout regression measuring the deck frame during title-size updates and async preview transitions. Test initial loading, repeated slider edits and square/wide tiles. Inspect preview fallback/image intrinsic sizing only after the regression reproduces the symptom; preserve hit areas and selection. Do not claim the recording establishes a particular source-level cause.

The pre-fix background native regression ran on 2026-10-23: one test, 26 geometry assertion failures. At a fixed 320-point host width, the grid changed from 276×163 to 270×162 bitmap pixels as the fallback became a rendered image; relative cell positions also changed. Loaded-state size edits were stable within tolerance, so this proves a loading-related geometry defect rather than every slider transient seen in the recording. Red log: `/Volumes/Data/tmp/hidhogg-evolution-layout-red.log`. The authorized correction gives tiles a stable shape base and overlays preview content; verification is in progress.

## Implementation sequence and gates

1. Reproduce/fix layout instability; brightness 1–100; horizontal alignment; move device settings below deck. Focused domain/codec/render and background native tests.
2. Dedicated Actions and Notifications pages with native navigation/history and live bounded local listener. Verify no automatic execution or permission prompts while browsing.
3. Full automatic app profiles with migration from existing overrides and separate editing/runtime selection. Test foreground changes, inactive-profile edits, overlay lifecycle and reconnect.
4. Portable tile preset library, copy/paste and reviewed optional-action import. Bound asset/file decoding and preserve originals.
5. Signed app/CLI, provenance, decisions and owner checklist; no physical device writes, actual configured scripts, real clipboard reads or permission changes by agents.

## Checklist

- [x] review current implementation and mockup conventions
- [x] inspect the supplied recording
- [x] confirm local-only notification listening
- [x] confirm full appearance/action app profiles
- [x] owner approves the combined implementation boundary and proposed conventions
- [x] reconcile TaskView tasks and freeze module interfaces
- [x] implement and independently verify selected slices
- [ ] owner acceptance

## Implementation decisions

| Decision | Alternative considered | Reason |
|---|---|---|
| Add sparse appearance/topic overrides alongside existing per-app binding maps | Replace all configuration with a new profile hierarchy | Existing bindings retain their representation; one resolver combines all three aspects with default fallback. |
| Keep the existing D200X action catalog; manage it on Actions | Move it to a new root configuration table | D200X is the current consumer; changing storage adds migration without changing functionality. |
| One private local endpoint with CLI and in-app publisher | External broker or separate listener endpoint | The approved requirement is local receipt; validation/routing stay shared. |
| Listener captures at most 100 in-memory messages while enabled | Persist message text | Text is useful for live inspection; disabling listening clears it. Metadata history remains separate. |
| Presets are independent copies with a versioned JSON package and embedded PNG | Live-linked templates or external image paths | Copies are predictable, and a package can be shared without machine-specific paths. Optional actions are reviewed and never run on import. Conflicting action IDs cannot overwrite existing definitions when applied. |
| Serialize rendered page writes across profile/notification changes | Cancel a started display transfer | A completed transfer followed by the newest profile preserves transport integrity. |

Horizontal alignment uses Core Text paragraph alignment, shared by previews and device images. API basis: [Apple CTParagraphStyleSpecifier.alignment](https://developer.apple.com/documentation/coretext/ctparagraphstylespecifier/alignment).

## Active checklist

- [x] EV-01: layout regression/fix, brightness 1–100, title alignment, device settings below deck
- [x] EV-02: topic-only contract/wildcards, Actions and Notifications pages, bounded live listener
- [x] EV-03: automatic appearance/action/topic profiles with independent editor selection
- [x] EV-04: portable copied presets and reviewed optional-action import
- [x] EV-05: independent offline tests, background native windows, signed package and owner checklist

## Approved usability follow-up — 2026-10-23

Owner reports notification delivery and configured scripts working. Approved: remove brightness Desired/Sent/Verified rows; compact notification topic/text and profile/control rows with copyable monospace topics, clear-one/clear-active buttons and tile navigation; selectively copy appearance properties to other tiles within the editing profile, preserving labels/images/actions; word-preserving notification auto-fit; inner Actions script list/New button with editor on right; clear script history and record device profile/control versus local API origin, with tile navigation. Existing un-attributed records display Unknown origin. Offline fake tests and background windows remain the verification boundary.

## Approved editor refinement — 2026-10-24

Knob UI follow-up approved: replace the gesture dropdown with visible Press/Rotate Left/Rotate Right buttons, omit Hold+Rotate controls. This is presentation/selection only: existing held bindings and transport support are preserved; a legacy held selection opens the corresponding ordinary rotation editor. No automatic configuration mutation.

Assignment refinement is ready in signed build `cb88b450a46a`: short Left/Right buttons under a Rotate label; direct Record Shortcut and searchable Choose Action controls; current assignment with Clear only when non-disabled; app-specific Use All Apps Default remains separate. Opening/cancelling a chooser preserves the existing assignment. Clear writes an explicit disabled binding; Use All Apps Default removes the override. Capture and chooser context guards reject stale commits after control/profile/session changes, loss of editability, or action removal.

The targeted inheritance regression passed 1/1, followed by final background native window checks 2/2 at 820×560 and 1280×800. Initial captures caught the missed short-label change; final source/captures confirm Rotate/Left/Right, with the narrow bitmap crop limiting visual proof at the inspector edge. No automated chooser selection/cancellation or keyboard capture was exercised; those remain owner interaction checks. Broad suite not repeated for the two-view delta. Strict app/CLI signatures, CLI help and 188 provenance inputs verified. Logs: `/Volumes/Data/tmp/hidhogg-direct-assignment-{focused,native-final,release-final}.log`.

Ready for owner check in signed build `57231171afe7`: both existing background workspace window cases passed at 820×560 and 1280×800, including the legacy held-selection path. Only `D200XControlInspectorView.swift` changed from the preceding native-action package. Strict app/CLI signatures verified; the broad suite was not repeated for this UI-only correction. Logs: `/Volumes/Data/tmp/hidhogg-knob-gestures-{native,release}.log`. Pointer/keyboard and real device interaction remain owner checks.

Owner approved a compact Notifications toolbar with test publisher popover and expanded history occupying the main pane, plus an independent Tile Presets list/editor. Presets must be editable without selecting a device tile, including text, background/title color, font/alignment, image and optional action; preserve portable copied assets/actions and explicit apply-as-copy semantics. Owner subsequently approved the complete starter action catalog as **DX-10 / TaskView476**: media/volume, Bell/Play Sound, openers, static deck notification, reusable shortcut and retained custom executable. Speak Text is excluded. No notification payload interpolation is authorized; DX-09 remains deferred.

Checklist: [x] compact notifications/history; [x] independent preset draft/editor/save/image handling; [x] action catalog selection; [x] focused/full/background native gates; [x] signed package and owner checklist. Owner physical/interactive acceptance remains open.

Current package is **715d2cc8ebfcce34e32fb407ace548e0e9274e21fd9a4f2011a5373f121bd1f8**, signed on 24 October 2026, including the complete DX-10 core set. Compact Notifications now has one bounded scrolling history list, visible by default, with Test in a popover. Independent preset drafts are guarded against duplicate/stale/deleted records and late image completion; cancelling after an image import may leave an unreferenced content-addressed asset, while the configuration remains unchanged until Save. Native definitions can be embedded as immutable preset copies in package version 2; version 1 executable presets remain supported.

Verification: focused 29 XCTest + 15 Swift Testing passed; full retry 319 XCTest executed with 3 intentional native skips + 212 Swift Testing passed (528 ordinary passes). The first full run hit an unchanged Logitech thumbwheel assertion; three exact isolated runs and the full retry passed. Its cause is not proven; no Logitech source/test was edited. Three standard background native cases passed, followed by one new native-only case rendering all nine action kinds at 320×560. That final test-only addition was not in the earlier ordinary count; it passed separately. Non-key bitmap captures have known vibrancy/Picker artifacts and do not establish pixel-perfect foreground appearance.

Logs: `/Volumes/Data/tmp/hidhogg-dx10-{focused-guards,full,full-retry,native,native-action-editor,release}.log` and `thumbwheel-isolated-{1,2,3}.log`. App/CLI strict signatures and CLI help checked; source remains uncommitted/not pushed. [Native action decisions and manual boundaries](native-action-catalog-proposal.md). The checks used fakes, with no real media, sound, volume, openers, scripts, device writes, clipboard, production endpoint or prompts.

UI/history refinement is implemented and offline verified, ready for owner checks. Deferred **DX-09 / TaskView475** evaluates safe notification data passing into actions: literal argv, structured stdin and restricted templates. Notification text stays data; no shell interpolation or automatic notification execution is introduced by this follow-up. The spike requires a decision record and isolated adversarial fixtures before separate implementation approval.

Usability package: signed app/CLI build **557d230d712f58703c4905de486c33229ef052168a1743e5987cc9ce78f20943**. Focused 38 XCTest + 6 Swift Testing passed; full 303 XCTest with 3 intentional native skips + 203 Swift Testing passed (503 ordinary). Final background native class passed 3/3 at 820×560 and 1280×800. The inspector check now uses the existing concrete workspace marker, after the old width heuristic mistook the inner Actions split for an inspector. Only that test helper changed after the full ordinary suite; the final native run compiled and exercised it. Logs: `/Volumes/Data/tmp/hidhogg-dx08-usability-{focused-final,full,native-marker,release}.log`.

History clearing preserves running/queued executions and revision-gates asynchronous reads. Clear Active uses one queued transaction/page write. Trigger provenance is recorded at admission; external requests cannot supply device attribution. Selective copying is restricted to style fields in the current editing profile. Notifications treat the configured tile font size as an upper bound, shrink to 8 when needed, wrap on whitespace, and ellipsize unbroken oversized words/overflow. Font measurement uses [Apple Core Text typographic bounds](https://developer.apple.com/documentation/coretext/ctlinegettypographicbounds(_:_:_:_:)).

Strict signatures and CLI help verified. No live device writes, actual configured process, clipboard access, production endpoint, prompts or production app launch by agents. New visual/pointer/physical checks remain in the owner checklist; source remains uncommitted and not pushed.

## Verified package — 2026-10-23

Signed `dist/Hidhogg.app` and `dist/hidhoggctl`, build **5f0b86fc747c0296900b09a8bb45249334cec00fa24106e7f8d3d964374bdde7**. App executable 8,043,968 bytes; CLI 998,048 bytes. The ignored `dist/build-info.json` records 168 source/resource/test hashes and test-log hashes; all inputs matched after packaging. Source remains uncommitted after `e2744ad` on `next/d200x-slice`; no push.

| Gate | Result |
|---|---|
| Focused offline checks | 52 XCTest + 15 Swift Testing passed |
| Full ordinary suite | 297 XCTest executed, 3 intentional native skips, 0 failures; 201 Swift Testing passed — 495 ordinary passes |
| Background native windows | 3/3 passed: geometry regression plus 820×560 and 1280×800 workspaces, including the three new routes |
| Native side effects | Fake process/binding/permission/input guards clear; windows remained non-key |
| Packaging | App and CLI strict signatures verified; CLI `--help` advertises `--topic` |

Logs are `/Volumes/Data/tmp/hidhogg-evolution-{focused,full,native,release}.log`, with red/green geometry logs beside them. The first focused attempt hit restricted-shell cache access; the authorized scoped retry passed without deleting or modifying cache permissions. SwiftPM reports the existing native-build-system deprecation warning.

Further review corrections: strict preset codecs reject nested unknown fields; notification admission synchronously captures foreground profile/topics; inactive-profile edits and preset-library changes preserve active overlays; unmapped applications share the default profile; started writes complete before the latest profile is applied. Fake integration tests cover these cases.

The native checks navigate through model state, not pointer/keyboard automation. Actual hardware brightness, physical rendering, real foreground app behavior, configured executables, clipboard operations and production endpoint delivery remain owner checks. No production app was launched by agents. [Manual checklist](d200x-parity-owner-checks.md).

## Action chooser search regression — 24 October 2026

Owner confirmed the knob labels, but reported that interacting with Choose Action search dismisses the popup. The previous two native window checks exercised rendering, not search focus or typing. Two bounded background attempts could not reach the focus-dismissal symptom: the inspector button and SwiftUI search field were unavailable through the passive host’s native view/accessibility trees. A test-only popover opened successfully, but no search focus or typing was exercised. These are harness limitations, not evidence against the owner report. Logs: `/Volumes/Data/tmp/hidhogg-chooser-search-repro.log` and `/Volumes/Data/tmp/hidhogg-chooser-search-popover.log`. Incomplete failing experiments were removed.

Defensive correction: replace the chooser’s navigation-bar `.searchable` and navigation wrapper with an inline labeled search field above the existing filtered list, in a stable 340×340 popup. Matching by action ID/type and explicit row selection remain; parent control/app/session commit guards and cancellation remain unchanged. The exact original cause is unproven. Signed app/CLI build `723315930d512350d562d28ab1a889a9750e57ab1130859e48c15bc4ca1d80bb` passed strict signatures and CLI help. Combined frozen-source checks passed 3/3: two native workspace sizes and the inheritance regression. Log: `/Volumes/Data/tmp/hidhogg-chooser-search-final-verification.log`; release: `/Volumes/Data/tmp/hidhogg-chooser-inline-release.log`. Provenance verifies 188 inputs. No broader-suite repeat or live effects. Owner must retry clicking, typing, selection and cancellation; these interactions are not automatically verified.

## Wide title scale and dial brightness — 24 October 2026

Owner accepted inline action search and reported native media controls functional. Owner approved equal apparent font sizing on wide/normal tiles. The wide raster remains196×98; title rendering now uses shared logical196px height before text-only scaling, preserving image geometry. Rendered regression and packaging pending; physical scale remains owner verification.

Owner reports every dial, including unassigned rotation, appears to reset brightness to100%. Source inspection finds brightness writes only at connection/configuration changes, not the ordinary unassigned input path. Device-side cause is plausible but unproven; no actual device trace captured. Proposed optional mitigation is bounded/coalesced reapplication of an explicit saved override after rotation; owner approved this bounded workaround on24October2026. Implementation and fake-session verification are in progress. Possible brief brightness flash was disclosed; the original device-side cause remains unproven. No guessed device commands or brightness readback added.

Approved brightness implementation uses existing150ms coalescing only for accepted mapped dial rotation with an explicit saved override; key/dial press and release do not trigger it. Initial brightness application now occurs when connected status is accepted, avoiding the fake-session-proven connect/event ordering gap. Delayed writes recheck delivery eligibility immediately before sending, covering spontaneous disconnect without epoch change.

- [x] owner approves wide-font correction
- [x] owner approves optional dial-brightness workaround
- [x] implement bounded renderer/model changes and fake/raster regressions
- [x] final focused checks, signed package and provenance
- [ ] owner verifies physical wide-font scale and brightness after turning

Final24/24 passed: appearance10, dial brightness5, parity integration9. Log `/Volumes/Data/tmp/hidhogg-wide-title-regression-final.log`; initial test import failure and brightness ordering regression retained in earlier logs. Font comparison has no pre-fix red run; final normal/notification glyph bounds and unchanged non-title image pixels are verified. Signed app/CLI build `2a5d55bb24e13c5b34216212b85cabe8c9e48aa82be593665962c469464764e4`; strict signatures/help and189 source inputs verified. Release `/Volumes/Data/tmp/hidhogg-wide-font-dial-brightness-release-final.log`. No live device/app/scripts/platform effects, full-suite repeat, commit or push.

## Retained connection sleep trial — 26 October 2026

Owner approved a narrowly scoped physical trial: on Mac sleep pause GETBASE maintenance and send brightness0 while retaining the D200X handle. On wake resume maintenance and restore the saved brightness (100 fallback when unset). The earlier100/10/10s idle policy, lock/screensaver behaviour and wide-tile physical calibration remain proposed separately; this trial does not implement them. Whether0 remains black through device screensaver entry is unknown and is the owner check.

- [x] owner approves pause/zero trial without deliberate disconnect
- [x] implement session pause/resume with pending-query/deadline invalidation
- [x] implement ordered model sleep/wake and explicit-disconnect safety
- [x] independent fake session/transport checks, signed package and provenance
- [ ] owner tests sleep/wake physical display

Protect the26October Logitech recovery checkpoint and all unrelated dirty changes. No live device, production app, real scripts, configured endpoint or permission changes during agent verification. MacOS can still invalidate USB handles externally; genuine transport loss remains recoverable rather than hidden.

Session layer now has explicit keep-awake pause/resume; initial handshake and genuine read-failure handling remain. Pause cancels only maintenance/deadline state and retains reader/handle. Transport brightness accepts0…100 while saved preference validation stays1…100. Fake tests authored; independent execution pending. An already-issued GETBASE cannot be retracted; same-generation identity replies carry no request correlation ID, so per-request reply attribution is not claimed.

Model layer now keeps system sleep separate from restart suspension, blocks input/action/render delivery during power transitions, drains started device writes without cancellation, and serializes pause→0 /resume→saved-brightness. Wake restores100 when no override exists without saving that fallback. Explicit disconnect invalidates pending transitions and closes only after owned work completes. True lost handles reconnect on wake. Wake brightness reconciles configuration edits made during an in-flight write; stale transitions cannot overwrite status.

Initial focused gate had59XCTest cases with2assertions in a fixture setup and22SwiftTesting cases with1independent clock-race failure; no finalgreen claimed yet. The sleep-during-connect fixture now waits for actual fake session entry rather than the model’s immediate connecting label. Independent pause/resume clock diagnosis and final rerun remain in progress. Initial log `/Volumes/Data/tmp/hidhogg-retained-sleep-focused-2026-10-26.log`.

Final gate:59XCTest+29SwiftTesting=88unique tests passed, covering allUlanzi transport/session/page/codec suites plus model/connect/sleep/dial/parity/wake. Log `/Volumes/Data/tmp/hidhogg-retained-sleep-final2-2026-10-26.log`. Narrow7+1 and exactresume1 are repeated evidence, not additionaltests. Earlierfailures resolved by explicit fake-connect entry and cancelled-clock-sleeper drain barriers; no productionfix was needed for those fixturefailures. Independent source audit found no scoped defect.

Signed app/CLI build `b316e9c095828b6e97df581cbadbc513d831cee0ed10a163067ad7e8d6cc5a0d`, strictsignatures/help and196sourceinputs verified. Release `/Volumes/Data/tmp/hidhogg-retained-sleep-release-20261026.log`. Test-only fixture changes followed release; production sources stayed frozen. No productionapp/HID/effects/fullpackage campaign/commit/push. OS sleep-notification timing and whether0staysblack during screensaver are ownerchecks; no guarantee of hardwareacceptance.

## Wide title horizontal calibration — 26 October 2026

Owner reports physical wide text height is correct but width is excessive; app preview looks correct. Owner approved a20%horizontal text reduction on physical output only. Keep vertical font scale, alignment anchors, wrapping, bitmap dimensions, images, ordinary tiles and preview unchanged. Renderer target selection separates device compensation from preview rendering. This is an empirical calibration trial, not a measured physical-display aspect ratio.

- [x] owner approves initial0.8horizontal text factor
- [x] implement device-only title transform and preview target
- [x] rendered-pixel regression, signed package and provenance
- [ ] owner verifies physical text proportions

Ready for owner calibration: signed app/CLI `03ca0bb45c4895840a1aaa49e9b8e96234630c7cbfb3dbffca2e467359fcf711`; strictsignatures/help and196inputs verified. Focused16/16passed (appearance11,workspaceevolution5). Pixelregression covers normal/notification text at all3alignment anchors, widthratio0.8±0.04 and unchangedheight,196×98dimensions, identicalsquare/image-only outputs. Previewexplicitly selects.preview; pagedefault.device. Staticindependentaudit foundno defect. Logs `/Volumes/Data/tmp/hidhogg-wide-title-calibration-2026-10-26.log` and `/Volumes/Data/tmp/hidhogg-wide-horizontal-release-20261026.log`. No nativewindow/fullpackage/liveHID/productionapp/commit/push. Factor0.8is empirical, physicalacceptancepending.

## Higher resolution wide raster trial — 26 October 2026

Owner approved trying458×196devicewide output after official UlanziSDK documented the D200X encoder full display region at458×196: https://github.com/UlanziTechnology/UlanziDeckPlugin-SDK/blob/main/manifest.md#d200x-encoder-layout . This is vendor canvas evidence, not yet proof that the existing wide-key image path maps1:1 to those pixels. Prior392×196proposal was not an officialnative resolution.

Preserve acceptedtextproportions/alignment/layout and196×98preview. Render the existinglogical196×98scene directly into458×196devicewide CGContext with scaledcoordinates; retain the acceptedtitle0.8horizontal calibration. Avoid resizing a low-resolution intermediate. Squaretiles andlifecycle unchanged.

- [x] owner approves458×196trial
- [x] implement devicewide bitmapresolution only
- [x] renderedpixel/pagechecks, signedpackage/provenance
- [x] owner reports physicalwide rendering looks much better

Ready for ownertrial: signed app/CLI `3a7adfa11f7b665f0c9cc8c3e9bb9792a0596db3015c8b9370dfa39c9562278d`; strictsignatures/help and196inputs verified.18focused checks passed:appearance11,workspaceevolution5,page2. Outputdevice458×196,preview196×98; glyphheight/alignment, acceptedlogicalwidthcalibration, square rendering, imageplacement and page-slot equality checked. Tests resamplepreview only for geometrycomparison; production directly draws text into the higher-resolution context. Pixelspace x/ytitle ratio is about0.935aftertheexistinglogical0.8calibration, preserving the prior layout under the assumed458×196 displaymapping.

Log `/Volumes/Data/tmp/hidhogg-wide-native-raster-2026-10-26-3.log`; release `/Volumes/Data/tmp/hidhogg-wide-458-release-20261026.log`. Initialtest-onlycompile/staledimension assertions corrected; no productionchange needed afterrelease. Indep sourceaudit foundno defect; physicalmapping/AAquality unverified. No liveHID/app/nativewindow/fullpackage/commit/push.

Owner acceptance26October2026: after build3a7adfa11f7b, owner reports wide rendering looks a lot better. Retain458×196devicewide raster andacceptedlogical layout. This accepts the visual improvement, not proof of1:1firmwaremapping or unrelatedsleep/idle/cataloggates.

## Lossless executable arguments — 26 October 2026

Check-in review found validliteral argv values were changed by the editor newline join/split representation: oneemptyargumentbecamenone, embeddednewlinebecamemultiplearguments, evenaftertimeout-onlyedits. Owner approved separate Add/Remove argumentrows androundtripregression. Eachrowpreserves an exactString with stableephemeralidentity; empty andmultilinevalues remainvalid. Keep64argument andexistingbytebounds, executablevalidation/runtime/schema unchanged. No configuredprocesses oractualuserconfiguration are used inverification.

- [x] owner approves boundededitorfix
- [x] implement losslessrowdraft/editor andregression
- [x] independent review, finaloffline/nativegates andsignedpackage
- [ ] refreshprovenance/docs/tracker andstageexplicitfiles

Argumentfixready26October2026: stableUUIDrows preserveliteralargv; validation/save use rawrowprojection. Independentreviewclosed originalblocker. Focused10passed; finalfull345XCTestincluding5intentionalnative skips +221SwiftTesting passed (561ordinary); explicitnative5/5passed, totaling566uniquechecks. New320×560nativefixture renders empty/multiline/normal rows without invokingactions. Signed873e84a8bb590aa1f887da82754ecc9dc8aa2c3a3b7d90ed78f54708813346bc, strictsignatures/help/198sourcehashesverified. Logs /Volumes/Data/tmp/hidhogg-argv-fix-full-2026-10-26.log, hidhogg-argv-fix-native-2026-10-26.log andhidhogg-checkin-argv-release-20261026.log. No realapp/HID/process/permission/platformeffects, commit orpush. Check-in preparation/stagingrecord: docs/checkin-preparation.md.
