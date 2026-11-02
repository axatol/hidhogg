# Receiver notification setup and unified devices — 2 November 2026

Owner approved retaining last-read stored pairings during discovery and temporarily enabling the documented wireless/software-present notification bits with verified setup and guarded cleanup. Synthetic verification only: no agent-operated flag writes, pairing or new live probe is authorized. Physical effect remains an owner check.

- [x] Preserve current source baseline for bounded diffs.
- [x] Implement baseline-preserving notification setup before discovery.
- [x] Verify setup readback, serialized cancellation/close and guarded restoration.
- [x] Confirm updated unified-list scope and replace separate Stored Pairings/Existing Mice presentation.
- [x] Retain display snapshots while revoking stale mutation authority.
- [x] Run independent synthetic gates and sign the app.
- [ ] Owner verifies discovery/event delivery and unified-list behaviour.

## Notification contract

Register `0x00` is a three-byte big-endian mask. Required bits: wireless `0x000100` and software present `0x000800`. Read the current mask, preserve other bits, add only missing required bits, and verify readback before issuing `C0` discovery. An already-enabled baseline requires no write and grants no cleanup ownership. Record possible mutation before awaiting write; acknowledgement alone is insufficient.

Cleanup drains any admitted setup operation. Re-read the current mask, remove only bits Hidhogg added when the expected mask still establishes ownership, preserve all other bits, and verify restoration. Unexpected external changes or a poisoned/timeout channel produce a separate cleanup warning and no blind overwrite/resend. Retain a verified pairing outcome even if notification cleanup cannot be verified. The register API has no atomic compare-and-set, so an external-writer race remains possible.

This is an owner-approved test of the zero-mask hypothesis, not a confirmed cure for physical discovery. Public source: [flag definitions](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp10_constants.py#L101-L104), [three-byte flag read/write](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp10.py#L175-L208). Do not copy the GPL implementation.

## Unified-list steering

Owner subsequently requested merging stored pairings into Existing Mice so one list can show Bolt/Bluetooth devices, remembered/disconnected devices and new pairable candidates. Proposed heading: Devices. Keep last-read rows visible during discovery, with state-appropriate Add/Open/Pair/Unpair actions. Names alone never authorize cross-transport merging. A stale display snapshot must not retain Unpair authority; a fresh inspection is required before a stored bond can be removed.

Owner confirmed the recommended scope: combine current stored Bolt records, existing verified Bolt/Bluetooth mice, Hidhogg-remembered mice and newly discovered Bolt mice. New Bluetooth discovery/pairing remains the next slice. The UI uses one Devices group with state/provenance labels and puts ready-to-pair results first. Stored snapshot presentation is separate from fresh unpair authority.

Baseline source copies: `/Volumes/Data/tmp/hidhogg-notification-setup-baseline/app/`. All315 inputs matched the previous signed source manifest when captured. Current delivered baseline: build `dc187c06641e5539dfdd7f641af5815449ab97ac38545bcb7524bb6696df0450`, full990 passing cases with the documented intermittent thumbwheel assertion and two suite exclusions. Broad dirty master and old worktree remain preserved.

## Progress checkpoint

Backend setup/readback/cleanup passed its first synthetic gate. Review then exposed duplicate Cancel starting cleanup before C0 cancellation drained, and event-overflow uncertainty arising during a suspended notification read. Deterministic red regressions reproduced both; fixes coalesce the whole cancellation/cleanup transaction and recheck channel safety at request boundaries. Final verification is pending these corrections.

The AppModel cache collects all receivers serially after the existing endpoint scan. A full successful refresh must atomically replace cached inventories/labels because native enumeration assigns fresh opaque IDs each time; old rows remain read-only while loading/failure, never accumulate as duplicate current records. The unified UI removes the old Stored Pairings card and duplicate candidate rows, retains setup/cleanup diagnostics, and renders management messages in the Devices list.

## Delivered verification — 2 November 2026

The active setup now has one Devices group: ready-to-pair Bolt candidates first, then available verified endpoints, Hidhogg-remembered registrations and stored Bolt inventory snapshots. Stored entries show receiver/slot provenance; names never merge physical identities. Complete nonempty receiver refresh atomically replaces cache/labels with fresh opaque IDs. Zero accessible receivers retain the last read only as stale. Pairing and Cancel retain stale display data while management authority closes; Unpair requires the exact current inspected snapshot, not a cached row. Normal setup exit clears the cache. New Bluetooth discovery/pairing remains the next slice.

Notification setup adds only missing0x900 bits, preserves other baseline bits and verifies readback before C0. Cleanup conservatively checks the current expected mask, restores only owned additions and verifies readback. Channel uncertainty or external changes skip restoration without a blind retry. Fixed setup/cleanup messages remain in Discovery details; final uncertainty uses the existing workspace alert across Cancel rebuilding and successful navigation, retaining any existing error text. Verified pairing still saves/activates despite a cleanup warning.

Review regressions reproduced and fixed overlapping cleanup from duplicate Cancel, authentication-timeout pair cancellation, uncertainty arriving during a suspended read/write, admitted verification, and late terminal success during cleanup. Cancellation and pair-cancellation completion are coalesced; verification/cleanup obey admission order without a wait cycle, and release drains late verification. Unresolved post-pair cleanup waits for close. Explicit LC-04 cancellation outcomes remain unchanged. The external-writer read/write race remains unavoidable; the guard protects only observable changes.

Independent focused gate passes278 cases (51 XCTest+227 Swift Testing). Full offline gate passes1,011 cases (611 XCTest+400 Swift Testing), zero failures, excluding existing WakeConnectionTests and NativeWorkspaceWindowTests. The previously intermittent thumbwheel assertion passed both gates. New tests cover all-receiver serial reads, cache/Cancel retention, renewed UUID replacement, fresh Unpair gating, and retained settings. Cleanup-warning tests are red-capable and use the actual Cancel setup-rebuild route and successful save/navigation route.

Signed app/CLI build `1861e1513027e5044aec8e1433c3cda8a6eed4f0f325098123d6f2225ba311a6` passes strict signatures and CLI help; all318 captured source/test/build inputs match. Logs: `/Volumes/Data/tmp/hidhogg-notification-unified-{focused,full,release}.log`; manifest `/Volumes/Data/tmp/hidhogg-notification-unified-inputs.json`; current metadata ignored `dist/build-info.json`. Source remains uncommitted/unstaged on master; no push or production app launch. No agent-operated receiver read/write occurred in this slice. Earlier approved read-only mask0 remains historical evidence, not a fresh live reading.

Owner next check: restart with the signed app, inspect the unified list, retry the intended mouse in pairing mode, and check notification setup/readback, event counts and cleanup results. Physical discovery/pairing/temporary flag restoration remain unverified. No radio timeout-fix claim follows from offline tests. Notification icon follow-up remains deferred.
