# Candidate stability, challenge UX and recovery — offline verified and signed, 2 November 2026

Owner reports MX Master 4 rows repeatedly appearing then disappearing, plus a later uncertain pairing with no obvious Retry. Owner confirms Pair was clicked and the ten-click challenge appeared. First screenshot: 34 typed advertisements, all 34 decoded, one assembly rejection, two discovery status events; notification setup and restoration verified. Second screenshot: pairing outcome uncertain. These are distinct attempt stages; they do not prove one root cause.

Owner also requests prominent highlighting of the current challenge action. Missing padding across surfaces is explicitly deferred and recorded separately.

- [x] Inspect candidate assembly, status cleanup and retry guards.
- [x] Confirm implementation scope before code changes: owner approved on 2 November 2026.
- [x] Reproduce repeated-beacon/transient-counter and mutable-byte cases with synthetic reports; distinguish reproduced synthetic failures from the unconfirmed physical rejection branch.
- [x] Keep one stable candidate for repeated observations where identity is supported; retain model/address/authentication checks and bounded assembly limits.
- [x] Preserve the original failure reason when cleanup closes a failed discovery session.
- [x] Add clear recovery that rechecks current devices/receiver inventory after uncertain pairing before offering another attempt; never blindly resend Pair or undo a bond.
- [x] Highlight the current receiver-confirmed click, dim completed steps, separate the simultaneous-button confirmation and waiting-for-result stage.
- [x] Verify synthetic state/recovery/challenge regressions, independent gate and signed build.
- [ ] Owner verifies candidate stability, challenge progression and real recovery.

## Evidence and uncertainties

Current assembly uses the transient two-byte discovery key and compares complete report bytes when the same part repeats. It allocates separate candidate IDs per assembly and globally fails at candidate/assembly limits or a conflicting fragment. The vendor research labels this counter transient, not a physical identity. Both changing counters and changing non-identity bytes are therefore test hypotheses; the screenshots alone do not identify which rejection occurred. Semantic conflicts in model, session address or authentication must remain protective.

`close()` can replace a discovery failure with “Pairing was closed before selection.” Preserve the first actionable failure instead of hiding its cause. Retry blocking after a possible C1 pairing write is intentional: the receiver bond may exist. The user-facing recovery needs an obvious refresh/reconciliation path and current Devices wording, rather than silently bypassing this protection.

Challenge progress is sourced from receiver entry events; the UI must not advance based on guessed clicks or synthesize input. Owner confirms the ten-click sequence was entered incorrectly and the challenge failed. This does not establish the receiver error code; synthetic terminal-event tests must preserve that distinction. New Bluetooth pairing and padding changes remain outside this proposal. No live device reads/writes, raw captures or private logs are authorized for diagnosis here; implementation is approved; physical pairing remains owner-operated.

## Synthetic reproduction — 2 November 2026

`repeatedDiscoveryCountersRetainOneSelectableCandidate` failed before the candidate fix: repeated reports with identical parsed device metadata and changing transient counters produced duplicate selectable UUIDs, then hit the candidate bound. The run reported 114 failed assertions; log: `/Volumes/Data/tmp/hidhogg-pair-recovery-counter-red.log`. The additive defaulted challenge `entryComplete` property was introduced first so concurrently added UI code compiled; candidate behavior remained unchanged for this RED. This reproduces a plausible disappearance mechanism without proving the exact hardware attempt used that branch.

## Protocol references

The pinned [Solaar error constants](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp10_constants.py) distinguish Bolt timeout `0x01` and generic failure `0x02`; generic failure is not proof of an incorrect PIN or click sequence. The pinned [notification handling](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/notifications.py) provides corroborating event semantics. Local technical evidence: `~/Workspace/ai/rea/investigations/logi-options-plus/hidhogg-pairing-mouse-protocol-spec-2026-11-01.md`. No private reports or manual-result captures were read for this slice.

Backend checkpoint: the counter case is GREEN after canonical assembly matching. Receiver entry-completion first failed three assertions, then passed after event state propagation. Terminal authentication failure first failed seven behavior assertions, then passed with matching challenge/address and fresh unchanged inventory. Negative cases preserve uncertainty for missing challenge, address mismatch, changed/unreadable inventory, timeout, unknown error and nonterminal status; late matched success remains verifiable. Focused logs use `/Volumes/Data/tmp/hidhogg-pair-recovery-*.log`. Independent whole-slice validation is still pending.

## Independent gate iteration 1

The first focused gate failed: 60 XCTest cases produced 11 failed assertions across four cases; the Swift Testing run reported 239 tests and two failed assertions in one diagnostics test. First log is preserved at `/Volumes/Data/tmp/hidhogg-pairing-recovery-focused.log`; full gate was correctly withheld. Review follow-up is in progress. The backend diagnostics fixture advertised different models with the same synthetic session address, correctly triggering the new conflict protection; the fixture is being separated into distinct peers. App follow-up covers normal refresh revocation during receiver management, changed post-failure refresh requirements and repeated-use fake close readiness. No passing-delivery claim yet.

## Review iteration 2

The backend diagnostic fixture now uses distinct synthetic session addresses for distinct advertised models; original event-count assertions remain. Ordinary Refresh again revokes/drains pending receiver management, while recovery retains its stricter cleanup/freshness gate. Existing post-failure tests now explicitly refresh before Add/Pair, and repeated attempts use fresh session/event-stream fixtures like production. The four failing app cases pass in the bounded author rerun: `/Volumes/Data/tmp/hidhogg-pairing-recovery-focused-app-iteration2-retry.log`. Independent source review has no outstanding actionable finding. Final 321-input manifest was recaptured; independent whole focused/full gates are running. The first manifest is preserved separately as `hidhogg-pairing-recovery-iteration1-inputs.json`.

## Independent full-gate follow-up

Iteration 2 focused gate passes 299 tests (60 XCTest + 239 Swift Testing). The first full gate ran 1,032 tests (620 XCTest + 412 Swift Testing): two `ThumbwheelModelTests` cases produced 15 assertions; all Swift Testing cases passed. The failure is preserved as `/Volumes/Data/tmp/hidhogg-pairing-recovery-full-iteration2-failed.log`. An explicitly authorized isolated run passes all four thumbwheel model tests, including the two failing cases, at `hidhogg-pairing-recovery-thumbwheel-isolated.log`. This does not prove flakiness or establish cause.

Read-only diff review found no change to wheel delivery paths. It identified a test timing sensitivity: `SenderTestClock` is initialized before model connection and first events use its fixed timestamp plus 1 ms, while the runtime lease rejects events predating its real `startedAt`. Initialization longer than 1 ms could cause the observed missed admissions; that timing was not measured in the failed run. No thumbwheel source/test was changed. One unchanged-source full repeat is authorized at `hidhogg-pairing-recovery-full-retry.log`; delivery remains pending its result.

## Final delivery — 2 November 2026

Independent focused gate passes 299 tests (60 XCTest + 239 Swift Testing). The unchanged-source full repeat passes 1,032 tests (620 XCTest + 412 Swift Testing), including all four thumbwheel model cases; the initial failure did not recur in isolation or that repeat, and its cause remains unconfirmed. Existing exclusions remain exactly `WakeConnectionTests` and `NativeWorkspaceWindowTests`. No thumbwheel implementation/test changes or additional exclusions were made.

Signed app and CLI pass strict signature verification; CLI help exits 0 without contacting the app. All 321 input hashes match the final manifest after tests/signing. Build ID: `2434478ad6e8b8c88eaf7ac2e5f625dd80328cebafded6464530def9607a685b`. Release/help logs: `/Volumes/Data/tmp/hidhogg-pairing-recovery-release.log` and `hidhogg-pairing-recovery-cli-help.log`; complete metadata: `dist/build-info.json`. Source remains uncommitted/unstaged on master `3dc576fcadfd41e2fedba4761efbce719704f2bc`; no push, production launch or live device operation occurred.

Owner acceptance remains open: confirm one stable MX Master 4 row while discoverable; follow the highlighted click sequence and separate both-button instruction; deliberately fail a sequence and use Refresh Devices after cleanup; verify successful pairing/Add or a safe explicit new attempt. Real pairing, VoiceOver and native layout remain unverified. General padding and battery notification icon changes remain deferred; new Bluetooth pairing is the next slice.
