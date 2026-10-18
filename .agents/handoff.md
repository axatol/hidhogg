# Hidhogg v2 handoff

Updated: 2026-10-18, Australia/Brisbane.

## Objective and source of truth

Complete pure Swift macOS app/runtime plus Swift CLI and six-field button editor. Use native macOS with simulated D200X for acceptance, test feature and failure edges, and commit between tasks. TaskView Personal project 5/list 49 is authoritative: P01 121, C01 122, C02 123, D01 124, D02 125, R01 126, R02 128, I01 130, U01 132, U02 134, V01 136, X01 138. Eleven tasks are accepted; X01 remains incomplete. Branch v2, current source HEAD 08a44f8. No push, PR or worktree.

Read docs/v2-plan.md, docs/overview.md and docs/structure.md for accepted scope; .agents/log.md preserves earlier decisions. Only root edits .agents ledgers. Source changes use existing agents, narrowly assigned ownership and independent verification.

## Accepted checkpoints

- R02 620b5ec; I01 d714dfe; U01 2418f54; shared docs 8ca678f.
- U02 implementation fc0a9c5 passed focused 24 tests; acceptance still depends on final GUI workflow.
- Simulation delayed-stop fix 185bf34: eight fake tests and native 135-second ready/stop/clean exit gate passed. Bootstrap observer isolation ea8c04c passed the bounded 148-test app suite.
- Latest error-contract fix 980f59e and stable argument-row fix a915cec passed revised Core 206/206 and app 152/152 suites, zero failures or skips reported. Seven frozen source/resource hashes matched before and after. Fresh production Debug build session 89893 is terminal exit 0.

Latest unit artifacts: /Volumes/Data/tmp/hidhogg-v01-regression-gate-20261018/. Core log core-test-final.log SHA bc0c4ff5e94c009119b684f07889bd2564033ab2f35d58de34c897c4746cbe07; Test/ARM64 build log app-build-final.log SHA d36b727fe64d37ad2f6036c3c1761de318d371f4f7c53ed8b615c7a2cb274b66; app log app-tests-final.log SHA 36c13a181816e4b205947f4abaceb8f279c1779c3ec9a3ebe03dd9847abaddc4. Result bundle app-tests-final.xcresult. Source manifest SHA 1d8084be3011f1602747debf4a7e236aae2f2c854fe397d6aa7863d46cb11fe5. App tests used HIDHOGG_TEST_HOST; no actual server/child/native input selectors. Earlier denied sandbox attempts and the superseded @testable Core build failure are preserved, not test failures.

## Watched GUI findings and fixes

User asked to watch a retry. Fresh hg04 app PID 96009/session 78449 reached ready. Computer Use could not attach to the windowless menu-bar app; user opened Settings manually, then exact-path attachment worked. Do not attribute earlier timeouts to another Codex session: that cause remains unproven. Settings may appear behind other apps; use its observed Raise action if needed.

Six-field save passed: Simulation label, #2458A0FF, centered/24 label, calendar+alerts sources, activate-profile office/release. UI reported file committed/runtime reloaded (display); file and reopened position values agreed. External brightness 80 -> 81 plus a stale draft save preserved the file but incorrectly reported unknown outcome. Core messages differed from the app's exact-wording validator.

Execute DRAFT ONLY (/usr/bin/true; first,middle,last): editing middle and removing first trapped with app exit 133/harness 1. No configured action was executed or saved. Failed hg04 generation and logs remain; no graceful cleanup claim. Report /Volumes/Data/tmp/hidhogg-v2-v01-gui-prep-20261018/watched-gui-result.md SHA 2c63ebca593129baccce637834f056ac8901a26801a35e2a690e6bfd601713db. A second temporary app process appeared after the crash; user denies Reopen. Its cause is unconfirmed; scoped TERM stopped it and exact-binary pgrep then returned no PIDs. No owner configuration was inspected.

980f59e fixes the actual wire contract: known error code determines classification; bounded server message is never displayed, and the client supplies fixed safe wording. Missing legitimate editor codes were added. Closed fields/types/allowlist and 256 UTF-8-byte bound remain. Core production source is unchanged. Core's actual stale response is byte-checked against a shared resource consumed by the app test. Ordinary Core import avoids the earlier testability build issue; no build flags/public API were changed.

a915cec replaces index-captured argument bindings with stable UUID rows. Lookup/update/removal use IDs; wire values remain ordered strings. Display ordinals remain. Tests cover first-row removal, surviving edits, stale IDs, serialization and action/position switches.

## Immediate next action

V01 accepted on 2026-10-18. Hg07 session 17037/PID17100 is terminal exit0; runtime root empty. Report /Volumes/Data/tmp/hidhogg-v2-v01-gui-prep-20261018/hg07-result.md SHA 2b0f3bad14cbf85c876acd2e5c42d1e7577ce8631633c679486f4228178dc5fa; independent matrix /Volumes/Data/tmp/hidhogg-v01-final-acceptance-20261018.md SHA 9a3a89e71ed720b088a10e23ce7226a9676e466a62534e98257b96da3a2f9dc6. Six-field save/reopen, stale conflict/no retry, action/position isolation, background reset with other fields kept, reload and cleanup passed; hg06 separately verified argument first/last removal and survivor edits.

Approved Settings scene modifier is committed 08a44f8. Standard exact-path macOS open reopened Settings twice and retained PID17100. Cold-launch presentation was not isolated because an extra temporary process15547 was present; scoped TERM stopped it. It started around the prior shutdown, possibly from a late CUA state query; cause unconfirmed. Never make any CUA call after requesting stop, even while harness remains live. Final smoke must log watchdog escalation explicitly so exit0 cannot conceal a signal.

X01 is in progress with two source owners: swift_v2_executor owns tracked Go removals/retired diagnostics/current docs; swift_app_ownership owns only the obsolete Swift launcher boundary and Xcode refs. Both must freeze before tester runs Core/app units and Debug/Release app/CLI builds. Root owns integration, Git, TaskView and .agents only. Keep all untracked files untouched, including d200xprobe. No app/test/build currently live.

## Remaining scope and decisions

GUI acceptance passed; X01 final cleanup and verification remain. Optional four-case actual child integration is an unrun qualification, not a required V01 gate: Task 128 says it may verify after approval, and docs/v2-plan.md requires unit/failure plus simulated app workflows. Do not run those optional tests without their separate approval; do not block the approved goal on that optional gate. Real hardware/native input are also untested boundaries.

User explicitly chose on 2026-10-18: retire legacy owner-run physical D200X diagnostic tools (brightness-zero, experimental keepalive, firmware-wake trials) while preserving research documentation. Do not port them or delete unrelated Ulanzi LLDB helpers. X01 must wait for V01, then remove Go implementation/build references and retire Go-backed diagnostic wrappers with clear current documentation.

X01 preflight: /Volumes/Data/tmp/hidhogg-v2-x01-removal-preflight/report.md and tracked-go-paths.txt (173 candidates). Preserve docs/v1-roadmap.md, api/protocol/v1 references, and Go Regular font/provenance/license. Swift legacy boundary report swift-legacy-boundary.md SHA 095cc7ab38c13c86ce1f9c15eaef8f980b5fd6b37d446d993e129d2c9ae4a888. Supervisor.swift is mixed-use: retain generation/ID providers, lifecycle state and active failure cases; delete obsolete actor/ProcessSupport/legacy tests and only dead cases. Preserve Swift CLI and Core action runner. Final tests and ARM64 Debug/Release app/CLI builds, no-Go dependency audit, docs and per-task commit remain required.

## Constraints and architecture

One app-owned Swift runtime/device; no runtime child, C bridge or runtime-file lock. MVP assumes one app process and does not enforce singleton use. Private UUID generations retain owner-only permissions, UID/nofollow/inode checks and uncertainty-safe cleanup. Normal actor/thread locks remain. macOS 26+, app ARM64 only; unused SwiftPM Intel intermediates are not shipped.

Never read .env*, .envrc*, .aws/.gcp/.oci/.config/.ssh/secrets.yaml, environment values, PII or owner configuration without permission. No real HID/input/prompts. All gates use synthetic config and explicit simulation. Use rg/fd, full arguments where supported; no gh. Curated Git staging only; .git/.agents writes need scoped escalation. No crash-report reads. Only approved milestone notifications. Keep source frozen during gates and use the same live handle until terminal.
