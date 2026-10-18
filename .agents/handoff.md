# Hidhogg v2 handoff

Updated: 2026-10-18, Australia/Brisbane.

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
