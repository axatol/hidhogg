# Check-in preparation — 28 October 2026

Branch `next/lofree-flow-lite84`; baseline `f5bb00f0d1eed275e719b66b5a0e4a0d21820238`. Owner approved checking in the completed checkpoint and merging locally into the existing `master` mainline. Both local and GitHub master were verified at that baseline. No branch rename or push is part of the current request.

## Included implementation

- Native receiver-based Lofree Flow Lite84 read-only status, useful battery-event handling, connection on launch, event-driven hourly-throttled battery refresh and manual full refresh.
- Logitech disappearance/recovery refinements, stable retry presentation, clearer device menu statuses and Open Settings.
- D200X built-in wide modes/clock format and host metrics, explicit screensaver crop/upload with temporary on-device preview, lifecycle guards, retained collapsed last-sent image, and numeric-field/scheduler mode-transition corrections.
- Static app-icon notifications through API/CLI/actions/presets with text fallback. Icon plus visible text composition and count badges are not implemented.
- Default screensaver artwork and isolated synthetic Now Playing feasibility/probe artifacts; no live media provider.
- Verified decisions, owner checklists and roadmap/handoff updates.

The package/model/configuration and UI changes share dependencies; this is one complete checkpoint, not independently buildable feature commits. The candidate paths are listed in `checkin-files-2026-10-28.txt`. Local environment/configuration, caches and dist products remain excluded.

## Verification

Signed app/CLI build `fec36149ac455d36e8187bc8c9b878a5d06e8bce140f76ca21218cbf20f2a66d` has strict signatures and229input hashes. Latest targeted independent gate:38checks with25matching pre/post/build hashes; /tmp/dx-wide-store-independent.log. Earlier206display/icon,69battery and75activity gates retain their dated evidence and are not summed as disjoint cases.

Consolidated merge-readiness suite passed635/635 checks (351XCTest and284SwiftTesting cases). Independent correctness/specification review found no remaining blocker after the two owner-approved corrections. This run excludes WakeConnectionTests (known historical fake-delay orphan hazard) and opt-in NativeWorkspaceWindowTests; it must not be described as an unrestricted full suite. No live app, devices, real endpoint, platform effects or permissions are exercised.

## Acceptance and remaining work

Owner confirms the latest wide-mode switching and retained screensaver preview appear to work. Earlier notification/scripts/media/rendering and UI/recovery confirmations remain scoped to their dated reports. Device screensaver activation/timing/power-cycle persistence/lock/sleep, keyboard battery precision/lighting/OS mapping, receiver reply origins and some platform effects retain separate owner gates. These do not imply incomplete code in the approved checkpoint.

New work is paused until check-in completes: additive app icon plus text with above/below placement and fitting; optional per-profile/tile notification badges with acknowledgment/expiry/duplicate-ID semantics; MCP read/configuration/refresh coverage of user-editable UI fields. MCP transport/access design and detailed implementation plan remain to be settled. No source changes for these new features are included.

The previous publication record is preserved in [26 October check-in preparation](checkin-preparation-2026-10-26.md).


## Consolidated-gate correction

First ordinary run executed635checks (351XCTest,284SwiftTesting):634passed, one Logitech parameter case failed. The isolated two-case rerun passed. Review identified a recorder synchronization race introduced by the new intermediate discovering event: ownership false could satisfy the wait before ready arrived. Owner approved a test-only correction; the eventual predicate now checks ownership and phase from one recorder snapshot. Production code is unchanged. Targeted and consolidated reruns are pending; the first failing log remains preserved.

First log: /Volumes/Data/cache/hidhogg-workspace-independent/CHECKIN-VERIFY-20261028T133458Z-3fed1a03/logs/swift-test.log. Isolated rerun: same directory/logs/targeted-rerun.log. The failure is not discarded by an isolated pass; commit/merge waits for the corrected consolidated gate.


Second consolidated run again executed635checks: all284SwiftTesting cases passed, while one of351XCTest cases failed at the immediate empty action-history assertion. The method passed once in isolation. Source review found baseline f5bb00f already had the same publication race: a concurrent refresh can supersede clear's refresh, allowing Clear to return before the published array updates. Owner approved the two-line correction after runner clearing: invalidate earlier reads again and set the published history empty, retaining the subsequent refresh for newly admitted actions. No assertion was weakened. Current targeted/consolidated rerun and signed rebuild are pending.

Second failing log: same gate directory/logs/consolidated-after-testfix.log. Both failures and their isolated passes are retained as evidence; neither is hidden by a later pass.


## Final merge-ready gate

Final635/635ordinarychecks pass, with only the two named suite exclusions. The targeted Bolt parameter cases and action-history method also passed; these overlap the consolidated count. After signed rebuild,284input hashes match pre/post/build (aggregate59f5fbbd6f5451c88d91f95efab462f7daccd932c297b4c723b710fbb7bc4fcc). No owned test/compiler processes remain. Strict app/CLI signatures and CLI help pass; no live endpoint was contacted. Final log: gate directory/logs/consolidated-after-coordinator-fix.log; final manifest: gate directory/post-signed-build-manifest.json. Build log: /Volumes/Data/tmp/hidhogg-checkin-release-20261028.log. Earlier pending/failure notes above preserve chronology; this final gate supersedes their status.

Final explicit checkpoint scope is99files. The approved production history correction and test-only recorder synchronization correction are included. The index will be audited against working bytes and the229-input signed-build manifest before committing; master integration uses fast-forward only. No new feature code or remote publication is included.
