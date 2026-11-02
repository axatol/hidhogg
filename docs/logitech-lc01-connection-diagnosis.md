# LC-01 connection diagnosis — 1 November 2026

Owner reports ordinary mouse input works over Logi Bolt while Hidhogg shows Disconnected, Cancel and “Mouse unavailable”. Production source remains unchanged during diagnosis.

## Observed failure

Owner approved reading only Hidhogg structured diagnostic codes/status messages/build ID from the preceding 15 minutes. No receiver commands, live inventory, identifiers, raw reports, private configuration or other applications' logs were inspected.

The bounded read returned 83 matching structured events from build `96deafbe8257702abf8b6de0e17fa097c4312c192a03f23b51151db2f8cb9c01`. Representative attempts on 1 November 2026 at 19:06:01, 19:08:14 and 19:10:48 Brisbane time report `bolt.endpoint.ambiguous`: “Multiple Bolt endpoints or device slots require explicit association. Delivery stopped.” Cleanup also reported verified during the observed window. The evidence supports ambiguity as the reason these connection attempts fail; it does not establish which ambiguity branch fired or the physical device topology.

Source branches: `IOKitBoltTransport.open` refuses more than one eligible HID endpoint; `BoltController.openCandidate` refuses more than one responsive root-protocol slot. Existing generic background recovery text hides this distinction as mouse unavailable. Choosing the first candidate would violate the ownership/association boundary.

## Separate reproduced regression

Bounded existing fake test `WakeConnectionTests/testTransientDiscoveryFailureThenSuccessRestoresConnection` passes. `WakeConnectionTests/testWakeRecoversAfterUncertainCleanup` fails in about 1.46 seconds: one discovery instead of two, phase failed rather than ready, cleanup uncertainty retained. Reproduction log `/Volumes/Data/tmp/hidhogg-uncertain-cleanup-repro.log`; transient diagnostic `/Volumes/Data/tmp/hidhogg-lc01-reconnect-diagnostic.log`. Both used `swift test --skip-build` with a 25-second process-group limit and no hardware access.

The controller retains cleanup uncertainty until fresh discovery verifies capabilities/native reporting; LC-01's cleanup-success gate can prevent same-owner fresh verification. Any fix must preserve refusal to transfer to another registration after unverified cleanup. This is a real regression in an explicitly excluded wake test, but is not demonstrated as the cause of the owner's repeated ambiguity events.

## Next decision

Await owner confirmation of receiver/device topology. Use explicit endpoint/slot selection (LC-02) rather than guessed adoption where multiple devices are present; improve error presentation to identify association-needed status. Separately scope same-owner recovery without weakening cross-registration ownership. No production code edits or new pairing performed. The owner also supplied the later Bolt functionality coverage report, linked from the connectivity plan for subsequent pairing work.
