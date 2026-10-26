# D200X appearance and local automation implementation

Approved2026-10-23: brightness/static key images/host title styling; source-filtered tile notifications with replace/TTL/clear/dismiss/history; controls run configured scripts and local scripts invoke named actions or emit notifications. Pages/profiles/richer media actions/screensaver/telemetry remain later parity slices. Branch next/d200x-slice, baselinee2744ad; existing settings/deck follow-ups remain uncommitted.

## Checklist

- [x] bounded architecture review and interfaces
- [x] brightness transport source+fake tests authored (unrun)
- [x] strict additive domain/TOML with old-config compatibility
- [x] native bounded asset import and square/wide title rendering
- [x] notification prepare/write/commit store and fake-time tests
- [x] configured process runner, local Unix interface and CLI
- [x] model lifecycle/render/input/API integration
- [x] native per-control script/subscription/appearance editor
- [x] independent focused tests/review and background native gates
- [x] signed app+CLI package and source provenance
- [ ] owner manual device/script/CLI acceptance

## Decisions and alternatives

Use D200XBinding(kind disabled/shortcut/action) only for deck bindings; keep mouse ControlBinding unchanged. Store named ConfiguredExecutable definitions inside D200XConfiguration for this deck-only slice. Rejected parallel script-binding maps because they complicate explicit application Disabled versus inherited defaults. Configured argv is immutable on admission, executable and optional working directory absolute; no implicit shell or request-supplied executable. Explicit shell/interpreter executable can be configured by owner. One active process plus8queued, timeout1–60seconds, history100 metadata-only, output discarded; shutdown cancels owned work.

Local Unix socket only, per-user private directory0700/socket0600, UID peer check, bounded strict single-request JSON framing, existing request_id/protocol_version1 and nestedparams convention. Default temp per-user endpoint, optional explicit CLI --socket path. No remote listener, automatic app launch or untrusted notification-to-code path. No new dependency/process/runtime resurrection.

Image references SHA256.png relative assets beside active TOML; normalize PNG/JPEG with bounded input16MiB/pixel16M/thumbnail1024, metadata stripped. Preserve square196×196/wide196×98 existing deviceformat, contain fit. Host-rendered optional title8–48/color/placement; no firmwarefontcommand change. Missing asset falls back visibly. Assets copied, never mutate originals or delete arbitrary paths. Brightness optional25–100 desired preference; unset preserves current behavior, coalesced immediate updates+autosave, reconnect reapplies. Research samples25/60/100; no readback/Verified claim.

Notifications exact ASCII source IDs1–64, single-line text≤64characters/256bytes, optionalTTL1–86400,14tile overlays, history100; notification text never part of history or executable config. TTL starts after successful device commit. Failed display mutations do not become delivered. Capture notification ID for selection dismissal; stale clear/expiry cannot delete replacements. Configuration/lifecycle transitions clear overlays rather than replaying external text. Existing independentGETBASE cadence retained.

## Ownership

Parent owns Domain/codec/Package/AppModel/D200XModel and final composition; appearance executor owns assets/renderer/editor; transport executor owns brightnesswire/tests; notification executor owns pure store/tests; automation executor owns process runner/socket/CLI/tests/buildpackaging. Independent tester/reviewer after source freeze. Only parent edits .agents log/handoff. Agents do not launch actual app or operate real device/scripts/permissions. Test user fixtures/temporary files/fake runners only; physical acceptance owner.

## Verification contract

Old/new TOML and invalid field/path/ref tests; exact brightness bytes and stale-session checks; asset copy/validation/fallback/render updates; fake notification transaction/TTL/replacement/rollback/bounds; fake process queue/timeouts/stop; strict local wire validation/owner-only endpoint; model foreground binding resolution and lifecycle cancellation; background native820/1280 routing/editor/resize/reopen; strict signed fixedbundle and CLIhelp. Actual deviceappearance, brightness, script subprocesses and notificationCLI owner checks reported separately.


Parity implementation checkpoint2026-10-23 (in progress): shared D200X-specific action bindings/configDTOs, brightnesswire, bounded assetstore/renderer/editor, transactionalnotificationstore, configured runner+localUnixIPC/CLI, model+AppModel lifecycle integration authored. Isolated HidhoggAutomation build passed. Firstfocusedcompile found/fixed testfixture ControlBinding→D200XBinding, missingtry, duplicateassetdims, missingpickerreturn; nextgate compilegreen but2assetimport tests fail unsafePath onnormaltempfolder, diagnosis delegated. Newconfig7tests/modelinherit1 and notificationstore15+SwiftTesting15 passed inpartialgate; not a finalpass. Independentreview P1subscriptionorientation, expiringduringwrite/historyeviction/saturation, immutableinputID/script capture, and transportcancellation fixedin source; re-reviewclosedP1afteradditionalrawexpiry/authorizationchecks. P2postwriteTTLreauthorization removed torespectsuccessfultransport; historynowmetadataalloutcomes/controlIDs. Workerstoretests expanded slowcommit/staleexpiry. No actualapp/device/scripts/permissionoperations. Testerdepthcoordinatorgates andfull/native/release stillpending. Code notready for owner untilgates pass. Interfaces/decisions checklist docs/d200x-parity-implementation.md.

## Verification progress

Focused final gate passed69XCTest +15SwiftTesting cases (84total), including7configuration and6modelintegration cases. Tests cover matchedsource routing+clear, disconnectedfailure/unhandledreceipts, heldbaselinewrite without cancellation, and fake configured-action dispatch. Assetdirectory alias diagnosis reproduced Foundation mapping /private/var back to /var; POSIX realpath+raw path assembly nowpasses fixture while rejectingassetleaf symlinks. Reviews closedP1 routing, lateexpiry/restoration, saturation/historydeadline, immutablepresscapture, startedwritecancel and prewriteauthorization defects; regressioncases added. Fullordinary/native/signing/CLI gates pending.

TaskView reconciliation: listendpoint omittedknownrecords; directget confirmedDX-05 task448 and parent443 in project5/list66. DX-05 nowInProgress; approvedlocalautomation newtaskDX-07 #454 InProgress. ImmutableIDsretained. Script runner deliberately uses emptyenvironment and absolute configuredpaths; no inheritedenvironment data is read, no stdout/stderr capture. Owner can explicitlyconfigure interpreter plus arguments; timeout/cancel owns directchild only, descendanttermination notclaimed. Existinglocalsocket failsclosed instead of unlinkingunknown/stale endpoints; manualstale cleanup mayberequired aftercrash. Thesecompatibility limits needownerreview.

Full baseline gate passed279XCTest executed (2explicitnative skips) +201SwiftTesting;478ordinarypasses, then explicitnative2/2. Noactualuserapp/HID/configuredscript/permissionposts. IsolatedsyntheticUnixsockettests do create temporarylocal endpointswithfakehandlers; these are notproductionendpointacceptance. Firstsignedapp+CLI buildpassed, finalpreviewcompletion stillpending: decktilepreviewmust reflect importedimages/showTitle/style/overlays, ratherthan plainlabels. Previewwill reuseexact196px renderer offmainactor andretain smallper-tile images; no sourceimageIO inbody. Targetedappearance+nativegates afterthisUIcompletion; no fullrepeatunlessnewfailure. Manualvalidation checklist willseparate actualhardware/script/CLI behavior.


Parity selected-slice ready for owner review2026-10-23. DX-05 appearance and DX-07 local notifications/scripts implemented; TaskView448/454 InProgress (owner physical gates remain). Signed fixed dist/Hidhogg.app +dist/hidhoggctl, strict signatures and CLI --help passed. Build 1d3139b217262febb3e5b385dd08de734ea99b888d5114ccb9ad6cbe5a8a4860, 159source inputs, app 7312368bytes, CLI 901104bytes. Sourceuncommitted aftere2744ad, no push. Fullbaseline478ordinary tests passed (279XCTest incl2native skips +201SwiftTesting); finalpreviewfocused14+native2/2; finalassetreadbound9/9. Fullnotrepeatedafterboundedpreview/assetchanges. Parentinspected defaultdeck/settings snapshots; nativecachevibrancy artifacts remain so no pixelperfectclaim. Fakeprocess/device guards, isolatedtemporaryUnixsocket tests only; no actualuserapp/HID/configuredscript/permissionprompt tested.

Features: optionalcoalescedbrightness25–100; copiedboundedPNG/JPEG assets+host title styles onstandard/widekeys; sharedsmallasyncpreview; exactsource tileoverlays withcommit-timeTTL/replace/clear/captureddismiss; boundedmetadatahistory outcomes/control/eventIDs; configuredabsolute executable argv andtimeouts, queue/history; ownerlocalUnixAPI +signedCLI actionsinvoke/notifications/status/history. Mouse ControlBinding unchanged; D200X-specific scriptbinding type andstrict optionalTOMLfields keepoldconfigdecoding. SingleD200XModel remainsdisplaywriter. Criticalreview corrections: sourcemaptranspose, monotonicrawexpiry/catchup/saturation/historyeviction, capturedscript/notification/config identity, prewriteTTLauthorization, no normalcancellationofstartedwrites, publicreceiptoutcomes/IDs; regressiontests passed. Canonicalassetparent realpathfix handlesmacOSvaralias and rejectsassetleafsymlinks; storedPNGdimensionbound1024beforedecode.

Knownlimits: no fullStudio parityclaim; pages/profiles/media/textmulti-actions/widestatus/screensaver/encoderresearchremainroadmap. Script environmentempty, directchild cancellationonly, no capturedoutput; staleexistingUnixendpoint failsclosed requiresownerreview/manualcleanup. Ownerchecks docs/d200x-parity-owner-checks.md; implementationdecisions docs/d200x-parity-implementation.md. Nextaction ownerreopensbundle andtestsbrightness/importedimagepersist/scriptfromkey+CLI/notificationTTL+replace+clear+dismiss/reconnect+restart. Do notmarkmilestoneDone orsendcompletionnotification beforeownergate.

Finalverification scopedsummary: fullbaseline478ordinarypasses; previewfollowup14 andnative2; finalstoredassetguard9. App/CLIstrictsignatures andCLIhelppassed onfinalartifacts. Allimplementationcheckschecked; owneracceptanceonlyopen. TaskView448/454 notesupdatedandremainInProgress. Branch next/d200x-slice uncommitted/no push. [Ownerchecklist](d200x-parity-owner-checks.md).

Final scope audit: explorer verified branch next/d200x-slice at e2744ad, expected implementation filenames and159-input provenance. Parent accounts permission/low-battery edits as preceding owner-accepted settings work, unbranding as prior approved visual work, and docs/build script as handoff/packaging. Pre-work status already listed excluded local environment/editor/cache/probe artifacts; none were read, staged, modified or deleted. Source remains uncommitted and unpushed. Owner review is next.
