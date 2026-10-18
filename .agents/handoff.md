# Hidhogg v2 handoff

Updated: 2026-10-18, Australia/Brisbane.

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
