# Hidhogg roadmap

Status: M-02 config-driven D200X slice complete
Updated: 2026-08-26

Task IDs are immutable.

| ID | Status | Goal | Dependencies |
|---|---|---|---|
| P-01 | Complete | Establish planning baseline and evidence rules | none |
| S-01 | Complete | Determine whether a cgo-free Go runtime can operate the physical D200X reliably | P-01 |
| S-02 | Complete | Determine whether required TOML GUI mutations can be lossless; compare JSONC fallback if not | P-01 |
| D-01 | Complete | Owner selects runtime architecture and configuration format from the spike report | S-01, S-02 |
| M-01 | Complete | Scaffold the selected production architecture | D-01 |
| M-01-F01 | Complete | Embed the required Go runtime in Xcode app products and verify failed-launch cleanup | M-01 |
| M-01-F02 | Complete | Make the runtime build phase independent of interactive shell PATH and clear cleanup warnings | M-01-F01 |
| M-02 | Complete | Drive one physical D200X page and decoded input events from one explicit TOML file | M-01 |
| M-02-P01 | Complete | Freeze the Go-only configuration, device-session, event, and verification contracts | M-02 |
| M-02-C01 | Complete | Implement strict TOML loading, semantic validation, and deterministic JSON Schema generation | M-02-P01 |
| M-02-D01 | Complete | Implement the production D200X protocol, transport, rendering, and decoded input boundary | M-02-P01 |
| M-02-R01 | Complete | Integrate configuration and D200X operation into the Go runtime | M-02-C01, M-02-D01 |
| M-02-V01 | Complete | Independently verify automatic gates and the owner-run physical procedure | M-02-R01 |
| M-03 | Pending | Make direct-Go runtime discovery self-contained and preflight IPC before physical device mutation | M-02 |

## P-01 — Planning baseline

- Goal: record product intent, provisional boundaries, stable tasks, and session state.
- Acceptance: required documentation exists, contains only verified facts or explicit hypotheses, and does not claim an architecture decision.
- Verification: documentation review and clean repository inventory.

## S-01 — Cgo-free Go D200X spike

- Goal: evaluate `go-ctap/hid` on macOS 26 with `CGO_ENABLED=0`.
- Scope: deterministic interface-0 enumeration, open/close, input, brightness, diagnostic display, and disconnect/reconnect.
- Constraints: do not log device serials; do not access unrelated HID devices; do not inherit production code from `UlanziDeckControl`.
- Automatic gate: cgo-free build, unit tests for framing/selection, and testable transport lifecycle.
- Physical gate: 20 open/close iterations, representative input matrix, visible brightness/display confirmation, and one unplug/replug cycle without keyboard seizure, duplicate sessions, truncated reports, or dead reads. The owner reduced the reconnect threshold from three cycles on 2026-08-23; this establishes feasibility, not repeated-cycle reliability.
- Acceptance: report every criterion as pass, fail, or not run. Recommend Go only if every required physical criterion passes.
- Current evidence: all revised automatic and physical gates pass. The repaired diagnostic archive displays colored numbered tiles, although the numbers are not highly legible. One reconnect/session-replacement cycle passes; repeated-cycle reliability remains unmeasured. See [research.md](research.md).

## S-02 — Configuration editing spike

- Goal: evaluate VS Code-style minimal source edits for TOML.
- Scope: representative root/device fixtures; scalar, insertion, deletion, reorder, table, array-of-table, comment, unknown-field, malformed-input, atomic-write, and content-hash conflict cases.
- TOML acceptance: all required edits preserve untouched byte ranges, comments, whitespace, ordering, and unknown fields while producing a semantically valid document.
- Fallback: if any TOML criterion fails, run the same behavioral cases using HuJSON/JSONC and report the comparison.
- Constraint: no configuration format becomes a public compatibility contract during the spike.
- Current evidence: 34/34 required TOML cases and 8/8 exact minimal same-line checks pass. HuJSON passes malformed-input rejection but fails 32/32 mutation-preservation comparisons because untouched trailing commas change. TOML is recommended provisionally; see [research.md](research.md).

## D-01 — Owner decision

- Goal: select Go core plus SwiftUI or native Swift, and TOML or JSONC.
- Required evidence: exact dependency versions, licenses, commands, automated results, physical observations, failures, and uncertainties.
- Decision (2026-08-24): Go core with a SwiftUI client and TOML configuration.
- Reliability posture: the owner accepts reconnect reliability as an implementation assumption. Only one reconnect/session-replacement cycle has been measured; repeated-cycle reliability remains unverified and must not be represented as established evidence.

## M-01 — Production scaffold

- Status: complete on 2026-08-24 after independent verification.
- Goal: establish independently testable Go runtime, CLI, IPC, and SwiftUI client boundaries without implementing product behavior.
- Scope: root Go module, runtime and CLI shells, minimal exercised internal boundaries, versioned local health/status IPC, shared fixtures, SwiftUI `MenuBarExtra` shell, and build/test commands.
- Constraints: Go 1.26 minimum language baseline; SwiftUI launches and supervises the Go runtime; socket access is local and owner-only; use unique per-generation endpoints and never blindly unlink an existing entry; retain reconnect/session-replacement resilience as an explicit future verification concern.
- Excludes: public TOML schema, real configuration mutation, physical HID access, action execution, notification behavior, signing, packaging, login items, and `launchd` installation.
- Completion gate: Go build, unit tests, race tests, and vet pass; Swift build and unit tests pass; the Swift client completes a health/status exchange with the supervised Go process over a Unix socket; no test accesses physical HID hardware.

### M-01-P01 — Freeze scaffold contracts

- Status: complete on 2026-08-24 after independent architect review.
- Goal: define the internal dependency direction and the bounded health/status IPC contract used by the scaffold.
- Scope: one-request-per-connection LF framing; strict JSON envelopes and shared fixtures; 16 KiB bounds; deadlines and concurrency; endpoint lifecycle and peer identity; per-generation attribution and readiness; deterministic process supervision; minimal dependency direction; black-box cases.
- Constraints: the IPC contract is internal and does not establish a public compatibility promise; messages cannot carry executable commands.
- Acceptance criteria: a normative v1 specification and shared valid/invalid fixture manifest remove Go/Swift semantic choices; cleanup refuses every substitution observable before unlink while documenting the accepted same-UID check/unlink race; a health response is attributable to the process launched by the app; dependency direction has no cycle.
- Role: main agent for decisions and documentation.
- Dependencies: `D-01`.
- Verification gate: architect consensus and documentation consistency review before implementation begins.
- Blockers: confirm Darwin peer credentials, Unix-socket path capacity, and Swift process/pipe behavior against primary sources and the installed toolchain.
- Parallel boundary: blocks `M-01-G01`, `M-01-I01`, and `M-01-S01`.

### M-01-G01 — Scaffold Go module and boundaries

- Status: complete on 2026-08-24.
- Goal: create compilable Go runtime and CLI shells with replaceable internal boundaries.
- Scope: root module; `cmd/hidhogg`; `cmd/hidhoggctl`; `internal/runtime`; `internal/ipc`; only exercised consumer-owned config/device ports and test fakes.
- Constraints: do not create speculative action, notification, D200X, or TOML implementation packages; do not move spike code wholesale; no production import may reference a spike, HID dependency, or unstable TOML editor.
- Acceptance criteria: both commands compile; package responsibilities are represented by narrow interfaces; fake implementations support deterministic unit tests.
- Role: `executor_light`.
- Dependencies: `M-01-P01`.
- Verification gate: `go build`, `go test`, `go test -race`, and `go vet` across the root module with cgo disabled where applicable.
- Blockers: installed Go toolchain must support the selected test matrix.
- Parallel boundary: may proceed in parallel with `M-01-S01` after `M-01-P01`; coordinates shared IPC types with `M-01-I01`.

### M-01-I01 — Implement local scaffold IPC

- Status: complete on 2026-08-24.
- Goal: prove bounded communication between the runtime, CLI, and SwiftUI client.
- Scope: owner-only Unix socket; single LF-framed strict JSON health/status exchange; request correlation; one-second phase deadlines; eight-connection limit; unique endpoint ownership; graceful shutdown.
- Constraints: no configuration writes, notification submission, action commands, discovery, or remote transport; each frame is at most 16,384 bytes including LF; malformed input must not terminate the runtime.
- Acceptance criteria: Go server and client consume shared fixtures; invalid, partial, slow, concurrent, foreign, or oversized input receives the specified bounded behavior; modes, peer identity, non-socket/symlink refusal, inode-safe cleanup, and two-instance coexistence are tested.
- Role: `executor_light`.
- Dependencies: `M-01-P01`, `M-01-G01`.
- Verification gate: unit and integration tests using temporary sockets; race detector passes.
- Blockers: none known.
- Parallel boundary: server work may proceed alongside the Swift client after the contract fixtures are frozen.

### M-01-S01 — Scaffold SwiftUI client and supervision

- Status: complete on 2026-08-24.
- Goal: create a native menu-bar shell that owns the scaffold Go process lifecycle and displays its health state.
- Scope: Xcode project; SwiftUI `MenuBarExtra`; injected executable/socket paths; UUID instance attribution; validated readiness; concurrent bounded output drains; deterministic termination escalation; one bounded restart; Unix-socket health client; test doubles.
- Constraints: no `launchd`, login item, signing, settings editor, or direct HID ownership; do not expose unbounded process output in the UI.
- Acceptance criteria: the app builds; the shared fixture corpus passes; readiness proves the launched instance; output cannot block the child and is retained only as bounded tails; quitting terminates the child with fixed escalation; exactly one delayed restart is permitted and a second failure becomes terminal.
- Role: `executor_light`.
- Dependencies: `M-01-P01`; integration depends on `M-01-I01`.
- Verification gate: Xcode build and unit tests on the installed supported toolchain.
- Blockers: none; Xcode 26.6 and Swift 6.3.3 were recorded on 2026-08-24.
- Parallel boundary: project shell and lifecycle tests may proceed alongside `M-01-G01`; live IPC integration waits for `M-01-I01`.

### M-01-V01 — Independent scaffold verification

- Status: complete on 2026-08-24 after remediation and recheck.
- Goal: verify the scaffold satisfies its boundary without silently implementing excluded behavior.
- Scope: early black-box case design followed by build/test execution, dependency-boundary audit, process cleanup, socket security, failure paths, and physical-HID exclusion.
- Constraints: verification must use fakes and temporary sockets; do not access a physical device.
- Acceptance criteria: every `M-01` completion gate is reported pass or fail with exact commands and toolchain versions; root dependencies contain no spike module, HID, or unstable TOML editor; exclusions and residual risks are audited.
- Role: `tester`.
- Dependencies: `M-01-G01`, `M-01-I01`, `M-01-S01`.
- Verification gate: independent report accepted by the main agent; failures return to the owning implementation task.
- Blockers: none.
- Parallel boundary: black-box cases are designed after `M-01-P01`; independent execution begins after implementation tasks declare their local gates complete.

## Parallel boundaries

`S-01` and `S-02` proceeded independently and are complete. Within `M-01`, `M-01-P01` freezes shared contracts; Go and Swift shells may then proceed in parallel, IPC integration follows the shared contract, and independent verification follows all implementation tasks.

## M-01-F01 — Bundle-required runtime correction

- Status: complete on 2026-08-24 after independent direct-launch and test-host verification.
- Goal: make every Xcode-built Hidhogg app contain the required `hidhogg` Go runtime and ensure failed launch generations clean up or report why they could not.
- Scope: Xcode build/copy integration, deterministic bundle lookup, launch-failure cleanup regression coverage, and direct bundle verification.
- Constraints: do not search shell `PATH`; do not depend on `/usr/local/bin`; preserve endpoint mismatch safeguards and user-owned Xcode workspace metadata.
- Acceptance criteria: the built app contains an executable `Contents/MacOS/hidhogg-runtime`, distinct from the case-insensitively colliding Swift executable `Contents/MacOS/Hidhogg`; the app resolves that bundled path; a normal Xcode-built launch reaches ready; two failed launch attempts leave no matching empty generation directories; cleanup failure is observable rather than silently discarded.
- Role: `executor_light`, followed by `tester`.
- Verification gate: Go gates, full Xcode tests, bundle inspection, and an independent direct-launch/cleanup probe.

## M-01-F02 — Xcode GUI build-environment correction

- Status: complete on 2026-08-24 after independent restricted-`PATH` verification.
- Goal: make Xcode GUI builds find the installed Go toolchain without inheriting an interactive shell and keep the Swift build warning-free.
- Scope: deterministic build-phase executable discovery, actionable missing-tool failure, and explicit discard of best-effort cleanup results.
- Constraints: do not hard-code a single developer-specific path; preserve bundle output, cleanup behavior, and user-owned Xcode workspace metadata.
- Acceptance criteria: a restricted GUI-like `PATH` build finds a supported Go installation or reports actionable remediation; full tests pass; the two unused `try?` warnings are absent.
- Role: `executor_light`, followed by `tester`.
- Verification gate: fresh restricted-`PATH` build, full Test-configuration XCTest, issue-log audit, and staged diff check.

## M-02 — Config-driven D200X vertical slice

- Status: complete on 2026-08-26 after automatic, Taplo, independent, and physical verification.
- Goal: prove that one explicit, versioned TOML file can drive one complete physical D200X page and expose decoded input events through the production Go runtime.
- Scope: strict configuration loading; semantic validation; deterministic checked-in JSON Schema; exact D200X selection; one complete configured page; brightness, upload, unlock, and input enable; bounded decoded event output; opt-in verbose outbound-packet and input-event logging.
- Constraints: configuration must validate before HID enumeration or writes; raw HID paths, serials, and unrelated device identities must never be logged; writes are serialized and never automatically retried after an uncertain failure; existing health IPC remains operational.
- Excludes: all Swift and SwiftUI changes, default config discovery, root/device composition, configuration watching or mutation, last-known-good reload, actions, notifications, new IPC methods, rich assets, multi-device abstractions, packaging, and reconnect hardening.
- Completion gate: all automatic gates pass and the owner records the physical procedure pass, fail, or not run.

### M-02-P01 — Freeze Go-only slice contracts

- Status: complete on 2026-08-26 after owner confirmation and independent architect review.
- Contract: `--config-path` names one absolute TOML file with `schema_version = 1`, adapter `ulanzi.d200x`, brightness `0..100`, exactly one page, and all 14 display positions explicitly configured with stable ID, position, label, and background colour.
- Compatibility posture: the schema is milestone-private; unknown fields are rejected; future root/device composition requires an explicit migration rather than silent reinterpretation.
- Observability: decoded press/release events go to a bounded diagnostic sink. Verbose mode additionally logs input events and outbound packets without raw device identifiers or serials.
- Failure policy: invalid configuration performs no HID activity; disconnect or an uncertain write ends the device session without retry.

### M-02-C01 — Configuration and schema

- Status: complete on 2026-08-26 after independent package test, race, vet, regeneration, and diff checks.
- Scope: stable TOML decoder; schema reflector; semantic validation; valid and invalid fixtures; deterministic schema artifact and stale-generation test.
- Acceptance: malformed, duplicate, unknown, unsupported-version/adapter, page-count, duplicate-ID/position, position-range, colour, and brightness cases are deterministic; valid fixtures agree across TOML decoding, JSON projection, and schema validation; Taplo consumes the checked-in schema.
- Parallel boundary: may proceed alongside `M-02-D01`; owns configuration packages and schema artifacts.

### M-02-D01 — Production D200X adapter

- Status: complete on 2026-08-26 after durable framing, selection, rendering, lifecycle, input, and diagnostic regression tests passed independently with cgo disabled and under the race detector.
- Scope: exact collection selection, framing, serialized writes, deterministic label/colour page archive, brightness, upload, unlock, input enable, input decoding, cancellation, and bounded verbose diagnostics.
- Acceptance: zero or ambiguous eligible collections refuse open; fake transport proves exact packet ordering and complete archive semantics; short/failed writes invalidate the session; malformed or unknown input cannot terminate the runtime; tests never access physical HID hardware.
- Parallel boundary: may proceed alongside `M-02-C01`; owns D200X packages and must not import the spike module.

### M-02-R01 — Go runtime integration

- Status: complete on 2026-08-26 after independent architecture corrections and cgo-free test, race, vet, build, and module-integrity gates.
- Goal: load and validate before opening one D200X, operate the configured session concurrently with existing health IPC, and shut down deterministically.
- Acceptance: invalid config causes zero enumerate/open/write calls; startup order is load, validate, select, open, page upload, brightness, unlock, input enable, and event read; cancellation closes the session; verbose mode is opt-in and bounded.

### M-02-V01 — Independent verification

- Status: complete on 2026-08-26. Full cgo-free build/test/race/vet, schema regeneration, module integrity, diff checks, direct Taplo linting, independent review, and the physical gate pass.
- Automatic gates: `CGO_ENABLED=0 go build ./...`, `go test ./...`, `go test -race ./...`, `go vet ./...`, schema regeneration, `git diff --check`, existing Xcode tests, dependency/provenance audit, and confirmation that tests do not access physical HID hardware.
- Physical gate: with one D200X attached and Ulanzi Studio quit, launch the Go runtime with an explicit config; confirm all 14 configured positions and brightness; press and release one named square tile and observe exactly one ordered pair; quit and confirm the device closes.
- Evidence rule: record each physical item as pass, fail, or not run. Do not infer repeated reconnect reliability.
- Physical result: pass. One connected D200X accepted the configured 14-position page and brightness 80; the owner confirmed both visible results. Two intentional interactions with configured tile `music` at `4_0` each produced exactly one ordered pressed/released pair. Controlled shutdown removed the runtime socket.

## M-03 — Self-contained runtime discovery

- Status: pending; recorded as the immediate next improvement on 2026-08-27.
- Goal: replace user-supplied socket and instance plumbing with one secure runtime directory while retaining generation attribution.
- Scope: `--runtime-dir`; internally generated lowercase canonical instance ID; atomically published owner-only runtime metadata; `hidhoggctl --runtime-dir` discovery; case-insensitive UUID normalization for explicit overrides; IPC directory and endpoint preflight before any HID open or write.
- Constraints: retain owner-only directory/socket modes, peer-UID verification, generation identity checks, guarded cleanup, multi-instance safety, and explicit supervisor/testing overrides.
- Acceptance: a normal direct-Go launch requires only runtime directory and configuration path; uppercase and lowercase UUID overrides normalize to the same canonical representation; invalid runtime-directory state fails before physical device mutation; metadata and socket are removed only when their recorded identities still match.
- Excludes: configuration watching/editing, SwiftUI settings, actions, notifications, reconnect hardening, signing, and packaging.
