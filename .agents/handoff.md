# Hidhogg handoff

Updated: 2026-08-27

## Current objective

Select and plan the milestone after the completed Go-only `M-02` config-driven D200X vertical slice.

## Completed state

- `M-02` is complete. One strict TOML file drives one configured 14-position D200X page, brightness, and bounded decoded input events through the direct Go runtime.
- Full cgo-free Go build/test/race/vet, deterministic schema generation, `go mod verify`, Taplo linting, independent tester review, and independent architecture review pass.
- The owner physically confirmed all 14 positions and brightness 80. Two interactions with `music` at `4_0` each emitted exactly one pressed/released pair; controlled shutdown removed the runtime socket.
- A deploy-directory run additionally verified owner-only directory/socket modes, matching-instance health readiness, and socket removal after shutdown.
- A controlled reproduction confirmed the screensaver defect: baseline input worked, IPC remained `ready`, two post-screensaver presses neither woke the display nor emitted events, and shutdown cleanup passed.
- `S-01`, `S-02`, `D-01`, and `M-01` are complete.
- The owner selected a Go core, SwiftUI client, and TOML configuration on 2026-08-24.
- `M-01` implements Go runtime/CLI shells, strict bounded health/status IPC, shared v1 fixtures, a SwiftUI `MenuBarExtra`, deterministic process supervision, endpoint security, and live Go/Swift integration.
- `M-01-F01` is complete: every Xcode-built app contains `Contents/MacOS/hidhogg-runtime`, starts it eagerly outside the dedicated hosted-test configuration, and awaits cleanup on normal application termination.
- `M-01-F02` is complete: GUI-launched Xcode discovers Go from standard installation locations without interactive shell initialization, and the Swift build has no unused cleanup-result warnings.
- The normative internal protocol is `api/protocol/v1/README.md`; consequential decisions awaiting owner review are in `docs/m01-decision-review.md`.
- Installed verification toolchains were Go 1.26.4, Swift 6.3.3, and Xcode 26.6. Go 1.27 was unavailable and not run.
- Final verification passed cgo-free Go build/test/race/vet, `git diff --check`, and 15/15 Xcode tests. An independent live probe confirmed a mode-mutated socket is preserved during shutdown.
- The post-milestone bundling correction passes 17/17 Xcode tests. Independent Debug direct-launch probes reached ready and cleaned their exact runtime/socket/generation on quit; the Test configuration created no orphan or generation.

## Residual risks

- `M-01` trusts same-effective-UID processes; pathname replacement between final identity validation and unlink is not atomic and remains accepted.
- Repeated physical reconnect reliability is an owner-accepted implementation assumption supported by only one measured reconnect/session-replacement cycle.
- Swift monitors endpoint identity after readiness, but no dedicated post-ready substitution test exists.
- Packaging, signing, App Sandbox isolation, login items, `launchd`, product behavior, physical HID integration, and a public TOML schema remain deferred.
- Distribution signing/notarization of the embedded Go runtime is unverified; Test-configuration app products intentionally suppress automatic runtime startup.
- The Swift supervisor does not yet pass the now-required `--config-path`; the bundled app is intentionally incompatible until the deferred Swift follow-up.
- Repeated reconnect reliability, configuration watching/last-known-good reload, actions, notifications, and rich assets remain unimplemented.
- Idle/screensaver-duration input reliability is not established; the latest live session stopped receiving events after the firmware screen state appeared.

## Next actions

1. Treat firmware screensaver/input loss and misleading `ready` state as the next functional blocker; diagnose protocol cause and recovery before pending `M-03`.
2. Plan and authorize pending `M-03`, the self-contained runtime-discovery correction.
3. After `M-03`, decide whether the next functional slice restores Swift supervisor compatibility or first adds Go-side actions/notifications.
4. Keep configuration watching/editing and reconnect hardening behind separate explicit milestones.
