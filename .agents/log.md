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
- The Go module uses Go 1.26 as its minimum language baseline. Go 1.27 was not installed or tested during `M-01`.
- The local scaffold protocol is versioned, JSON-encoded, bounded, owner-only, and restricted to health/status. It cannot carry executable commands.
- Implementation remains pending owner approval of the detailed roadmap tasks.

## 2026-08-24 — M-01 authorized and independently revised

- The owner authorized the main agent to complete `M-01`, research consequential decisions, seek architect consensus, and maintain a separate review register while continuing.
- Independent architecture review returned `revise before implementation`; the selected Go/Swift architecture was accepted, while IPC, endpoint, and process-supervision contracts required tightening.
- Architect consensus selected one LF-framed request and response per connection, strict shared v1 JSON fixtures, 16 KiB frames, one-second phase deadlines, eight concurrent connections, unique per-generation endpoints, UUID instance attribution, bounded output, fixed shutdown escalation, and one automatic restart.
- `M-01` was narrowed to exercised runtime and IPC boundaries. Action, notification, D200X, HID, and TOML implementation packages are deferred.
- Installed tools are Go 1.26.4, Swift 6.3.3, and Xcode 26.6. The installed macOS SDK exposes a 104-byte `sun_path` and Swift imports `getpeereid`; Go's `x/sys/unix` exposes `GetsockoptXucred` with `SOL_LOCAL` and `LOCAL_PEERCRED`.

## 2026-08-24 — M-01-P01 contract frozen

- `api/protocol/v1` is the normative internal scaffold contract and shared Go/Swift fixture corpus.
- Independent architect review required two correction rounds covering deterministic post-LF behavior, crash cleanup, generated-case oracles, validation precedence, missing-LF timeout behavior, and field/type error precedence.
- The architect approved the corrected contract with no remaining implementation-blocking semantic ambiguity.
- `M-01-P01` is complete. `M-01-G01`, `M-01-I01`, and `M-01-S01` may proceed within the frozen contract.

## 2026-08-24 — M-01 endpoint root revised after execution evidence

- Escalated XCTest execution showed that Foundation's per-user temporary-directory path exceeded Darwin's 104-byte Unix-socket path field, so the production Swift supervisor could not launch.
- Architect consensus replaced the environment-derived root with literal `/private/tmp`, verified at startup as a real UID-0-owned `01777` directory. Each generation is an atomic effective-UID-owned `0700` child named `hidhogg-<euid>-<UUID>`.
- The target host read-only check reported `/private/tmp` as UID 0, mode `041777`, directory. Future sandboxed packaging must revisit the location.

## 2026-08-24 — M-01 cleanup threat boundary corrected

- Independent verification found that Swift overwrote the first recorded socket identity and that both languages ultimately rely on a pathname identity check followed by unlink.
- Architect consensus found no macOS compare-and-unlink primitive available to the cgo-free Go and Swift scaffold. `M-01` therefore trusts same-effective-UID processes and records the final check/unlink race instead of claiming atomic conditional cleanup.
- Observable identity, type, owner, or mode mismatches must remain untouched. Swift must retain the first identity and treat drift as a security failure.
- Generated manifest families are milestone-blocking test requirements; exhaustive fuzzing, sustained load, adversarial same-UID stress, packaging isolation, and repeated physical reconnects remain future work.

## 2026-08-24 — M-01 production scaffold completed

- The Go runtime and CLI, strict bounded Unix-socket health/status IPC, SwiftUI menu-bar shell, process supervisor, shared fixtures, and live Go/Swift integration are implemented.
- Architect consensus added pre-health, post-health, and ready-state endpoint identity checks. The first socket identity is retained; observable drift is terminal and guarded cleanup preserves replacements.
- Independent verification found and reproduced one Go cleanup defect: mode-mutated sockets were identity-checked but not required to remain `0600`. Both unlink guards now enforce type, owner, mode, and identity; the regression test and a fresh live `0644` mutation probe pass.
- Final gates pass: cgo-free Go build, unit tests, race tests, vet, `git diff --check`, and 15/15 Xcode tests including live runtime integration.
- `M-01` is complete. Residual risks are the accepted same-effective-UID pathname race, untested Go 1.27, no dedicated Swift post-ready substitution test, deferred packaging isolation, and unmeasured repeated reconnect reliability.

## 2026-08-24 — M-01-F01 bundled-runtime correction completed

- Xcode launches initially failed because the app bundle contained no Go runtime and the app fell back to absent `/usr/local/bin/hidhogg`. Two empty generation directories confirmed cleanup failures were being discarded.
- The Go runtime is now an always-run, cache-backed Xcode build output atomically installed as `Contents/MacOS/hidhogg-runtime`. The initial case-only `hidhogg` name was rejected after it overwrote the Swift `Hidhogg` executable on case-insensitive APFS.
- `NSApplicationDelegateAdaptor` now starts the shared model eagerly and uses an AppKit terminate-later handshake so normal application termination awaits supervisor cleanup. Launch failure cleanup is observable, and two failed attempts leave no generation directories.
- Hosted XCTest originally orphaned the eagerly started runtime because test-host teardown bypasses normal termination. A dedicated `Test` configuration defines `HIDHOGG_TEST_HOST` only for the app target and compiles out only automatic app-owned startup; explicit live integration remains enabled.
- Final independent verification passes 17/17 tests with identical pre/post process and generation inventories. Two Debug direct-launch probes reached matching health/status readiness and normal quit removed each child, socket, and generation.
- Signing and notarization of the nested runtime remain deferred and unverified.

## 2026-08-24 — M-01-F02 Xcode GUI build correction completed

- GUI-launched Xcode could not resolve Go because the installed executable is under Apple Silicon Homebrew and the build phase inherited no interactive shell path.
- The runtime phase now checks standard Apple Silicon Homebrew, official Go installer, and Intel Homebrew locations before its supplied `PATH`, and emits actionable remediation if none contains Go.
- All best-effort cleanup calls explicitly discard their returned result, removing the unused-result Swift diagnostics without changing cleanup semantics.
- Independent verification passed a fresh restricted-`PATH` universal build, warning audit, bundle inspection, direct bundled-runtime health/cleanup probe, and the existing 17/17 Test-configuration suite.

## 2026-08-26 — M-02 Go-only vertical slice authorized

- The owner authorized the next milestone as a thin functional slice in which one explicit TOML file drives one complete D200X page and decoded physical input through the production Go runtime.
- Independent architect review recommended strict validation before HID activity, all 14 display positions, deterministic label/colour rendering, an injected diagnostic event sink, and no actions, notifications, reload, rich assets, new IPC, or general device registry.
- The owner deferred all Swift-related work until the Go application is fully functional.
- Opt-in verbose diagnostics must log decoded input events and outbound packets. Raw HID paths, serials, and unrelated device identities remain prohibited from logs.
- The milestone-private schema uses `schema_version = 1`, rejects unknown fields, and will be generated deterministically from the same canonical Go model used for TOML decoding. Future root/device composition remains a deliberate migration.

## 2026-08-26 — M-02 automatic implementation verified

- Strict configuration, deterministic Draft-4 JSON Schema generation, the production D200X adapter, and direct Go runtime integration are implemented.
- Stable production dependencies are `go-toml/v2 v2.4.3` and `google/jsonschema-go v0.4.3`, both MIT licensed. The D200X adapter pins pre-v1 `go-ctap/hid v0.11.0`, Apache-2.0, as established by the feasibility spike.
- Two malformed transitive checksums introduced during parallel dependency integration were corrected by comparison with the retained spike and Go's authenticated module download; `go mod verify` now passes.
- Independent architecture review required exact integrated startup-order coverage, config/adapter position-map parity, and an explicit stdout-failure shutdown test. All corrections pass.
- Full cgo-free Go tests and race tests pass outside the socket-restricted sandbox; build, vet, schema regeneration, module tidy diff, module verification, and diff checks pass. Automated tests use fake transports and do not access HID hardware.
- Taplo is not installed, so direct Taplo consumption remains not run. The physical D200X gate remains not run.
- Deferring Swift creates an intentional temporary incompatibility: the current supervisor omits the newly required `--config-path`, so the bundled Swift application cannot launch the M-02 runtime until the later Swift milestone.

## 2026-08-26 — M-02 physical slice completed

- The official Taplo CLI linted `examples/d200x.toml` against the generated local Draft-4 schema without diagnostics.
- The direct Go runtime opened one owner-confirmed D200X and sent eight complete-display-upload reports followed by brightness `80`, unlock, and input-enable reports.
- The owner confirmed all 14 configured positions were visible and brightness 80 was applied.
- Two intentional interactions with configured tile `music` at position `4_0` each emitted exactly one ordered `pressed` then `released` event pair with no raw device identity.
- Controlled interruption closed the runtime and removed its Unix socket.
- `M-02` is complete. This evidence does not establish repeated reconnect reliability or Swift application compatibility.

## 2026-08-27 — Deploy-directory verification and immediate follow-up

- The owner verified a direct launch using `deploy/hidhogg.toml` and `deploy/runtime.sock` after setting `deploy` to owner-only mode `0700`.
- The live runtime repeated the expected upload, brightness, unlock, and input-enable sequence. `hidhoggctl health` returned protocol version 1, `ready`, and the exact launched instance ID.
- While running, the socket was an owner-owned Unix socket with mode `0600`; after controlled shutdown, `runtime.sock` was absent while the configuration remained.
- A deploy-path negative run using the checked-in unknown-field fixture exited with configuration failure, emitted no outbound packet diagnostic, and created no socket, confirming rejection before HID and IPC activity.
- macOS `uuidgen` emits uppercase hexadecimal, which the current canonical-lowercase parser rejects. Manual lowercasing works, but this is an avoidable CLI defect rather than a security requirement.
- `M-03` is the immediate next improvement: accept one runtime directory, generate and atomically publish the instance ID internally, normalize explicit UUID overrides case-insensitively, let the CLI discover runtime metadata, and validate IPC state before changing the physical device.
