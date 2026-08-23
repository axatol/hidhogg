# Hidhogg handoff

Updated: 2026-08-24

## Current objective

Select and plan the milestone after the completed `M-01` production scaffold.

## Completed state

- `S-01`, `S-02`, `D-01`, and `M-01` are complete.
- The owner selected a Go core, SwiftUI client, and TOML configuration on 2026-08-24.
- `M-01` implements Go runtime/CLI shells, strict bounded health/status IPC, shared v1 fixtures, a SwiftUI `MenuBarExtra`, deterministic process supervision, endpoint security, and live Go/Swift integration.
- The normative internal protocol is `api/protocol/v1/README.md`; consequential decisions awaiting owner review are in `docs/m01-decision-review.md`.
- Installed verification toolchains were Go 1.26.4, Swift 6.3.3, and Xcode 26.6. Go 1.27 was unavailable and not run.
- Final verification passed cgo-free Go build/test/race/vet, `git diff --check`, and 15/15 Xcode tests. An independent live probe confirmed a mode-mutated socket is preserved during shutdown.

## Residual risks

- `M-01` trusts same-effective-UID processes; pathname replacement between final identity validation and unlink is not atomic and remains accepted.
- Repeated physical reconnect reliability is an owner-accepted implementation assumption supported by only one measured reconnect/session-replacement cycle.
- Swift monitors endpoint identity after readiness, but no dedicated post-ready substitution test exists.
- Packaging, signing, App Sandbox isolation, login items, `launchd`, product behavior, physical HID integration, and a public TOML schema remain deferred.

## Next actions

1. Review `docs/m01-decision-review.md`; record any owner-requested revisions as new roadmap work rather than rewriting completed evidence.
2. Define the next milestone and its stable task IDs before implementation.
3. Keep HID, TOML editing, notification, and action behavior behind explicit exercised boundaries as they enter production scope.
