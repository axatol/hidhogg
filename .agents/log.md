# Hidhogg decision log

## 2026-08-22 — Planning baseline

- Status: provisional; owner decision pending `D-01`.
- Product: personal-use macOS 26+ HID utility, initially one D200X and one page.
- Runtime preference: cgo-free Go if physical D200X feasibility passes; otherwise native Swift.
- Configuration preference: TOML if required GUI edits are lossless; otherwise JSONC.
- Security boundary: inbound notifications are display-only and cannot supply executable commands. Physical controls may invoke statically configured executable paths with argument arrays.
- Persistence: immediate GUI writes, content-hash conflict refusal, atomic replacement, and last-known-good runtime behavior for invalid external edits.
- Reference policy: `UlanziDeckControl` supplies evidence only, not a product or code foundation.
- Uncertainty: pure-Go macOS HID and lossless TOML editing remain unverified in this repository.

## 2026-08-22 — S-01 automatic evidence and permission blocker

- `go-ctap/hid v0.11.0` builds and tests with cgo disabled.
- One physical D200X exposes both a consumer-control and keyboard top-level collection on interface 0 through this backend. Exact usage filtering is required in addition to VID, PID, and interface number.
- Read-only enumeration selects one `0x000c:0x0001` collection after rejecting `0x0001:0x0006`.
- The first open returned `0xe00002e2`; no physical write occurred. Go architecture selection remains blocked pending an authorized hardware run.
- The required Discord blocker notification failed inside the sandbox because DNS resolution was unavailable. The escalated retry was rejected because the external destination and payload lacked explicit approval. No workaround was attempted.

## 2026-08-22 — S-02 measured result

- Pinned go-toml's exact edit-capable pseudo-version passed 34/34 required cases and 8/8 exact same-line minimal-edit checks.
- HuJSON passed 2 malformed-input cases but failed all 32 mutation preservation comparisons by changing untouched trailing commas.
- TOML is recommended provisionally. The unstable dependency pin and filesystem TOCTOU limitation remain explicit risks; the owner has not declared a stable format.

## 2026-08-23 — S-01 physical evidence and display repair

- An authorized terminal completed 20 open/close iterations and captured the required touch, physical-button, and encoder inputs.
- Brightness changes were visually confirmed on the physical D200X.
- The first diagnostic display attempt failed. The generated manifest omitted each `ViewParam` closing bracket and was invalid JSON; automated tests had only compared it to itself and therefore missed the defect.
- The manifest repair now has independent JSON and coordinate-mapping validation. Plain, race, vet, archive, framing, and independent review checks pass, but physical display behavior remains unverified.
- One reconnect/session-replacement cycle was recorded against the then-current three-cycle gate; the later owner decision below supersedes that threshold.

## 2026-08-23 — S-01 completed under revised reconnect gate

- The repaired archive physically displayed colored numbered tiles. Low number legibility is confined to diagnostic artwork and does not invalidate the protocol result.
- The owner reduced the reconnect feasibility gate from three cycles to one. One disconnect, reconnect, and active-session replacement passed; repeated-cycle reliability remains unmeasured.
- `S-01` is complete. Both feasibility spikes now support owner decision `D-01`; neither the runtime architecture nor configuration format has yet been selected.

## 2026-08-24 — D-01 production direction selected

- The owner selected a Go core with a SwiftUI client and TOML configuration.
- `D-01` is complete. `M-01` is ready for planning, but its production scaffold boundary has not been defined or approved.
- The owner accepts reconnect reliability as an implementation assumption. This is a risk decision, not additional physical evidence: only one reconnect/session-replacement cycle has been measured, and repeated-cycle reliability remains unverified.
- The TOML editing dependency must remain behind a Hidhogg-owned adapter with regression coverage because the tested edit-capable version is an unstable pin.

## 2026-08-24 — M-01 boundary approved for planning

- The owner approved the `M-01` scaffold boundary and a SwiftUI-supervised Go process model.
- `M-01` establishes testable shells and internal contracts only. Product behavior, physical HID integration, public configuration schema, packaging, signing, login items, and `launchd` remain out of scope.
- The Go module uses Go 1.26 as its minimum language baseline and is tested with Go 1.27. Exact installed Xcode and Swift versions must be recorded before implementation.
- The local scaffold protocol is versioned, JSON-encoded, bounded, owner-only, and restricted to health/status. It cannot carry executable commands.
- Implementation remains pending owner approval of the detailed roadmap tasks.

## 2026-08-24 — M-01 authorized and independently revised

- The owner authorized the main agent to complete `M-01`, research consequential decisions, seek architect consensus, and maintain a separate review register while continuing.
- Independent architecture review returned `revise before implementation`; the selected Go/Swift architecture was accepted, while IPC, endpoint, and process-supervision contracts required tightening.
- Architect consensus selected one LF-framed request and response per connection, strict shared v1 JSON fixtures, 16 KiB frames, one-second phase deadlines, eight concurrent connections, unique per-generation endpoints, UUID instance attribution, bounded output, fixed shutdown escalation, and one automatic restart.
- `M-01` was narrowed to exercised runtime and IPC boundaries. Action, notification, D200X, HID, and TOML implementation packages are deferred.
- Installed tools are Go 1.26.4, Swift 6.3.3, and Xcode 26.6. The installed macOS SDK exposes a 104-byte `sun_path` and Swift imports `getpeereid`; Go's `x/sys/unix` exposes `GetsockoptXucred` with `SOL_LOCAL` and `LOCAL_PEERCRED`.
