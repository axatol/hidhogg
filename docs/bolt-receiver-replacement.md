# Replacement Bolt receiver — diagnostic checkpoint

2 November 2026. Base is master `3e5e6ee`; BIND-01 is accepted and committed. Approved connection-flow corrections and offline tests are now uncommitted; verification is in progress.

## Verified facts

- Owner approved anonymous read-only HID inventory: vendor/product IDs, endpoint counts and report eligibility only; no names, serials, addresses, raw reports, HID commands or pairing writes.
- The owner corrected an earlier physical-state assumption: the new receiver had not been plugged in during the first new-only capture.
- After it was plugged in, the approved inventory found one USB `046D:C548` receiver and one eligible long-report HID endpoint (20-byte input/output). The receiver passes the current catalog predicate. Other interfaces fail eligibility as expected; no identity is inferred from their numeric indexes.
- Latest owner screenshot is Change Connection for MX Master 4: “The previous connection could not be released safely. Disconnect and retry.” No live endpoint was verified in that screen.
- AppModel gates setup/pairing on `stopForRestart` success plus a settled controller status with `cleanupUncertain == false`. The same message covers failed cleanup, uncertain cleanup, or a missing settled status.
- BoltController retains uncertainty after failed shutdown; repeated stops do not establish that restoration succeeded. Existing recovery permits rediscovery of the same saved target before clearing uncertainty.
- Existing synthetic `BoltPairingIntegrationTests.testUncertainCleanupNeverInventoriesReceiver` passes (1/1, 0.018 seconds), verifying that explicit cleanup failure produces this message and prevents receiver inventory. Log: `/Volumes/Data/tmp/hidhogg-receiver-cleanup-gate.log`. This does not establish which condition occurred in the owner's running app.

## Remaining question and proposed scope

Receiver removal during management could leave cleanup unverified; a status-wait failure can produce the same UI. The physical cause remains unconfirmed. Reconnecting the previous receiver was suggested as a workaround, not a protocol requirement.

The owner challenged the old-receiver prerequisite: Change Connection should preserve the registration/settings while allowing pairing to a selected replacement receiver even when the old receiver is unavailable. The current code's global cleanup gate is broader than that intended flow. Approved after crash-first investigation: separate verified local shutdown/drain from remote-device cleanup, retain unresolved cleanup attribution/warnings, permit selected-receiver pairing after local quiescence, then verify/reconcile the new connection before delivering bindings. Do not erase ownership/uncertainty merely to report successful cleanup.

The owner subsequently removed/unpaired and retried; Hidhogg crashed after the click challenge. Crash-first investigation was approved; the baseline UI exercises have not reproduced it. [Approved evidence, intended flow and current correction](bolt-pairing-completion-crash.md). No live pairing/device writes were performed by the agent.
