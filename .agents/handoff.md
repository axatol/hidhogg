# Hidhogg v2 handoff

Updated: 2026-10-18, Australia/Brisbane.

## Goal and current checkpoint

Complete the approved pure-Swift macOS app with one app-owned runtime/device, Swift CLI, and full button GUI (appearance, actions, notification sources); fully test features/edges, run native macOS app with simulated D200X before final acceptance, commit between tasks. No Apple Simulator macOS target. Branch v2; accepted HEAD 2418f54c6c70782936f72c23e26b8e19f00326fc. Nine of twelve migration tasks accepted. Overall goal active and incomplete.

TaskView Personal org2/project5/list49 is authoritative. Direct IDs: P01 121, C01 122, C02 123, D01 124, D02 125, R01 126, R02 128, I01 130, U01 132, U02 134, V01 136, X01 138. Use direct get_task; list_tasks omits known records. Never print raw task results (owner PII); extract only verified scope/status/note. I01/U01 marked complete on 2026-10-18; U02 in progress. Older detailed decisions/history are in .agents/log.md and docs/v2-plan.md.

## Accepted commits and evidence

- R02: 620b5ece492c6389ce26263101850d45d42bbd06 (earlier accepted foundations remain in history).
- I01: d714dfefae7c0bae7d1592018ab857b0793c59f1, exactly17 Core IPC/client/server/discovery/CLI/test paths.
- U01: 2418f54c6c70782936f72c23e26b8e19f00326fc, exactly9 app/project/test paths, Swift runtime in app process.
- Frozen Core owner and independent suites passed205/205, focused IPC45/45. Independent report /Volumes/Data/tmp/hidhogg-v2-no-lock-independent-20261004/independent-report.txt, SHA eec698ca85299dfb9d3a7db50552bace5672b756c80da204d109c3fe666a728c; full-log SHA65d2bfff3beefbebe0c473a4c4b3bf40eb8b2512702484d4349680463054bb4e.
- App seven fake selectors passed7/7; native Debug simulated D200X ready/normal quit exit0/runtime rootempty. /Volumes/Data/tmp/hidhogg-v2-no-lock-app-20261004/gate-terminal.log SHAaa78729f866b89bb1fd24bc36a0ba9023e3686e55e1b963c6fbb30a3cbf887f2. Fresh ARM64 Debug MyMac and generic Release builds passed; app binaries ARM64only. Logs /Volumes/Data/tmp/hidhogg-arm64-only-{debug,release}-20261004.log. Independent static review passed.
- Corrected CLI gate on2026-10-18 passedexit0: simulated synthetichost, status ready/protocol1/canonicalUUID, profiles, notificationemit-clear, host_status0, socket/metadataabsence and full currenttempdircleanup. /Volumes/Data/tmp/hidhogg-v2-i01-socket-cli-harness/corrected-result.txt SHA36e65eb39d14fc217b5e0fc955f21f90d0e441ffcf2664a766eef6784cd46ab9; corrected-run.log SHA3b1130a99e0131ee1d760f70ea1c337bd1390921a022c57256909976703721ed. Script SHAd1205c4ffbb87305915cd385fdaea94e8939f08011ccebf6b09bc833355aa03d. Initial run failed only because harness expected active in status; active belongs configStatus. Production unchanged. Prior failed outer /tmp/hgI01.jSiTTx preserved (runtime subdir empty). Historical HARNESS-SHA256SUMS scriptdigeststale; directhash authoritative.
- User reactivated after exact integration scope clarification; main treated this as approval for that bounded gate. No need ask again for same gate.
- Refreshed source inventory /Volumes/Data/tmp/hidhogg-v2-checkpoint-prep-20261018/owned-overlay.sha256 SHA5d0c03a3477090dac01ae276a76468647ad456c6952c0980173c46a4322d9fef. All26checked. Old26manifest sole difference was exactlynine approvedARCHS=arm64lines; tester proved removingthem reproducesoldhash. Three C/lock paths absent, neveracceptedtracked.
- Required Discord milestone notifications for I01/U01 succeededexit0.

## Current design decisions

One Swift runtime in the app process; no separate runtime child, C bridge, or runtime-file lock. MVP assumesoneapp; singletonnot enforced. Fresh UUIDprivategeneration directories; owner-only0700directory/0600socketmetadata, UID/nofollow/inodeidentity guards and uncertainty-safecleanup retained. Sharedexplicitdirectorymultiprocess unsupported. Thread/actorlocks are unrelated and retained. No compensating singletonframework.

Apple Silicon apponly: ARCHS=arm64 in nine project/app/test Debug/Test/Release configs, macOS26+. SwiftPM generic Release mayemit unusedIntelCoreintermediate, not linked/shipped. Go remains reference/source until finalV01/X01 removal; current committed app usesSwift. TOMLv4strict acceptance retained, improvements allowed; conventionalstraightalpha and completeUTF8fielddiagnostics accepted.

## Work in progress and next actions

1. /root/swift_v2_executor owns U02 source: Protocol.swift, UnixSocketClient.swift, ConfigEditorClient.swift, SettingsView.swift and SettingsViewModelTests/ProfileClientTests/ProtocolFixtureTests. No Core edits. Six-field typedpatch alreadyinCore. UI controls label, RGB/RGBAbackgroundpreview, alignmentbottom/center,size8–32, stableIDnotificationsources, typedoptionalactions(profile/executeorderedargs+timeout/typeText/keyPress), schema-validgesture. Keepunchanged/setedited/resetUseDefault, no fictionalinheritance. One atomicdigestcheckedbatch; no-opdisabled, staleconflictrefreshwithoutretry, lateendpoint/profile/positionresponseignored. Meaningfulfakeunitcoverage allfields/actions/bounds/mixedbatch/resets/conflict/uncertainty. No liveintegration.
2. /root/swift_app_ownership owns only overview/structure/v2-plan consolidation for accepted I01/U01 and current2026-10-18status. Oncecomplete review and commit docs separately; preserve codecommits. Root alone .agents updates.
3. /root/verification_baseline preparing readonly U02 independenttestselectors/edgeaudit and concrete finalGUIgateproposal. No builds/tests/app launch until assigned.
4. After U02 ownerunitpasses freeze exactsources and independentlyverify relevantfakeunitselectors/builds, fixissues, commitU02 separately. Reviewable finalnativeapp/simulatedD200X GUI save/reopen/conflict/reload gate stillrequired beforeV01. Confirm new integrationdepth under userAGENTS, leveraging alreadyapproved boundaries. No selectedownerconfig/liveHID/input.
5. V01 acceptance then X01removeGoproductionpaths and audit. Not complete. Actualfour synthetic child-runner tests from R02 were prepared but neverexecuted; retainqualification and resolve relevantfinalverification scope, don't claimtested.

## Constraints

Neverread .env*, .envrc*, .aws/.gcp/.oci/.config/.ssh/secrets.yaml, environmentvalues or PII/ownerdata withoutpermission. No broadtmp/home inventory. Syntheticfixtures only. No nativeHIDenumeration/open/input, permissionsprompts, ownerapp/config. Nativegate explicit.simulated beforedefaults, fakeOSactions/preferences/observers/bootstrap. No genericclassintegrationruns; use reviewedselectorlist.

Usefullcommandarguments where supported; rg/fd, notgrep/find; no gh. Gitstage curatedexactpaths only, suppress author/email output. Do notstage .codex/.envrc/xcuserdata/workspace/.swiftpm/cache/binaries. Currentsharedworkingtreecontains U02edits and uncommitteddocs; preserveothers. Git/.agentswritesneedscopedescalation. No push/tag/PR/worktree. Skills applied: diagnosing-bugs for harnesscontractfailure; no othernewskillneeded.

Use existingagents, selfcontainedcapsules; no source takeover. User requires sourcecodeplanconfirmation (existingfullbuttonplanapproved), integrationdepthconfirmation, per-taskcommits, root-onlyledgers. Notifyacceptedmilestones with notify-discord. Do not repeatedlyrerunpassed205suite/corpus/imagechecks withoutchangedrisk. Keepconciseupdates≤60s.
