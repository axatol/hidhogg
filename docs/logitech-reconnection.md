# Automatic Logitech recovery — 2026-10-26

## 27 October 2026 follow-up — wireless loss detection

The owner reported that wireless mouse loss left the app showing connected and prevented recovery. USB receiver removal alone does not cover that case. A controller-owned monitor now sends the existing read-only root protocol/nonce query every three seconds while ready or enabled, skipping busy operations. Request failure invalidates delivery and enters existing cleanup and recovery. Closing the transport cancels the monitor; results from superseded connection or lifecycle operations cannot fail the new session.

The app also clears attempted settings reconciliation on fresh discovery and records wheel requests only when dispatched. These changes are built and signed, but physical disconnect/reconnect and restored settings remain unverified. The owner requested regression tests after physical confirmation; no new tests were added or run for this follow-up. The verification table below describes the earlier checkpoint only. Current build provenance is in `dist/build-info.json`; final build log: `/Volumes/Data/tmp/hidhogg-mouse-connection-monitor-final-20261027.log`.

The owner subsequently reported recovery works better and approved background retry presentation. Waiting and unsuccessful probes show Disconnected; Reconnecting requires a responsive mouse undergoing capability/session recovery. Header copy, the Cancel control and the menu-bar mouse indicator remain stable across unavailable-device probes. Detailed retry and cleanup messages remain in Diagnostics. This presentation change still requires owner visual confirmation.

Implemented under the owner-approved exclusive mouse ownership policy. Unexpected loss and unsuccessful initial discovery now retain connection intent and retry automatically. Explicit Disconnect cancels that intent; sidebar navigation does not affect ownership.

## Completion checklist

- [x] Reproduce the old lockout with failing fake-transport/session regressions.
- [x] Close the old transport before discarding session ownership and feature indices.
- [x] Re-query capabilities, reclaim recognised routing and verify readback before Ready.
- [x] Preserve only wheel/thumb-wheel verification requirements when their cleanup was uncertain; absent or unsupported required features cannot bypass verification.
- [x] Use one cancellable retry loop with delays capped at 30 seconds.
- [x] Preserve requested recovery across sleep/wake and stop it on Disconnect, Restart or Quit.
- [x] Reapply current settings through normal reconciliation; reset scroll fractions on session loss while preserving capture across button-only generation changes.
- [x] Provide Cancel Reconnect and replace the permanent-lockout warning.
- [x] Independently verify application and controller suites; rebuild and sign the fixed-path app and CLI.
- [ ] Owner physical acceptance of reconnection, buttons and both wheels.

## Boundaries and decisions

The controller owns transport, capability discovery, recognised routing reclamation and verification. The app owns connection intent, retry scheduling and settings reconciliation. Unknown or malformed protocol state keeps delivery inactive while recovery retries. Exclusive ownership does not make an unverified reply valid.

Fresh discovery discards old feature addresses and ownership values only after closing the old transport. Two kind-only routing requirements survive failed wheel/thumb cleanup or pending Connect reclamation. They clear after the whole fresh reclamation transaction verifies. Optional features remain optional when no prior uncertain ownership requires them.

The coordinator yields once after its delay so queued status events can run even when a synthetic test delay completes synchronously. Terminal sleep cleanup statuses are drained before discovery, including failed/uncertain cleanup. Older-generation statuses cannot revive a timed-out session.

Orderly stop still attempts cleanup. No configuration schema, dependency, device pairing, live app state or D200X feature was changed by this task. Unrelated dirty checkout work remains preserved; no commit or push was made.

## Final verification

| Gate | Result | Evidence |
|---|---|---|
| Independent application tests | 255 passed | `/Volumes/Data/tmp/hidhogg-reconnect-independent-final-pty-20261026.log` |
| Independent Logitech tests | 149 Swift Testing functions passed, including parameterised cases | Same final independent log |
| Separate Logitech gate | 149 passed | `/Volumes/Data/tmp/hidhogg-reconnect-logitech-only-final.log` |
| Signed arm64 app and CLI | Built; strict signatures passed; CLI help passed | `/Volumes/Data/tmp/hidhogg-reconnect-release-final.log` |
| Source provenance | 193 current input hashes verified | `dist/build-info.json` |
| Native device/UI acceptance | Not run | Owner checklist below |

Final independent command: `swift test --package-path app --scratch-path /Volumes/Data/cache/hidhogg-reconnect-verification --filter HidhoggAppTests\|LogitechBoltTests --skip NativeWorkspaceWindowTests`, run with a bounded PTY harness; exit 0.

Signed app: `dist/Hidhogg.app`; adjacent CLI: `dist/hidhoggctl`. Build ID: `7201f4cc38c4f4744cab627485d7435286fa836926bcf1a5e729c4426e0a7308`. The app executable is 9,757,360 bytes; CLI is 1,147,952 bytes. Builds did not launch or restart the running app. Prior build metadata is preserved at `/Volumes/Data/tmp/hidhogg-reconnect-prior-build-info.json`.

The broader unfiltered package run had one failure in the untouched-by-this-task `D200XUsabilityTests.testClearActionHistoryKeepsRunningAndQueuedActionsWithoutReappearance`, line 186 (`/Volumes/Data/tmp/hidhogg-reconnect-logitech-final.log`). The same case passed in the final independent application run. Its cause remains unproven; this checkpoint does not claim a clean full-package run.

Red evidence is retained in `hidhogg-reconnect-controller-red.log`, `hidhogg-reconnect-app-red.log` and `hidhogg-reconnect-routing-requirement-red.log` under `/Volumes/Data/tmp`. Earlier bounded timeout logs are historical failed attempts, superseded by the final green gate.

## Owner acceptance checks

1. Relaunch the signed `dist/Hidhogg.app`.
2. Disconnect the mouse or receiver, then restore it. Confirm reconnection without navigating or pressing Connect; verify saved buttons and both wheel settings.
3. While the receiver is unavailable, choose Cancel Reconnect. Restore the receiver and confirm Hidhogg stays disconnected until Connect is chosen.
4. Sleep and wake while connected or waiting to reconnect. Confirm one recovery flow resumes; switching sidebar pages must not affect it.

Retry delays cap at 30 seconds; transport discovery and settings verification add their own bounded work. The cap is not a measured reconnection-latency guarantee. The physical cause of the original disconnect remains unknown.
