# Logitech discovery UI follow-up — 2 November 2026

Subsequent approved implementation: [temporary verified notifications and unified Devices](logitech-notification-discovery-plan.md) supersedes the historical no-notification-write boundary below. The approved implementation was tested synthetically only; agents did not operate real flag writes.


## Native-boundary follow-up delivered — 2 November 2026

Owner supplied a timeout screenshot with all typed-event counts zero, then approved a bounded read-only notification-flag check and native callback/filter counters. This extends the earlier instrumentation scope; it does not authorize enabling notification flags or new pairing/configuration writes. Owner also asked that the additional technical investigation documents be consulted. Manual run records, private logs and raw captures remain excluded.

- [x] Read notification register once per attached receiver, reporting anonymous index and public flag categories only.
- [x] Consult additional technical receiver-startup/event-routing research.
- [x] Add native RAM counters and final snapshot retention without changing filters or receiver writes.
- [x] Run synthetic callback-boundary and existing-session tests, sign and record results.
- [ ] Owner checks the next attempt's native/typed counts; any notification-write policy needs separate approval.

Approved read-only result: one eligible receiver, notification mask `0x000000`; wireless and software-present bits off, no other bits set. No names/addresses/serials/unit IDs/raw reports printed or retained. The standalone probe sent only a read of receiver register `0x0000`, then closed; no flag, pairing or configuration writes. This supports disabled-notification setup as a hypothesis, not proof that these flags control Bolt discovery. [Primary receiver notification setup](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/receiver.py#L207-L227) enables and reads flags; discovery-specific causation remains unverified.

Native counters report callbacks, callback failures, metadata rejection, report-ID mismatch, matched register/feature replies, forwarded receiver notifications and unmatched reports. The transport snapshot reads RAM only; no per-report stream or periodic HID query is added. Unavailable snapshots are explicit for synthetic/unsupported transports. Names, identifiers, contents and raw bytes remain outside diagnostics.

Additional research: `protocol-workflows.md:96–97` corroborates the short `C0 [30,1]` start request; `:134–147` and the pairing protocol spec distinguish `0x53` state/error fields from device addresses. The broader coverage report `:52,75` explicitly leaves startup notification policy unresolved and distinguishes connection/link events from discovery/pairing events. These findings support measuring the earlier boundary; they do not justify guessing a notification write mask. The old connectivity report's sender limitations are historical and must not be mistaken for the current short/long register implementation. Research was restricted to the named technical documents, excluding manual-result records/raw captures.

Review identified an out-of-order RAM snapshot race: an older same-generation snapshot could replace newer close-time counts. The deterministic regression reproduced a final callback count falling from 14 to 7 before the fix. Snapshots now merge availability with OR and each count with max after the generation guard; the next attempt still resets all counts. The delayed-close regression and mixed-order merge test pass, along with all211 backend tests. Final source-frozen verification is recorded below.

Verification observation: the first final focused run failed the existing `thumbwheelPendingCaptureEventsAreNotReplayedAndPermissionIsFresh(deny: true)` immediate `recorder.last` blocker assertion at `BoltThumbwheelTests.swift:392`. Its no-write/no-replay assertions passed. The subsequent full990-case gate passed, including that case. The test awaits the controller operation but does not explicitly await the separate status recorder before this assertion; scheduling sensitivity is a hypothesis, not a confirmed production defect. No thumbwheel production/test code was changed. The isolated check passed both parameter cases, and one focused retry passed all249 cases. Keep the failed log as evidence; no cause was established and no thumbwheel code was changed.

Owner reports Stored Pairings requires two clicks to expand, and new-mouse discovery waits until timeout. Owner approved disclosure/loading fixes and anonymous per-attempt event counters. This slice does not establish or claim a fix for physical radio discovery.

- [x] Inspect adaptive layout and discovery loading/state seams.
- [x] Replace duplicate adaptive view trees with a single identity-preserving layout and parent-owned disclosure state.
- [x] Regress and fix the receiver-checking spinner during active discovery.
- [x] Add anonymous typed-event counters and a selectable Discovery details view.
- [x] Run independent synthetic checks and signed build.
- [ ] Owner verifies first-click expansion/resizing, then retries pairing and checks event counts if discovery times out.

The old `ViewThatFits` contained separate horizontal/vertical copies of the stateful Bolt section. Expansion could change the fitting branch and reveal the other copy's collapsed state. Replace it with one `AnyLayout` subtree, chosen by available width, and own expansion in `LogitechSetupView`. One parent change handler performs receiver inspection/close.

`receiveBoltPairing` previously ended receiver-loading only at awaitingSelection/terminal cleanup, leaving “Checking Logi Bolt receivers…” visible while discovering. Regress discovering/authenticating/verifying so those phases remain active without the receiver-checking indicator.

`BoltDiscoveryDiagnostics` contains counts only: typed advertisement events, decoded/rejected fragments, unsupported-model metadata, discovery-status/recovery events and transport failures. Counts reset per attempt and remain in terminal status snapshots; no names, IDs, addresses, raw reports, passkeys or content enter diagnostics. They count events forwarded by the receiver transport, not all raw HID traffic. No private log reads, live receiver operations or production app launch are authorized for agent verification here.

Physical timeout causes remain unconfirmed: no advertisement may arrive, fragments may be rejected or incomplete, or event delivery/setup may be incomplete. Do not guess new notification-register writes from the timeout alone. The next owner-operated attempt and anonymous counts will guide a bounded follow-up.

## Delivered verification — 2 November 2026

The loading regression failed at all three discovering/authenticating/verifying assertions before the fix, then passed; the pairing integration suite passes 13 cases. Counter tests cover zero events, valid/incomplete/duplicate/unsupported/malformed fragments, status/recovery/failure events, reset, close retention and verified-result preservation. Decoded and rejected counters are not disjoint: a valid decoded fragment may subsequently be rejected by assembly validation. Identical valid duplicates count as events/decoded but not rejected; unsupported metadata counts separately.

Independent focused gate passes 240 cases (38 XCTest +202 Swift Testing). Full offline gate passes 981 cases (606 XCTest +375 Swift Testing), zero failures, retaining existing WakeConnectionTests and NativeWorkspaceWindowTests exclusions. Static review confirms one AnyLayout child tree/parent observer, phase-correct receiver loading and numeric-only diagnostic snapshots preserving the existing status fields. No complete previous source copy was available for an exact whole-file protocol diff; review was bounded to changed instrumentation paths and mutation-call inspection.

Signed app/CLI build `127d4c1e809c010592721351ecdd406aacdfc048b34b59c272b5ca156b7537b7` passes strict signatures and CLI help; all313 captured inputs match. Logs: `/Volumes/Data/tmp/hidhogg-discovery-ui-{focused,full,release}.log`; manifest `/Volumes/Data/tmp/hidhogg-discovery-ui-inputs.json`; current metadata ignored `dist/build-info.json`. Source remains uncommitted on master; no push or native app/device operation performed.

Owner next check: click Stored Pairings once and resize the pane; retry discovery with the intended mouse in pairing mode. If it times out, expand Discovery details and share the numeric counts. Counts alone do not prove a radio cause: zero typed advertisements may mean no radio advertisement, no event delivery, or an earlier transport/parser boundary. Physical discovery timeout remains unresolved, and no notification-register write policy was added in this slice.

### Final native-boundary verification — 2 November 2026

Full offline gate passes 990 cases (606 XCTest +384 Swift Testing), with the same two existing suite exclusions. Focused retry passes249 cases (38 XCTest +211 Swift Testing). An initial focused run failed the pre-existing asynchronous thumbwheel recorder assertion described above; full, isolated and focused retry runs passed afterward. This intermittent observation remains part of the verification record, not a confirmed native-diagnostic regression. Final logs: `/Volumes/Data/tmp/hidhogg-native-rx-final-{focused,focused-retry,full}.log` and `hidhogg-native-rx-thumb-isolated.log`.

The two snapshot-order tests reproduced count regression before the monotonic merge and passed afterward. Review found no remaining actionable issue in numeric-only storage, existing callback filters/matcher ordering, serialized RAM snapshots, unavailable fallback or complete status-field cloning. Unmatched reports include ordinary device traffic and malformed/unclassified frames; they are not necessarily dropped reports. No per-report stream or new notification-write policy was introduced.

Signed app/CLI build `dc187c06641e5539dfdd7f641af5815449ab97ac38545bcb7524bb6696df0450` passes strict signatures/help, and all315 source/test/build hashes match `/Volumes/Data/tmp/hidhogg-native-rx-final-inputs.json`. Release log: `/Volumes/Data/tmp/hidhogg-native-rx-final-release.log`; metadata: ignored `dist/build-info.json`. Source remains uncommitted/unstaged on master; no push or production app launch. One separately approved read-only flag query was performed as recorded above; no flag/configuration/pair/unpair writes were performed by the agents.

Owner next step: restart with this signed app, retry discovery, then share Discovery details including native counts. The current evidence does not establish whether notification flags suppress discovery or where physical events are lost. Additional notification writes require a separately reviewed/approved policy, rather than inferring causation from mask0.
