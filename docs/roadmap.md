# Hidhogg roadmap

Status: production scaffold complete
Updated: 2026-08-24

Task IDs are immutable.

| ID | Status | Goal | Dependencies |
|---|---|---|---|
| P-01 | Complete | Establish planning baseline and evidence rules | none |
| S-01 | Complete | Determine whether a cgo-free Go runtime can operate the physical D200X reliably | P-01 |
| S-02 | Complete | Determine whether required TOML GUI mutations can be lossless; compare JSONC fallback if not | P-01 |
| D-01 | Complete | Owner selects runtime architecture and configuration format from the spike report | S-01, S-02 |
| M-01 | Complete | Scaffold the selected production architecture | D-01 |
| M-01-F01 | Complete | Embed the required Go runtime in Xcode app products and verify failed-launch cleanup | M-01 |

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
