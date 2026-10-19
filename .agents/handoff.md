# HIDHogg rebuild — current handoff

Updated 2026-10-19, Australia/Brisbane. Current branch: next/logitech-slice.

## Approved scope and reset

Owner approved native Swift/efficient implementation, MX Master 3S over Bolt only, Back and Forward bindings, new branch with old production implementation retired, preserved research/specs/spikes/designs, and deletion/replacement of dist/Hidhogg.app at the same fixed path. Prior visual prototypes are no longer the active approval boundary.

Recoverable v2 checkpoint: 4b3248d, on v2. It includes the previously uncommitted B02/B03 source and design records as a preservation snapshot, not a claim of their physical acceptance. Existing v2 TaskView acceptance records remain unchanged. New TaskView list65 in existing Personal/HIDhogg project5 tracks NX-01–04 (#417–420).

NX-01 completed: 103 old tracked macos paths removed; old docs/protocol/schema/examples/legal artifacts archived under docs/archive/v2. Explorer independently verified 147/147 preserved files byte-identical to checkpoint. Product redesign, spikes, diagnostics and LICENSE retained. Unknown local files/generated metadata left untouched; no git clean, environment/config/PII reads or external repository edits.

## Current new application

app/ is a dependency-free Swift tools6.2 package, one native SwiftUI arm64/macOS26+ executable. Sidebar/List, native forms/buttons, gold tint; explicit unavailable-device message and disabled discovery. No HID/IOKit/Bluetooth/CGEvent/permission APIs, timers/polling or fake connected data. This is the application foundation, not completed Back/Forward functionality.

scripts/build-app.sh builds, stages icon resources, signs/verifies then replaces dist/Hidhogg.app. Explicit signing identity required, ad-hoc '-' rejected. Output and scratch overrides supported; --disable-build-sandbox is opt-in for nested sandbox restrictions. Prior output is preserved on build/sign failures and restored on install failure; replacement uses two moves with brief path gap. Do not run concurrent builds into same destination.

Accepted selected icon docs/product-redesign/logos/27-selected-serpent-padded.png is converted with native sips/iconutil into all ten standard ICNS sizes; original preserved. Current fixed bundle com.hidhogg.app is signed with prior certificate SHA1 BD088C6A3D3855EA8F47857A604894BF98E3CF98. Main independently verified extracted certificate DER hash without printing owner metadata. No private key export/trust/ACL changes. Bundle executable SHA25683011afbf378bf6c1b75cfd8cebdf0b4d9dc1aeffe8d37b6778adf6bfd0f7cd0. Redacted dist/build-info.json records provenance; app not launched.

## Verification and limits

Independent tester Release compile passed (arm64, minOS26.0); syntax/help/refusal gates pass. Controlled temporary shell harness confirms old bundle unchanged after simulated build exit41/sign exit45 and restored after install mv failure. Final codesign deep/strict verify passed; no LC_RPATH, only system/SwiftUI/Swift libraries; icon has all expected16–1024 sizes. Test log /Volumes/Data/tmp/nx01-taskview417-build-escalated.log; failure logs sibling build-failure/sign-failure/rollback. Compilation required scoped sandbox escalation; no hardware or GUI/e2e run.

Source SHA256: Package5570b8bcf7e83a94b78c45f7ccc038772065654953a1078e41520190430cae73; Appdc786912874b2c0380aef87cf3091369de8877d1ef926e6b29c0b35b0222cb14; Devices7807c5f6d3cec2562c47d34e0497ad5217f0d765e58e62830c0f7ba35d0de7f7; Workspace4536241bc20ae2656ea4c058d85601cf83b2462e32c6152ae1e3455022d8087c; Settingscf686cf61c6a37f817ddec7f99fc8e7baf887d3ea753f240115392109ae2158f; build-scripte42483ee7d7db2337910f3520f6c9e5a55c0eedd7217f5dbfdc81cb0161fff1c.

## Next work

NX-02 #418: decide/store device-neutral defaults and app overrides, typed shortcuts and save semantics. NX-03 #419: serialized Bolt transport/control/action integration; Back has bounded external LogiBridge evidence, Forward unvalidated. NX-04 #420: native editor, permission/reconnect/physical acceptance and measured CPU/memory gates. Dependencies recorded. No pairing, Bluetooth, gestures, advanced scrolling, other device, MCP or notification expansion in first slice.

External LogiBridge frozen spikes remain at /Users/axatol/Workspace/hans-m-song/logibridge. Read current handoff before reuse; never import diagnostic helpers into production or run shared-receiver experiments concurrently. No repetition of passed physical tests without a new question. New physical tests require explicit scoped owner gate. IOKit is candidate based on current evidence, CoreHID locally unproven. Do not hard-code old slot/feature indices.

Current canonical docs: docs/overview.md, structure.md, roadmap.md, rebuild-decisions.md, build.md. The earlier handoff below is historical; its old source paths and next actions are superseded.

---

# Historical handoff retained at reset

# Hidhogg v2 handoff

Updated: 2026-10-19, Australia/Brisbane.

## Current direction — multi-device product mock-ups

Owner requested a fresh mock-up-first design around the original one-app/multiple-HID goal, informed by current lessons and research at /Users/axatol/Workspace/ai/rea/investigations. This is a new product-design exercise, distinct from the existing V2 Swift migration naming. No replacement implementation or clickable prototype code is approved.

Owner selected D200X, MX Master 3S and Lofree Flow Lite for the first concepts. Flow Lite key-count variant is unspecified. Main reviewed authored Options+/Ulanzi summaries and current goals/lessons; explorer supplied a bounded Options+ workflow/evidence brief. Research remains static/partial, especially pairing, live action availability, connection-specific behavior and keyboard protocol/persistence. No raw captures, private settings or device operations were accessed.

Delivered docs/product-redesign/mockups/01-navigation-concepts.png, generated with built-in imagegen: A device workspace (recommended), B application workspace, C bindings workbench. Prompt brief, limitations and next questions are in mockups/README.md; design assumptions/checklist/source pointers in docs/product-redesign/brief.md. All device illustrations/status/assignments are synthetic, not support claims. Owner selected A. Expanded boards 02–04 now cover overview, three editors, action picker and permission/offline states. Next: owner review of save scope, unsaved changes and shared-action/profile ownership; see mockups/README.md for limitations. Keep editing independent of device connection; preserve separate saved/applied/permission states; do not inherit D200X tile-only UI as the universal model.

Current dist bundle, signing identity and B02/B03 fixes remain unchanged and pending their recorded owner acceptance. Do not discard/commit/rewrite them as part of design exploration. No new TaskView project or roadmap migration has been created for the redesign.

## Standalone runnable bundle — 2026-10-19

Owner requested a fixed-path app without opening Xcode and selected dist/ in this checkout. Owner authorised inspection of signing metadata with owner names redacted and no private-key export. Release bundle is now at /Users/axatol/Workspace/axatol/hidhogg/dist/Hidhogg.app; /dist/ is ignored by Git. It contains the pending B02/B03 fixes. No app launch, owner configuration/HID access, /Applications install, commit or push occurred.

The previous product had only a linker ad-hoc signature; path alone did not establish durable update identity. One valid Apple Development identity was found and used through Keychain, without exporting a key or changing trust/ACL settings. Preserve this signing certificate SHA1 BD088C6A3D3855EA8F47857A604894BF98E3CF98 for subsequent local updates, bundle ID com.hidhogg.app and exact dist/Hidhogg.app path. Do not overwrite it with an ad-hoc-signed build. Owner may need one new permission grant for this initial signing-identity change; future permission retention is not guaranteed against OS/user policy changes.

Signature verification (deep/strict) passed, designated requirement is present and has no cdhash pin. Requirement SHA25651799b6c6550b6e7f74267a9e197ea012aeaa450290420b2950798af02efd343; signed executable SHA2564579b8a8ed0b87bb2b96a353c666d3d901832c150d6cf86c541d7702a9117eb6. Redacted build-info.json alongside the bundle records these facts. Full certificate-owner names and private keys were not printed or stored.

Independent Release packaging gate: arm64/macOS26+, default production arguments, default TOML/font resources bundled, no Test-host macro, no DerivedData-linked libraries/rpaths; source/project/scheme hashes unchanged. Build evidence /Volumes/Data/tmp/hidhogg-standalone-20261019/release-arm64-build.log SHA2568859f1ec59462bf422e5cdefa04498f7e8609c9cf6ee4849db363245bf69cf79. No unit rerun necessary without source changes. The owner should quit older instances and open the dist bundle, then verify permissions, profile editor and normal-use memory. Future packaging must stage a fresh Release app, sign with the same identity, verify its designated requirement before replacing this fixed bundle, and preserve any running instance until the owner quits it.

## Ready for owner check — V2-B03 #416

Approved on 2026-10-19; implemented and independently verified. Source is uncommitted pending owner confirmation under normal device/configuration use. Preserve the separate B02 editor repair. The owner can quit the old instance; no further live-process inspection is needed.

- [x] Confirm live footprint/allocation growth and identify retained types.
- [x] Reproduce growth in isolated Settings closed/open probes.
- [x] Add changed-value publication guards with red/green regression tests.
- [x] Independent source review, 75 app tests and arm64 production build.
- [x] Matched candidate closed/open/reopen memory probes and cleanup.
- [ ] Owner acceptance, then commit each accepted source scope separately.

### Change and decision

HidhoggAppModel retains its 100 ms poll but publishes each of its nine runtime/profile/display UI projections only when the Equatable value changes. Internal refreshObservedState() is shared by the poll and tests. Real lifecycle, health/bootstrap/CLI detail, profile/catalog, mapping, bundle and display-error updates remain. No new public API, Core/protocol change, broad Observation rewrite, runtime process, cache purge or notification-sizing work.

Alternatives rejected: reducing poll frequency merely slows redundant updates; periodic purge/reopening masks accumulation; an observer rewrite expands scope before evidence requires it. Three focused tests passed after the unchanged-refresh test failed with three emissions per field instead of one. Nonblocking review gap: changed currentProfileID is not explicitly driven by a new test; its guard is statically correct.

### Results

The original owner process showed 2.1G footprint/main heap about 2.0G, dominated by ObservationTracking dictionaries, key-path sets and closures. Timed live allocation count increased 5,352 in 17.42357 seconds. Owner reported opening Settings reduced 2.11GB to about 400MB, which remains unacceptable. That large drop was not reproduced or explained.

Both controlled versions use synthetic configuration and simulated D200X, with uniquely identified copied/ad-hoc-signed apps. Before/after measurements are separate builds and processes; the old baseline used CUA, while the candidate used a bounded exact-PID AX helper after CUA attachment hung. Each phase sampled for about 60 seconds with valid vmmap rows and timestamped heap captures.

| Phase | Old B02 build: footprint / main allocation change | Candidate: footprint / main allocation change |
|---|---|---|
| Settings closed | 61.4→66.9M / +30,180 | 39.5→39.4M / −435 |
| Settings visible | 70.0→74.9M / +31,799 | 39.5→39.5M / +40 |

Candidate visible-phase grouped Observation, AnyKeyPath, Tracking.Entry and closure-context counts/bytes were unchanged. All-zone heap grew only 3,104 bytes. Same-PID close/reopen snapshots were about 22.8 seconds apart: footprint39.5→39.8M, while heap totals and grouped tracking types decreased. The initial 19.2M zero-window sample is a pre-UI control, not the fresh GUI baseline or memory-pass result.

This supports removal of the reproduced idle accumulation and a low fresh-GUI footprint around40M. It does not prove overnight stability, physical-device behavior or the real owner configuration; owner acceptance remains pending. Do not call a fall to400MB a pass.

### Evidence

- Memory root: /Volumes/Data/tmp/hidhogg-memory-20261019.
- Old corrected phases: settings-phase-r416b03/phase-summary.json.
- Candidate: settings-candidate-r416b03/candidate-gate-summary.json, SHA25637849f6a65875f17f13e9ae624f868ca724d5f6602f24bfedd134935bb6de76b; phase JSONs and reusable collector alongside.
- Independent verification root: /Volumes/Data/tmp/hidhogg-memory-repair-verify-20261019.
- focused-tests.xcresult/log:75/75 (Settings43/runtime8/composition24), explicit socket-backed composition selector excluded. Test log SHA2562b7ceefbd9ca52dc073f4b558266ce83786345cdd5cf45d107416b1719405d9f.
- Production app: ProductionDebugDerivedData/Build/Products/Debug/Hidhogg.app under verification root. Binary SHA25696cd5448bb6ec4acf5df18a3c053d572ade4f6620ef93b96d852f7a14747efeb; arm64, no Test-host define. Build log SHA2563e7ea430c952383e6c2d12f29ff84204b0d28634d759142ec09b1666b6c29144.
- Frozen source hashes: HidhoggApp.swift8f9bd2be338cafcdebbd17255a4c50b9eb17c963f0021dc24a41c3c66a68ec5a; HidhoggSimulationCompositionTests.swift01dd7d26d51e1593cc77421ee7622e04918120debfbb2679101023be2b5e96e0. Main verified B02 source/test hashes unchanged too.

### Cleanup and retained qualifications

Candidate PID67775 is absent (main independently confirmed via scoped numeric ps), exclusive0600 stop marker caused shutdown, synthetic runtime is empty; baseline PID62474 likewise stopped with an empty runtime. Exit codes are unobservable through NSWorkspace launch; no force kill for these matched runs.

Earlier exploratory PID54482 required SIGTERM because the harness made its stop marker0644 rather than the required0600. Its synthetic runtime.sock/runtime.json remain preserved under /Volumes/Data/tmp/hmp-r416c8a2/r. Earlier exploratory vmmap/timing limitations are documented in the log/artifacts, not used for the matched rates. No product shutdown/deadlock fix claim.

CUA candidate attachment blocked261.1s and was interrupted by main. Bounded AX/NSWorkspace helpers verified exact diagnostic bundle/PID/path, used no TCC prompts or permission changes, and completed window transitions. Default sandbox metadata visibility was misleading; scoped checks confirmed the process remained alive. No owner app lifecycle changes, owner configuration/environment/PII/raw heap contents, physical HID or native input/actions were accessed. Temporary diagnostics stayed under temp roots; no production logging/instrumentation. Existing untracked files preserved; no install, push, deployment or worktree.

Next: owner rebuild/relaunch from Xcode, verify B02 profile editing and normal-use idle memory. Commit the confirmed source scopes after acceptance; no additional implementation is currently required.

## Ready for owner UI check — V2-B02 #415

Owner reports Settings profile editor unavailable while configuration health is ready; notification emission works. Repair approved 2026-10-19. Notification text sizing explicitly excluded.

- [x] Reproduce actual runtime-handle publisher delivery to the Settings editor with a failing inert test (two identical red runs).
- [x] Confirm cause and make scoped repair, preserving stale-generation guards.
- [x] Independent focused app verification and arm64 production build.
- [x] Record decisions, evidence and handoff.
- [ ] Owner GUI acceptance; commit accepted scope afterward.

Executor editor_readiness_repro changed only SettingsView.swift and SettingsViewModelTests.swift. The synchronous publisher delivers the new handle before provider storage updates; initial refresh reread nil and cleared the installed session. Initial refresh now captures that session and validates it in the asynchronous task before operation and on completion. Explicit actions/refresh retain synchronous guards. Weak self is preserved across the awaited snapshot. Two new tests cover real publisher readiness/shutdown and preflight provider loss. Executor Settings tests pass 43/43. Independent static audit found no blocker; independent tester passed Settings 43/43 plus runtime-session 8/8 and production arm64 Debug build. Source hashes unchanged across verification. No production test-host define. No owner configuration, physical HID/input, real actions or new integration harness. GUI acceptance pending; source remains uncommitted until owner confirms. Existing untracked files preserved. No installation, launch, push or deployment.

Evidence roots: /Volumes/Data/tmp/hidhogg-settings-editor-repro-20261019 (two red runs, focused green and Settings suite); /Volumes/Data/tmp/hidhogg-settings-editor-verify-20261019 (independent tests/build). Independent settings-runtime-tests-escalated.log SHA256 bceff82729f00f46ffdb9ac29b884802ccd44a49f437ac3a9f871a1efb7dc40d. debug-arm64-build.log SHA256 62817fd4e8015de2b4e56f9f076c00f6a7ca18df6bf7f872e32b826469774d3f. Built app: DebugDerivedData/Build/Products/Debug/Hidhogg.app under the independent evidence root; executable SHA256 1addff70b699e786b5abe6b636f7bc55255e6fa7a65f2484be09a56a8b3b8aa6.

## Latest completed task — V2-A01 #414

Owner follow-up: confirmed the new build still works and reported that the screen had locked earlier. The timing relative to the fixture mkdir stall and any causal relationship remain unverified. This adds owner acceptance, not proof of the earlier stall cause.

On 2026-10-18 the authorised internal-runtime simplification completed. See docs/runtime-simplification.md for all sixteen implementation decisions, alternatives, evidence and qualifications. TaskView project 5/list 49 is authoritative. Source checkpoint is the scoped in-process-runtime commit (see git log); no push, installation, deployment or worktree used.

App profile/display/editor calls now use captured typed RuntimeOperationsHandle instances. One session-owned Core RuntimeOperations actor serves app, watcher and IPCServiceBinding. CLI socket startup is optional with visible degradation; the external protocol/security remain. Retired operations reject new calls, cancel pre-admission work and drain admitted work before server/device shutdown. Separate disk digests, file-commit and reload outcomes remain. Four app wire files and two associated wire test files were removed; ProfileValidation.swift/AppValidationTests.swift retain app and path-security checks. Supervisor.swift still contains active lifecycle/directory utilities, not a child-process supervisor; no broad observer/state-machine rewrite.

Independent verification: Core 212/212; safe app 125/125; Debug arm64 production app and Release arm64 CLI builds; controlled native simulated-D200X app/CLI smoke passed. The app suite excluded only the explicit Core-server composition selector, covered separately by packaged app/CLI smoke. No production TestHost define. Smoke verified same UUID where returned, readiness/protocol 1, profile activation and notifications, graceful app exit 0, no watchdog escalation, empty runtime root and removed synthetic root; exact owned PID gone.

Evidence root: /Volumes/Data/tmp/hidhogg-runtime-simplification-20261018. Final source manifest final-source-manifest-r3.json: 100 entries (94 present, six deleted), zero mismatches after all gates; SHA256 ff4e8e9993ae3fef46c407ecafc67fe198c21ec7dd64aa9afd10e2f553f3376b.
- CoreFinal/full-suite.log SHA256 5a82099f3e3b7e031d17757ce164800eeeb2e9ba418538d532cf043d46c14806.
- AppTestsR3/safe-app-suite.log SHA256 92b56d0ed39be2a4fd4d47b7c177d1ea00743ef5ffb0377879c84b98d9104112.
- Smoke/smoke-a01smk1-escalated.log SHA256 82c6b05ab76744be83fa89cc1f3e9bb4bd9edfad787f5636435ea8ace995df15.
- SmokeArtifacts/a01smk1/harness-result.json SHA256 198f885abaea256441aa44df9308eb2e73ebe0ca486cb0c17704b6b2c63a3032.

Built app: /Volumes/Data/tmp/hidhogg-runtime-simplification-20261018/AppDebug/DerivedData/Build/Products/Debug/Hidhogg.app (executable SHA256 c20428f1d7c7f9c114ee4908f6d2da7543816d9e5c907a5516ea358a4ca74212). CLI: /Volumes/Data/tmp/hidhogg-runtime-simplification-20261018/CLIRel/SwiftPM/out/Products/Release/hidhoggctl (SHA256 80ceb9da900f0e879eae3ce46f3c8d31bc2a813d236937eb7cbd6d43735ac502).

Qualification: earlier app gate stalled in fixture mkdir before any runtime. Owned-process sample and interrupted log retained; cause unconfirmed. Only new fixture roots moved to short /private/tmp; isolated then full suite passed. No product-deadlock fix claim. Final adversarial review corrected stale clone validation order, ownership-unsafe fallback cleanup and invalid new ID expectation; re-review found no blocker. No physical HID/input, real configured actions or GUI testing for this task. No owner configuration/environment/PII reads. Temporary diagnostics reverted. Unrelated untracked files preserved. No remaining implementation work in this authorised slice; owner may review decisions and runnable artifact.

## Accepted feature — V2-U03 #412 / V2-U04 #413

Owner confirmed actual app drag works, then confirmed restart feature works and requested closeout on 2026-10-18. Both tasks complete. Earlier V2-B01 #411 resolved after permission grant/restart restored VS Code numpad actions.

Settings Permissions shows CGPreflightPostEventAccess status with appearance/activation/manual refresh, best-effort permission-page shortcut with both-name manual fallback, exact Bundle.main app icon public.file-url drag and Finder reveal. Restart awaits idempotent model.quit(), requires stopped runtime before exact-bundle new-instance launch with substitution disabled, then terminates old app on success. Duplicate requests blocked, failure visible, simulation restart disabled. No helper/shell/runtime IPC added.

Independent focused checks: 48/48 passed (42 SettingsViewModelTests plus five restart tests and existing delegate termination ordering), zero skips. Active gated fake-runtime test proves launch waits for stop. Debug production build passed, arm64 confirmed, no HIDHOGG_TEST_HOST in production log. Final four source/test hashes verified unchanged at closeout; static closeout audit found no unrelated source edits or blockers. No test rerun was needed without source changes.

Evidence root: /Volumes/Data/tmp/hidhogg-restart-20261018/
- focused-tests-corrected.xcresult and focused-tests-corrected.log; log SHA256 2625ccf4ab6872a7fa554f02dde4edbfa8673f8f032a2c6a4720fb55aec53098.
- ProductionDerivedData/Build/Products/Debug/Hidhogg.app; executable SHA256 496bde9a11fc354f867671a079fbfd93e61c255641fcd9bbf1fb8350f1762e00.
- production-debug-build.log records successful arm64 production build.

Earlier permission drag regression runs (two) failed NSURL/public.url loadItem roundtrip with CocoaError256, including an existing fixture; explicit public.file-url data export fixed the regression. Retained in /Volumes/Data/tmp/hidhogg-permissions-20261018/. Final permission class passed42/42 before restart additions. Restart test commands initially stopped before XCTest for sandbox package resolution and inaccessible private helpers; corrected test-local fakes then48/48 passed. No agent-run live native input/HID or owner configuration reads. Owner supplies live drag/restart acceptance. Exact permission deep-link destination was not independently observed; shortcut remains best effort with manual fallback. Simultaneous external Quit cancellation semantics are unspecified; shutdown ordering prevents runtime overlap.

Current feature is closed in the scoped permission/restart checkpoint (see git log). Unrelated untracked files preserved; no push/PR/worktree used.

## Completion

The approved offline Swift migration is complete. Branch `v2`; source cleanup checkpoint `95d0942`, Settings activation checkpoint `08a44f8`. All twelve V2 tasks in TaskView Personal project 5 / list 49 were verified complete: P01 121, C01 122, C02 123, D01 124, D02 125, R01 126, R02 128, I01 130, U01 132, U02 134, V01 136, X01 138. TaskView is authoritative; docs/roadmap.md remains a stable ID/dependency map. No push, PR, tag, deployment or worktree was used.

## Current architecture

macOS 26+ / Apple Silicon arm64. The native Swift app owns one Swift runtime/device lifecycle; HidhoggCore owns configuration, edits, D200X, policy, actions, notifications and IPC. The Swift hidhoggctl executable provides status/notifications. No Go source/module/build dependency, Go child launcher, C bridge or runtime-file lock remains. Private UUID-generation directories retain owner-only permissions, identity/nofollow checks and guarded cleanup. MVP assumes one app process; global singleton enforcement and shared explicit-directory multiprocess use remain unsupported. Ordinary actor/thread synchronization stays.

The six-field editor supports label, background, alignment, label size, notification sources and action. Stable UUID argument rows prevent stale index captures. Error classification follows stable allowlisted protocol codes with bounded raw messages and fixed local safe wording. Strict TOMLv4, exact digest conflicts, lossless untouched bytes and separate file/reload outcomes remain.

Settings scene uses defaultLaunchBehavior(.presented). Standard `open -a /absolute/path/to/Hidhogg.app` reopened Settings for the already-running temporary simulated app and reused the same PID. No URL scheme or new runtime command was added. Isolated cold-launch presentation was not established.

## Final verification

- Core final cached suite 206/206; app safe units 139/139. One app server-composition selector was intentionally excluded from the unit suite; actual simulated app/server/CLI behavior was checked separately.
- Initial final-run Core suite had one failed wait assertion at RuntimeCoordinatorTests.swift:232, `releaseWasProcessedBeforeTimerWake`, polling fake-clock zero sleepers for 2,000 Task.yield iterations. No other assertion failure was logged. Focused selector passed once plus 10/10 repeats, then one full cached run passed 206/206. Cause is unconfirmed; Core files were unchanged. Do not describe this as a fixed or proven production defect.
- Test/arm64 build and production Debug/Release app plus Debug/Release Swift CLI builds passed. All four production executables are arm64; no HIDHOGG_TEST_HOST condition in production app logs. Frozen 99-path source manifest matched before/after.
- Hg07 native GUI verified all six fields through save/reopen, stale-source refusal without retry/overwrite, action/position draft isolation, background reset preserving other fields, display reload and cleanup. Hg06 separately verified first/last argument removal and survivor edits without the old trap.
- Final hg08 packaging gate (session 4526 / PID 26286) reached ready, reopened Settings, verified Release CLI ready/protocol 1/same UUID, exited 0, removed runtime and simulation root, with explicit watchdog_escalation=none. No CUA calls occurred after stop request. No owned test app remains running.

Final report: /Volumes/Data/tmp/hidhogg-v2-x01-final-20261018/final-verification-report.txt
SHA256: 77127708a382f1ff664773cbc32fee1d8623787b0a2319d8980216609c513fa4
Native log: native-smoke-terminal.log in the same directory; SHA256 f3e358b86b12a997175b8c73c2141669cba6837694fe5c3b3778b07115cb80f8.
Earlier GUI report: /Volumes/Data/tmp/hidhogg-v2-v01-gui-prep-20261018/hg07-result.md; SHA256 2b0f3bad14cbf85c876acd2e5c42d1e7577ce8631633c679486f4228178dc5fa.
See docs/v2-plan.md for durable acceptance details and previous gate evidence.

## Removal and preservation

Source commit 95d0942 contains 199 reviewed paths: 173 Go/diagnostic deletions, 3 obsolete Swift file deletions, 4 retained Swift/project modifications, 19 documentation/reference updates. The Go set is 150 .go files, 8 module files, 7 Go-only fixtures plus 8 diagnostic scripts. Exact inventory matched independent review. Removed only dead child-launcher declarations; retained generation factory/lifecycle/security and Core configured-action runner.

The owner explicitly retired brightness-zero, keepalive and firmware-wake diagnostic tools rather than porting them. Preserve research. Historical runbooks and spike README bodies remain under dated retirement banners. Eight static spike artifacts, exact docs/v1-roadmap.md, 20 protocol-reference paths, font/provenance/license resources and all tracked ulanzi-lldb helpers remain. Existing untracked files, including the old d200xprobe binary, were left untouched. Do not delete or stage them as cleanup.

## Qualifications and future work

Physical HID/device delivery, native input/permission prompts, optional actual configured-child cases and isolated cold-launch presentation remain unverified. The child cases were optional under Task 128, not a V01 blocker. The intermittent Core assertion is recorded with unconfirmed cause. Custom assets/shared-library artwork and split profile files remain deferred. None is an unfinished task in the approved offline migration.

## Operating constraints

Never read .env*, .envrc*, .aws/.gcp/.oci/.config/.ssh directories, secrets.yaml, environment values, PII, owner configuration or crash reports without explicit permission. Use synthetic config and explicit simulated flags for offline gates. CUA must target exact temporary app paths; never query UI after requesting shutdown, because a prior query may have relaunched the temporary app. That earlier relaunch cause remains unproven. Preserve failed gate roots/logs. Source work uses bounded agents; only root edits .agents ledgers. New code plans require owner confirmation under supplied AGENTS instructions.

### Latest design revision — 2026-10-19

Board 05-application-selector.png supersedes segmented app controls in boards 02–04. Owner approved searchable dropdown; examples show VS Code override and Safari inherited default. Image and exact prompt saved in docs/product-redesign/mockups. No code changes.

### Latest page coverage — 2026-10-19

Boards 06–09 saved in docs/product-redesign/mockups with prompts: outlined controls/status; notifications; action library/editor; app rules/settings. All top-level pages now have static concepts. Owner review pending on these boards. Do not infer approval of shared-action propagation or notification route scope/retention. See README for remaining forms/edge states and visual inconsistencies. Application code and dist bundle unchanged.

### Canonical design correction — 2026-10-19

Boards 10/11 supersede board 07/global routing and standalone Permissions. Notifications is receipt/delivery history; filters belong to device/control bindings. Settings contains Permissions and proposed MCP integration. Owner requested MCP configuration, notification reads and settings. Device discovery/actions/validation/tests/activity are proposed. History retention, multi-target delivery, transport/auth and write semantics need agreement; MCP must not create another runtime. Mockups README and brief carry current decisions. No code changes.

### Latest identity direction — 2026-10-19

Owner wants connection dots beside Connected text, recorded in design brief. Logos/03-clay-device-concepts.png is current unselected logo exploration: hedgehog plus mouse/keyboard, faux 3D clay, no integrated lettering or gaming aesthetic. Board/prompt/README saved; earlier dragon/flat monogram directions superseded. Main inspected outputs, no production app icon replacement. Await owner choice.

### Current logo alternatives — 2026-10-19

Latest style is nearly 2D with shallow shading, based on owner-supplied icon; clay is superseded. No integrated letters, explicit mouse/keyboard motif, nothing gamery. logos/05-refined-hedgehog-directions.png shows preferred Mouse keeper/Companion/Curled connection compositions. logos/06-nidhogg-directions.png adds two requested dragon alternatives. Prompts/index saved; awaiting owner selection. No app changes.

### Latest requested icon set — 2026-10-19

logos/07-semi-flat-companions.png shows hedgehog/mouse and Nidhogg/keyboard based on supplied crops; 08-wildcard-common-thread.png and 09-wildcard-orbit.png explore independent styles. All saved with prompts and inspected. Mascot pair still more sculptural than near-flat 05; await owner preference. No icon selected/installed.

### Latest small-icon candidates — 2026-10-19

logos/10-small-icon-companions.png: simpler near-flat peeking hedgehog/mouse and dragon/keyboard. 11-mascot-wildcards.png: enamel hedgehog/keycap and ink dragon/mouse. Owner disliked 08/09 wildcards. Priorities: readable small, cute, oversized device, no lettering, not gamery. All inspected/saved with prompts; actual size/Dock testing pending selection. No code or installed icon changes.

### Latest icon refinement — 2026-10-19

logos/12-dimensional-companions.png is latest: owner preferred board 10 setup with more 3D. Preserves hedgehog/mouse and dragon/keyboard peeking poses and simple silhouettes, adds rounded volume. Saved/inspected with prompt; owner selection and real small-size testing pending. No app changes.

### Latest flat-3D style reference — 2026-10-19

Owner supplied ~/Workspace/hans-m-song/postie/packaging/Postie.png as authoritative flat-3D style reference. Main inspected exact image; logos/13-postie-style-companions.png is current unselected hedgehog/mouse and Nidhogg/keyboard refinement using that reference. Board/prompt/index saved; no app changes, small-size verification still pending.

### Latest device/palette board — 2026-10-19

logos/14-device-palette-studies.png is current candidate set, requested after owner said 13 closer. More edge padding; hedgehog behind illustrative MX Master, Nidhogg behind 15-key Stream Deck; Ocean/Sage/Dusk palettes. Final inspected and saved with prompt. Await choice; no icon installed and small-size export testing pending.

### Latest simplified palette board — 2026-10-19

logos/15-simplified-device-palettes.png supersedes 14: six large deck keys (2x3); smooth simplified mouse flipped so thumb rest on viewer right. Same mascots, padding and three palettes. Main inspected requested edits. Await owner selection, no app changes.

### Latest dragon alternatives — 2026-10-19

logos/16-dragon-palette-matrix.png adds nine unselected variants. Columns round face, long snout, three heads; rows apricot, icy cyan, charcoal/gold. Six-key deck, flat-3D finish retained. Main inspected; owner choice pending. No app changes.

### Latest distinct creature designs — 2026-10-19

Owner likes black/gold palette, requested actually different dragon styles. logos/17-distinct-gold-guardians.png offers long dragon/qilin-inspired/wyvern/feathered serpent. Kiryan interpreted as qilin/kirin (uncertain). Images/prompt/index saved; stylized interpretations, no final choice. No app changes.

### Latest selected-motif refinement — 2026-10-19

logos/18-playful-gold-guardians.png: owner-selected long dragon and feathered serpent motifs, more caricatured, six distinct button pictograms. Board/prompt saved and inspected. Black/gold preference retained. Not final icon selection; restore generous padding and verify actual small sizes before production. No app changes.

### Latest simpler mascot comparison — 2026-10-19

logos/19-simple-dragon-and-serpent.png: simplified long dragon and smooth serpent, gold/black six-key deck. Owner prefers long dragon generally; asked to reduce detail/squishing and try serpent. Main images inspected, generated thumbnails unreliable; actual small-size exports and padding refinement remain. No final selection or app change.

### Latest head/button refinement — 2026-10-19

logos/20-bold-heads-simple-keys.png is latest: larger prominent faces, no tiny whiskers or button pictograms; blank Amber/Jewel/Pastel buttons. Serpent now dragonlike head with horns/brows/cheek fins, smooth body. Owner selection pending; no app changes.

### Latest expressive-face refinement — 2026-10-19

logos/21-square-keys-expressive-faces.png is latest: bigger heads/eyes, restored long-dragon whiskers, square-looking blank keys with top-left black. Two candidates retained. Board/prompt saved and inspected; production size/geometry verification pending. No installed icon or source changes.

### Latest blue relief candidates — 2026-10-19

logos/22-blue-flatter-relief.png compares Azure and Blue-green long dragon. Owner clarified overlap contrast means shadows, wants flat body surfaces with narrow steep shadows. Large expressive face/whiskers and black-top-left blank deck retained. Exact key squareness/padding/small-size validation remain pending. No app changes.

### Latest gold dragon/serpent pair — 2026-10-19

logos/24-long-dragon-draconic-serpent.png current candidate: darker honey gold, ivory horns, smooth surfaces/tight shadows, broad scale patches; long-dragon whiskers sweep sideways from upper muzzle, serpent restored with dragonlike head/no limbs. Owner disliked nose-tip hanging whiskers in intermediate 23. Near-side root still imperfect; padding/square keys/actual small-size tests not final. No icon installed.

### Latest ridged-serpent refinement — 2026-10-19

logos/25-ridged-serpent.png: owner-supplied spined dragon reference loosely informs serpent head, horns and ridges; gold friendly finish and long-dragon alternative retained. Main inspected board/prompt saved. Production square keys/padding/small-size tests remain pending; no app changes.

### Selected serpent direction — 2026-10-19

Owner chose serpent and requested more caricature. logos/26-caricatured-serpent.png latest single-icon candidate, saved/inspected with prompt: larger expressive head, chunky muzzle, ivory swept horns, gold/black six-key deck. Direction selected, candidate acceptance pending. No app changes; actual small-size/geometry/alpha checks remain.

### Current design decision and pending approval — 2026-10-19

Owner accepted logos/27-selected-serpent-padded.png; use gold/charcoal accents. Requests Swift native components. Existing raster concepts are not native implementation. Async approval pending for separate synthetic SwiftUI prototype covering device editor/history/Settings with standard macOS controls and custom device canvas only. No working app/bundle changes authorized by that pending question yet. Exact palette tokens and production icon packaging checks remain.
