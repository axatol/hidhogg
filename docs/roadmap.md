# Hidhogg roadmap

Status: M-04 Go-owned profiles complete
Updated: 2026-09-08

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
| M-02-F01 | Complete | Diagnose firmware screensaver wake behavior and prove a wakeable application-owned idle strategy | M-02 |
| M-02-F01-K01 | Complete | Implement a bounded diagnostic-only periodic input-enable experiment | M-02-F01 |
| M-02-F01-K02 | Complete by retrospective waiver | Measure one no-write idle onset and run one paired keepalive-prevention trial | M-02-F01-K01 |
| M-02-F01-K02-R01 | Complete | Couple the K1 endpoint cue and capture window to the diagnostic scheduler | M-02-F01-K02 |
| M-02-F01-K03 | Complete; owner-run composite pass accepted as authoritative | Prospectively test a 50-second cadence with serialized boundary timing | M-02-F01-K02 |
| M-02-F01-B01 | Complete by explicit retrospective owner acceptance | Produce one trusted archived brightness-zero input matrix | M-02-F01-K01 |
| M-02-F01-P01 | Complete | Select and verify the production idle policy from reviewed physical evidence | M-02-F01-K02, M-02-F01-B01 |
| M-02-F02 | Complete | Derive bounded D200X interoperability evidence from static analysis of Ulanzi Studio | M-02-F01 |
| M-02-F03 | Controlled dynamic research complete with qualified T13 evidence | Capture bounded Ulanzi Studio HID-boundary evidence with ordinary LLDB | M-02-F02 |
| M-02-F03-T13 | Partial dynamic evidence complete; restoration repeat waived | Capture Studio screensaver-artwork upload with synthetic A/B images | M-02-F03 |
| M-02-F03-T14 | Complete as qualified research | Derive the independent `0x0009` payload contract from controlled A/B captures | M-02-F03-T13 |
| M-03 | Complete | Make direct-Go runtime discovery self-contained and preflight IPC before physical device mutation | M-02 |
| M-03-P01 | Complete | Freeze locked runtime-directory discovery and compatibility contracts | M-03 |
| M-03-D01 | Complete | Implement secure lock, metadata, discovery, and stale-recovery lifecycle | M-03-P01 |
| M-03-R01 | Complete | Integrate discovery and legacy modes into runtime and CLI startup | M-03-D01 |
| M-03-V01 | Complete | Independently verify automatic and direct-Go functional gates | M-03-R01 |
| M-04 | Complete | Add Go-owned profiles, transactional activation, discovery IPC, and built-in profile switching | M-03 |
| M-04-P01 | Complete | Freeze profile, activation, and IPC contracts | M-04 |
| M-04-C01 | Complete | Replace milestone-private pages with strict profile configuration | M-04-P01 |
| M-04-R01 | Complete | Implement transactional runtime profile activation | M-04-C01 |
| M-04-I01 | Complete | Expose bounded profile list and activation IPC | M-04-R01 |
| M-04-A01 | Complete | Add built-in activate-profile press action | M-04-R01 |
| M-04-V01 | Complete | Independently verify automatic and physical profile switching | M-04-I01, M-04-A01 |
| M-04-D02 | Complete | Add typed content-addressed targeted live-display updates | M-04-V01 |
| M-04-R02 | Complete | Replace live full-page activation with a serialized targeted-update batch | M-04-D02 |
| M-04-V02 | Complete | Reverify automatic and physical profile switching after redraw correction | M-04-R02 |
| M-04-P02 | Complete | Resolve content-addressed full-page live redraw behavior | M-04-V02 |
| M-04-R03 | Complete | Replace sequential live updates with one typed content-addressed full-page upload | M-04-P02 |
| M-04-V03 | Complete | Verify final bulk profile switching automatically and on the owned D200X | M-04-R03 |
| M-05 | Complete | Execute one bounded synchronous button action and expose generation-local history | M-04 |
| M-05-P01 | Complete | Freeze executable-action, worker, lifecycle, history, IPC, and CLI contracts | M-05 |
| M-05-C01 | Complete | Add the strict executable-action configuration and catalog variant | M-05-P01 |
| M-05-E01 | Complete | Implement the isolated one-slot execution worker and bounded history | M-05-C01 |
| M-05-R01 | Complete | Integrate completed presses, runtime lifecycle, and execution IPC/CLI | M-05-E01 |
| M-05-V01 | Complete | Independently verify schema, execution, concurrency, lifecycle, IPC, and CLI gates | M-05-R01 |

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

- Status: complete on 2026-09-04 after automatic, architecture, and owner-visible direct functional gates passed.
- Goal: replace user-supplied socket and instance plumbing with one secure runtime directory while retaining generation attribution.
- Scope: `--runtime-dir`; internally generated lowercase canonical instance ID; atomically published owner-only runtime metadata; `hidhoggctl --runtime-dir` discovery; case-insensitive UUID normalization for explicit overrides; IPC directory and endpoint preflight before any HID open or write.
- Constraints: retain owner-only directory/socket modes, peer-UID verification, generation identity checks, guarded cleanup, multi-instance safety, and explicit supervisor/testing overrides.
- Acceptance: a normal direct-Go launch requires only runtime directory and configuration path; uppercase and lowercase UUID overrides normalize to the same canonical representation; invalid runtime-directory state fails before physical device mutation; metadata and socket are removed only when their recorded identities still match.
- Excludes: configuration watching/editing, SwiftUI settings, actions, notifications, reconnect hardening, signing, and packaging.

### M-03-P01 — Locked discovery contract

- Status: complete on 2026-09-03 after owner confirmation and architect reviews A01/A02.
- Goal: freeze one secure, recoverable runtime-directory protocol before implementation.
- Contract: discovery mode uses one absolute, pre-existing, non-symlink, effective-UID-owned `0700` directory containing persistent `runtime.lock`, generation-scoped `runtime.sock`, and readiness metadata `runtime.json`, each owner-owned with mode `0600`. One cooperating runtime owns one directory.
- Locking: securely open or create `runtime.lock`, validate descriptor/path identity, acquire non-blocking exclusive advisory locking, and retain the descriptor until generation cleanup finishes. Never unlink the lock. No PID is authority.
- Recovery: while exclusively locked and before HID access, remove only strictly valid, identity-stable stale metadata/socket entries. Preserve and reject malformed, substituted, wrongly owned, or wrongly typed entries.
- Publication: bind the socket before HID mutation, initialize the device, begin IPC serving, then atomically publish strict bounded metadata without replacement. Metadata is the readiness marker.
- Compatibility: retain mutually exclusive legacy `--socket-path` plus `--instance-id` mode for Swift/tests. Discovery mode uses `--runtime-dir` and generates a lowercase UUIDv4 unless a case-insensitive canonical override is supplied. `hidhoggctl` supports the same mutually exclusive modes.
- Residual boundary: advisory locking coordinates compliant processes only; same-UID non-cooperating mutation and the existing guarded check/unlink race remain outside the guarantee.

### M-03-D01 — Discovery lifecycle module

- Status: complete on 2026-09-03 after main review, corrections R01/R02, and independent verifier V01 passed.
- Goal: implement a reusable filesystem and generation lifecycle independent of command packages, runtime orchestration, HID, and configuration.
- Scope: secure directory/lock handling; injected UUID generation and normalization; strict bounded metadata encoding/decoding; atomic no-replace publication; guarded stale recovery and cleanup; client-side resolution with post-call identity revalidation support.
- Acceptance: contention, process-exit release, persistent lock reuse, valid crash-state recovery, malformed-state refusal, substitution preservation, UUID normalization/generation, metadata strictness, and two-directory coexistence pass without HID.
- Role: `executor_light`.
- Dependencies: M-03-P01.
- Parallel boundary: owns new discovery module and its tests; must not refactor runtime or command entry points until its interface is reviewed.

### M-03-R01 — Runtime and CLI integration

- Status: complete on 2026-09-03 after corrections R01/R02 and independent verifier V02 passed.
- Goal: integrate discovery lifecycle so all discoverable-mode filesystem and bind failures occur before HID enumeration/open/write, while metadata appears only after device and IPC readiness.
- Scope: mutually exclusive CLI parsing; runtime bind-before-HID lifecycle; post-readiness metadata publication; guarded unwind/shutdown; `hidhoggctl` discovery; retained legacy mode.
- Acceptance: normal launch needs only runtime directory and config path; controller discovers generation; mixed/incomplete modes fail before mutation; uppercase overrides normalize; failed device initialization publishes no metadata and cleans its socket; controlled shutdown removes matching generation entries but retains the lock.
- Role: `executor_light` after D01 interface review.
- Dependencies: M-03-D01.

### M-03-V01 — Independent verification

- Status: complete on 2026-09-04 after independent automatic verification, final architecture review, and direct owner-visible acceptance passed.
- Goal: independently verify security, lifecycle, compatibility, and the direct-Go vertical slice.
- Scope: full/race/vet/build gates; helper-process lock contention and crash recovery on Darwin/Linux; fake-HID preflight ordering; CLI matrix; schema/format/diff checks; owner-run no-HID direct functional procedure before any optional physical check.
- Role: `tester`.
- Dependencies: M-03-R01.
- Automatic result: independent V02 passed full tests, race, vet, build, formatting, diff checks, repeated runtime/discovery/CLI lifecycle matrices, idle-policy race regressions, and a verbose no-skip suite without HID access. Public `Start` cleanup, Start-to-Run publication, all serving-wait outcomes, post-start terminal branches, metadata withdrawal, socket cleanup, and controller revalidation are covered.
- Residual automatic gaps: serving termination before readiness is integrated only at its fully covered helper boundary; metadata-before-cancellation ordering is directly covered through `Close` rather than a separate integrated probe; start-time cancellation combined with cleanup failure is not an explicit compound case. These are low severity and do not contradict observed behavior.
- Architect correction: A03 found a direct `Generation.Close` deadlock when metadata remained published. R04 changed close to use the internal locked withdrawal path while continuing all cleanup after errors; independent V03 passed repeated, race, full, vet, and build gates, and A04 closed the blocker.
- Direct functional result: a fresh discovery-mode runtime published owner-only `runtime.lock` and `runtime.json` regular files plus an owner-only Unix socket, all mode `0600`. Discovery-mode health and status succeeded without an instance argument; both reported ready and status reported protocol version 1. After the execution host ended the first process without clean shutdown, a second launch using the same directory recovered the valid stale metadata/socket and became healthy. While the owner watched, a same-directory contender failed promptly on the lock, emitted no D200X packets, and left the already-off display unchanged. Clean SIGINT exited zero, removed metadata/socket, and retained the owner-only lock.
- Blockers: none.

## M-04 — Go-owned profiles and activation

- Status: complete on 2026-09-08 after the final content-addressed bulk-redraw implementation passed automatic and owner-visible physical acceptance.
- Goal: let the Go runtime own a validated set of D200X profiles and one active profile, expose bounded profile discovery and activation over local IPC, and allow a configured button to activate another profile.
- Responsibility boundary: Go owns profile definitions, default/current selection, validation, rendering, input bindings, and activation. A later Swift milestone owns foreground bundle-ID observation and bundle-to-profile mapping; Go receives only a requested profile ID and contains no macOS application identifiers.
- Initial activation sources: local IPC and built-in `activate_profile` press actions. Executable actions, asynchronous supervision, execution history, long/double press, configuration watching, foreground observation, and Swift mapping are excluded.
- Preliminary invariants: unknown profile IDs do not mutate state; activating the current profile is an idempotent no-op; a transition publishes new input bindings only after the complete display update succeeds; uncertain device writes fail-stop rather than claiming either state.

### M-04-P01 — Freeze profile and activation contracts

- Status: complete on 2026-09-05 after owner confirmation and architect review A01, with the profile bound corrected to 31 for the 16-KiB IPC frame.
- Goal: define strict configuration, stable IDs, startup/default behavior, transactional activation, input-event ordering, bounded IPC methods, error taxonomy, and verification gates before implementation.
- Role: architect advises; main agent confirms material choices with the owner.
- Dependencies: M-03.
- Contract: strict schema version 2 replaces `pages` with `default_profile_id` and `profiles`; version 1 is rejected and never rewritten. Profiles have case-sensitive stable IDs, labels, complete 14-position layouts, and optional strict `activate_profile`/`press` actions. At most 31 profiles are accepted so a worst-case compact `profiles.list` response plus LF remains within 16,384 bytes under Go's default HTML escaping.
- Activation: one coordinator serializes IPC and completed-press intents. Current-profile activation is a zero-write `changed:false` success. A new profile commits its ID and bindings only after the full page write succeeds; uncertain writes withdraw readiness and fail-stop without retry or rollback.
- IPC: compatible internal protocol-v1 extensions `profiles.list` and `profiles.activate`; existing health/status shapes remain unchanged. Swift owns foreground bundle-ID mappings and sends only profile IDs.
- Blockers: none.

### M-04-C01 — Profile configuration

- Status: complete on 2026-09-06 after independent verification V02 passed strict decoding, semantic boundaries, catalog immutability, schema determinism, race, and vet gates.
- Goal: replace the milestone-private single-page model with strict named profiles and one default profile without adding app mappings.
- Dependencies: M-04-P01.

### M-04-R01 — Runtime profile service

- Status: complete on 2026-09-06 after remediation R01-R03 and independent verification V04 passed transactional, concurrency, fail-stop, dynamic-binding, diagnostic-cancellation, race, vet, and compile gates.
- Goal: own current/default profiles and serialize transactional D200X redraw plus input-binding replacement.
- Dependencies: M-04-C01.

### M-04-I01 — Profile IPC

- Status: complete on 2026-09-06 after independent V01 passed strict protocol, frame-boundary, runtime-adapter, CLI, race, vet, build, and unsandboxed Unix-socket gates.
- Goal: expose bounded profile listing and activation through the existing authenticated generation-attributed Unix IPC.
- Dependencies: M-04-R01.

### M-04-A01 — Built-in profile activation

- Status: complete on 2026-09-06 after independent V01 passed state-machine, emission-order, wake-suppression, concurrency, race, vet, compile, and whole-tree tests.
- Goal: recognize one complete configured `press` gesture and invoke the same profile service used by IPC.
- Dependencies: M-04-R01.

### M-04-V01 — Profile verification

- Status: complete on 2026-09-07; the physical gate exposed the fixed-path live-redraw confound and opened the corrective protocol tasks.
- Goal: independently verify configuration, transition, concurrency, IPC, built-in action, failure, and owner-visible physical behavior.
- Dependencies: M-04-I01 and M-04-A01.

### M-04-D02 — Typed live-display update

- Status: complete on 2026-09-07 after physical protocol isolation and independent archive, API-safety, batch, race, vet, and compile verification.
- Goal: encode one validated square or wide position as a deterministic content-addressed Studio-shaped `0x000d` archive through a typed production-only API.
- Dependencies: M-04-V01 physical failure and bounded `0x000d` square/cache/wide trials.

### M-04-R02 — Live profile redraw correction

- Status: complete on 2026-09-07 after independent V02 passed 100-repeat transition/failure/action race stress, full runtime race, vet, compile, formatting, and diff gates.
- Goal: preserve verified startup `0x0001` while activating profiles through one prebuilt, serialized 14-position targeted-update batch with fail-stop uncertainty semantics.
- Dependencies: M-04-D02.

### M-04-V02 — Corrected profile verification

- Status: complete on 2026-09-08; sequential targeted redraw worked physically but visibly updated positions one at a time, which opened M-04-P02/R03.
- Goal: repeat comprehensive automatic gates and owner-visible default, IPC, button, wake, dynamic-binding, and shutdown acceptance against the corrected live redraw path.
- Dependencies: M-04-R02.

### M-04-P02 — Content-addressed bulk-redraw protocol gate

- Status: complete on 2026-09-08 after automatic archive/frame verification and an owner-observed physical repeat.
- Goal: determine whether one complete live `0x0001` archive with content-derived icon paths redraws all 14 positions, because the earlier fixed-path trial was confounded by subsequently verified path-sensitive image replacement.
- Scope: one spike-only complete archive from a verified default baseline; distinct labels and artwork at every position; exactly one `0x0001` command; no brightness, unlock, input-enable, retry, or production behavior change.
- Acceptance: record whether the owned D200X applies the page in bulk, applies it progressively, or ignores it; retain raw observation separately from the inferred production choice.
- Dependencies: M-04-V02 physical observation and the completed content-derived `0x000d` control.

### M-04-R03 — Content-addressed bulk profile redraw

- Status: complete on 2026-09-08 after architecture remediation and independent automatic verification passed without skips.
- Goal: replace the sequential 14-command live profile transition with one prebuilt content-addressed full-page `0x0001` archive while retaining transactional runtime and fail-stop semantics.
- Scope: a typed production bulk-redraw encoder/session operation, runtime integration, removal of mixed-state input suppression that exists only for sequential writes if no longer required, and corrected automatic/physical verification.
- Constraints: startup behavior remains independently specified; current-profile activation remains zero-write; one transition emits exactly one bulk display command and no brightness, unlock, input-enable, retry, or rollback command; transport uncertainty remains terminal.
- Acceptance: archive tests prove all 14 positions, content-derived image paths, exact square/wide geometry, and deterministic framing; runtime/IPC/action tests prove one-command commit/failure behavior; owner observes default, IPC, and button-driven transitions.
- Dependencies: M-04-P02.

### M-04-V03 — Final bulk profile verification

- Status: complete on 2026-09-08 after independent automatic gates and owner-visible default, IPC, idempotency, button, trace, and shutdown checks passed.
- Goal: verify default startup plus IPC- and button-driven profile transitions use the final content-addressed bulk operation on the owned D200X.
- Acceptance: default renders; IPC activation changes all 14 positions without visible progressive replacement; repeated current activation is zero-write; completed configured button press returns to the default profile; shutdown removes generation metadata and socket.
- Dependencies: M-04-R03.

## M-05 — Bounded executable press actions

- Status: complete on 2026-09-08 after automatic, architecture, independent, and owner-visible physical acceptance passed.
- Goal: execute one trusted owner-configured program from a completed ordinary button press without blocking HID input, idle/keepalive behavior, profile activation, or IPC, and retain bounded queryable results.
- Scope: additive strict schema-version-2 `execute` action; absolute executable plus literal argument vector; one isolated runtime-owned worker and one active child globally; timeout and shutdown process-group termination; generation-local bounded execution history; read-only list/get IPC and CLI.
- Constraints: no shell, command string, interpolation, `PATH` lookup, inherited runtime environment, configurable environment, configurable working directory, queue, concurrent children, persistence, IPC-triggered execution, retry, Swift changes, configuration reload, or long/double press. The child working directory is `/`; its environment contains only a fixed minimal `PATH`. Execution failure does not fail-stop the D200X runtime.
- Bounds: default timeout 10 seconds; accepted timeout 1..60 seconds; at most 32 literal arguments, 1,024 UTF-8 bytes each and 8,192 bytes total; one active child with busy attempts retained; 32 history entries; separate 4,096-byte stdout/stderr tails plus total-byte and truncation metadata.
- Lifecycle: start the child in a new process group; timeout or runtime shutdown sends group `SIGTERM`, waits at most two seconds, then sends group `SIGKILL` and reaps the direct child. Shutdown closes admission before cancellation and does not wait for the configured action timeout.
- Privacy: history never stores or returns executable paths, arguments, working directory, or environment. Output remains generation-local memory and is base64 in IPC. IPC cannot start, retry, cancel, or supply a command.
- Future boundary: configured env-file loading for Hidhogg and explicit variable-name exposure to child actions require a separate contract. They must not implicitly forward the runtime environment and are outside M-05.

### M-05-P01 — Freeze executable-action contracts

- Status: complete on 2026-09-08 after owner confirmation and architecture review A01.
- Goal: define the smallest secure synchronous child-execution slice without blocking runtime coordinators.
- Acceptance: configuration, execution, concurrency, lifecycle, output/history, IPC, CLI, privacy, and failure semantics are explicit and bounded.

### M-05-C01 — Executable-action configuration

- Status: complete on 2026-09-08 after schema regeneration and independent semantic, strictness, immutability, race, vet, and diff verification passed.
- Goal: add an immutable strict `execute`/`press` action variant with absolute executable, literal bounded arguments, and optional bounded timeout.
- Acceptance: schema generation and semantic tests cover every bound and reject relative paths, shell-shaped fields, unknown fields, NUL, invalid UTF-8, unsupported gestures, environment, and working-directory fields.
- Dependencies: M-05-P01.

### M-05-E01 — Execution worker and history

- Status: complete on 2026-09-08 after architecture remediation and independent process, lifecycle, history, UUID, concurrency, race, vet, and cgo-free gates passed.
- Goal: implement one nonblocking runtime-owned worker that synchronously supervises one process and records bounded generation-local results.
- Dependencies: M-05-C01.

### M-05-R01 — Runtime, IPC, and CLI integration

- Status: complete on 2026-09-08 after architecture acceptance and main/independent automatic gates passed.
- Goal: route completed presses to the worker and expose strict read-only `executions.list`/`executions.get` discovery and legacy CLI operations.
- Dependencies: M-05-E01.

### M-05-V01 — Independent executable-action verification

- Status: complete on 2026-09-08. Automatic and architecture gates passed; the owner-visible local execution/history slice passed on the owned D200X.
- Goal: verify configuration, literal argv, minimal environment, nonblocking runtime behavior, busy rejection, output bounds, all terminal states, bounded shutdown, history eviction, IPC framing, and CLI behavior without executing arbitrary host programs or accessing HID/network.
- Dependencies: M-05-R01.
- Physical acceptance: a temporary schema-v2 profile bound top-left `0_0` to absolute `/usr/bin/printf` with literal metacharacters in its argument. One owner-confirmed press/release produced one exited history entry with exit code 0, no signal or supervision error, 32 stdout bytes, empty stderr, and no truncation. `executions.get` decoded exactly to `literal:a;$(not-executed)|*.txt\n`, demonstrating that `;`, `$()`, `|`, and `*` were not interpreted by a shell. Controlled shutdown removed `runtime.sock` and generation metadata while retaining `runtime.lock`.
- Evidence boundary: this proves the configured direct-argv vertical slice on the owned D200X and the queried generation. It does not prove arbitrary executable compatibility, persistent history across generations, asynchronous/concurrent child support, configuration reload, long/double press, or environment-file exposure; those remain outside M-05.

## M-02-F01 — Screensaver wake and keepalive correction

- Status: complete on 2026-09-03 after the production idle policy passed automatic, architecture, and owner-present physical gates.
- Goal: determine which non-encoder controls remain available while brightness persists at zero, characterize encoder rotation as the observed brightness-restoration transition, determine which allowlisted packets recover a live session from the firmware screensaver, and select a measured application-owned idle strategy.
- Scope: a bounded diagnostic mode; minimal square baseline followed immediately by brightness zero; continuous compact wide/button/square capture while zero persists; one encoder rotation ending that state with a closed visual attestation; configured-brightness recovery; firmware-screensaver wake attempts using only brightness, unlock, input-enable, and complete configured-page upload; owner-run archival wrappers; an isolated spike-only one-frame probe for all 12 known command IDs; durable fake-transport packet-order and refusal tests.
- Constraints: one explicit device and owner confirmation; never send arbitrary commands; never automatically retry an uncertain write; one wake attempt per fresh firmware-screensaver generation so results are attributable; preserve bounded redacted diagnostics.
- Acceptance: required wide, physical-button, and square controls are classified while brightness persists at zero; encoder rotation is recorded only as the state-ending transition and never as persistent-zero evidence; its brightness-to-100 effect requires an exact contemporaneous owner attestation; each wake packet is pass, fail, or not run; successful wake requires visible recovery where applicable and resumed decoded input; unsuccessful attempts do not silently continue as healthy.
- Decision gate: if brightness zero preserves input, the first wake interaction is consumed before configured actions and restores configured brightness. If it suppresses input, use a measured alternative rather than claiming brightness zero is wakeable.
- Evidence record: `docs/research.md`, section `M-02-F01 — D200X idle and protocol research`.
- Completed support: the `metrics` preset generates and reports nonzero synthetic CPU/RAM/GPU values per invocation while retaining strict JSON fixtures. Exact payload, random-source failure at every draw position, no-retry, pre-HID refusal, race, and independent verification pass without HID access. The observed hypothesis that mode `0` updates values and mode `2` selects their display remains a physical research question.
- Controlled wake evidence: S0 passive open plus one `0_0` press left the native screensaver visible and emitted no input. From a new generation, exactly one `enable-input-stream` (`0x0002`) frame dismissed the visible screensaver and restored the canonical `0_0` press/release pair. Keepalive prevention and interval remain pending.
- Excludes: production exposure of experimentally unsafe commands, arbitrary numeric commands or payload injection, production actions, notifications, SwiftUI, config watching/editing, reconnect hardening, and implementation of the final idle policy before the matrix is reviewed.

### M-02-F01-K01 — Bounded keepalive-prevention diagnostic

- Status: complete on 2026-08-31 after automatic gates, independent tester review, and architect review passed without physical HID activity.
- Goal: provide one diagnostic-only monotonic scheduler that can test whether periodic `enable-input-stream` prevents the measured native idle failure.
- Scope: add the closed `keepalive-prevention` mode; require explicit positive interval and duration; enforce `D = 4I` and `D <= 60m`; keep one HID session; send exactly four experimental `EnableInputStreamFrame` writes; archive one owner-confirmed invocation through a dedicated wrapper.
- Constraints: no production runtime timer, TOML field, Swift/UI surface, generic repeated command, catch-up write, retry, or silent continuation after a short, failed, late, or uncertain write.
- Acceptance: fake-clock and fake-transport tests prove four absolute scheduled boundaries and frame count, zero writes before confirmation, cancellation, no retry, late-boundary invalidation, bounded completion, final `0_0` verification, and an exact 11-record redacted archive; the core and wrapper reject schedule mismatch or duration above 60 minutes before HID activity; cgo-free tests, race tests, vet, wrapper tests, and independent tester review pass.
- Roles: main agent owns integration and durable decisions; `executor_light` owns the bounded implementation; `tester` owns independent verification; `explorer` supplies read-only interface findings.
- Dependencies: controlled S0/S1 evidence and architect-approved experiment design recorded on 2026-08-31.
- Verification gate: no physical K1 trial until automatic and independent gates pass.
- Verification: the full cgo-free Go suite, focused race tests, vet, zsh syntax, jq/Python/Ruby archive regressions, formatting, and diff checks passed; independent tester `M-02-F01-K01-V02` passed. No physical HID trial was part of K01.
- Residual: wake jitter before the next interval boundary is accepted by the approved scheduler contract, so physical evidence must retain actual timing; the retained 48-boundary guard is unreachable under the closed four-boundary K1 contract and remains defense-in-depth only.
- Blockers: none; K02 requires owner-visible device-state reporting and the bounded wait.
- Parallel boundary: read-only interface audit may run alongside implementation; source ownership remains exclusive to the executor.

### M-02-F01-K02 — Paired C0/K1 physical evidence

- Status: complete on 2026-09-01 as a bounded pass by explicit retrospective owner waiver of serialized per-boundary timestamps.
- Goal: determine whether a measured periodic `0x0002` interval prevents the observed idle failure on the owned D200X.
- Scope: measure one no-write onset `T0` with a predeclared 30-minute ceiling; derive `I = T0 / 2` and `D = 2 * T0`; run one K1 session without physical interaction until `D`; verify visible activity and one canonical `0_0` press/release at the end.
- Constraints: use a fresh active state for each phase; no unrelated frames, retries, catch-up writes, or owner interaction during the idle window; stop on screensaver appearance or uncertain write.
- Acceptance: C0 reaches the visible screensaver and suppresses `0_0`; K1 remains visibly active for `D`; the final canonical press/release pair is captured; every result is classified without claiming a maximal interval or cross-firmware generality.
- Roles: main agent operates the harness; owner reports visible device state and performs the single requested input; architect reviews ambiguous outcomes.
- Dependencies: M-02-F01-K01 automatic and independent gates.
- Verification gate: evidence timestamps, derived interval/duration, scheduled writes, visual result, and input hashes are recorded before policy selection.
- Evidence: the first 2026-08-31 attempt reached the 30-minute ceiling without a contemporaneous visual report and remains rejected. In the repeated owner-observed C0, the configured display was visible after reset, native screensaver onset was reported 64 seconds later, and one `0_0` press/release neither woke the display nor emitted an input frame. The conservative K1 parameters are `I = 32s`, `D = 128s`.
- K1 attempt: one `I = 32s`, `D = 128s` invocation archived four passing boundaries and a passing schedule, but final verification was delayed until after the screensaver recurred. No input pair was captured; the checksum-valid archive records `class-failure`. This does not establish state at `D` and is not a prevention pass.
- Replacement decision: architect review permits exactly one clearly labeled replacement with unchanged parameters because the original primary endpoint was not observed contemporaneously. The first archive remains retained as scheduler-valid and endpoint-inconclusive; it is not a negative replicate.
- Replacement result: the owner reported the display active at the spoken cue, then screensaver onset before there was enough time to press; no input pair was captured. The agent-mediated cue could not be proven within the five-second endpoint window. The checksum-valid archive records `class-failure` and is endpoint-inconclusive.
- Scheduler-coupled result: archive `20260831T064118Z-keepalive-prevention` is checksum-valid and passes its strict 14-record schema. It records accepted same-process preflight, four ordered boundary writes, healthy capture, `ACTIVE_AT_CUE`, one adjacent canonical wire-0 press/release pair in the logical window, endpoint timing within tolerance, and diagnostic `pass`/exit 0.
- Evidence classification: the four boundary records retain ordinals but not actual monotonic wake/write timestamps. Architect `A07` therefore rejected prospective compliance and tester `V01` classified the physical inference as inconclusive. On 2026-09-01, after reviewing the favourable endpoint outcome, the owner explicitly waived that retention requirement and accepted the categorical scheduler-window evidence. Architect `A08` classifies K02 as bounded pass by retrospective waiver, not an unqualified or prospectively compliant pass.
- Permitted claim: on this owned D200X specimen, one 128-second run containing four ordered `0x0002` writes accepted within 32-second categorical scheduler windows remained visibly active and produced one valid canonical input pair at the coupled endpoint.
- Constraints: exact 32-second delivery, maximal safe interval, sustained reliability, cross-device or cross-firmware behaviour, and production policy remain unproven. The physical authorization is consumed; no further K1 is authorized. A 16-second cadence is a conservative analytical production candidate, not measured physical evidence, and remains gated by B01 plus explicit owner policy confirmation.
- Parallel boundary: none; device-state interventions are sequential.

### M-02-F01-K02-R01 — Scheduler-coupled endpoint instrumentation

- Status: complete on 2026-08-31 after independent verifier `V04` and final architect review `A06` passed.
- Goal: remove agent, chat, terminal-Enter, and external-cue latency from the K1 composite endpoint before one final revised physical invocation.
- Scope: add an injectable diagnostic endpoint cue; use only fixed absolute `/usr/bin/say` with fixed text in the macOS CLI; retain continuous capture across the idle schedule and take a fresh endpoint-eligibility boundary immediately before cue invocation; require successful cue completion within 12 seconds; set the logical input-window close five seconds after completion; require actual timer wake and capture stop no earlier than that close and no more than 250 milliseconds late; collect one post-window visual attestation token; record distinct monotonic elapsed cue, planned-close, actual-wake, actual-stop, and input timing; revise strict archive validation and metadata.
- Constraints: no arbitrary command, path, text, environment, shell, TOML, production runtime, Swift/UI, HID packet, interval, duration, retry, catch-up, or owner-response window surface. Preflight must use the same cue implementation and complete before HID confirmation; the preflight owner-heard response remains an external operator gate recorded by the wrapper.
- Acceptance: deterministic tests prove exact fixed cue invocation and exact same-process `CUE_HEARD` before runner construction/HID; capture-health checks before and after each write and before cue; no later write/cue after terminal failure or exhaustion; 12-second timeout enforcement even for an injected cue that ignores cancellation; no attestation after invalid timing; automatic five-second logical window; inclusive logical bounds; actual close lateness at 0/250 milliseconds and rejection at 250 milliseconds plus 1 nanosecond; inbound-malformed versus terminal transport classification; cancellation-safe terminal commits; the complete visual-token and canonical-pair outcome table; mandatory redacted capture-health and non-droppable required observations; jq/Python/Ruby validators require preflight, capture-health, and planned/actual timing evidence; full cgo-free tests, race, vet, formatting, and independent tester review pass.
- Roles: main agent owns protocol integration and durable records; `explorer` audits existing cue/process/capture seams; `executor_light` owns the bounded diagnostic implementation; `tester` independently verifies automatic gates; architect reviews the final evidence boundary.
- Dependencies: both retained scheduler-valid endpoint-inconclusive K1 archives and architect decision `M-02-F01-K02-A02`.
- Verification gate: no further physical K1 invocation until automatic tests, independent tester, architect review, and same-cue owner preflight pass.
- Verification: `V01` found fail-open capture handling; `V02B` found the early cue boundary; `V03` found jq/Python/Ruby canonical-pair parity drift. Corrections `R05` through `R08` closed each finding. Main unrestricted `go test ./...`, focused race/vet, shell syntax, all archive backends, independent `V04`, and final architect `A06` pass.
- Blockers: none in R01. The K02 physical authorization was consumed; prospective K1-50 is tracked separately as K03.
- Parallel boundary: read-only interface audit may overlap implementation planning; source ownership remains exclusive to the executor.

### M-02-F01-K03 — Prospective 50-second cadence evidence

- Status: complete on 2026-09-01. The owner explicitly accepts the independently operated passing archive `20260901T065715Z-keepalive-prevention` as the authoritative and sufficient K03 result; earlier agent-mediated attempts remain historical procedural failures and do not define the K03 outcome.
- Goal: test whether one owned D200X remains active and accepts canonical input through a prospective 200-second run with a nominal 50-second `enable-input-stream` cadence.
- Scope: retain the closed four-boundary diagnostic with `I = 50s`, `D = 200s`; serialize each boundary's planned monotonic elapsed time, actual timer-wake elapsed time, write-start elapsed time, and successful write-completion elapsed time; require `planned <= wake <= start <= completion <= planned + 250ms`; retain the scheduler-coupled cue, five-second endpoint window, exact owner attestation, and strict archive.
- Constraints: exactly four `0x0002` writes; no catch-up, retry, extra command, production runtime change, TOML/UI surface, or reinterpretation as a K02 retry. No physical invocation before automatic, independent, and final architect gates pass.
- Acceptance: all four boundary timing values are present and ordered for boundaries 1–4 under `timing_contract = k1-50-v1`; zero and exactly 250 milliseconds late pass while 250 milliseconds plus 1 nanosecond, early/reordered/missing timing, and completion after the bound invalidate without retry or catch-up; fourth completion precedes the fresh cue boundary; capture remains healthy; the display is active at the coupled cue; exactly one canonical wire-0 press/release pair occurs in-window; hashes and strict jq/Python/Ruby validation pass; all outcomes are retained and classified.
- Roles: main agent owns contract integration and durable records; architect fixes timing semantics; `executor_light` implements bounded code/schema changes; `tester` independently verifies; owner performs the one approved physical interaction only after gates pass.
- Dependencies: bounded K02 pass by retrospective waiver and explicit owner confirmation of the new prospective protocol.
- Verification gate: no physical K1-50 until full Go, race, vet, shell/archive, independent tester, and final architect reviews pass.
- Verification: implementation reviews `R01` and `R02`, main focused/race/vet/shell/archive checks, independent tester `V02`, and final architect `A02` pass. The full Go suite's only reported failure is sandbox-denied Unix-socket creation in unrelated `internal/ipc` tests.
- Physical evidence: archive `deploy/diagnostics/20260901T063506Z-keepalive-prevention` retained four passing boundaries. Completion lateness was 1.711458 ms, 1.576791 ms, 1.988541 ms, and 1.326333 ms; capture health passed and boundary four completed 1.145 ms before cue start. The endpoint attestation received `CUE_HEARD` where the closed protocol required `ACTIVE_AT_CUE`, `SCREENSAVER_AT_CUE`, or `UNCERTAIN`; no canonical input pair was retained, so final verification and result are indeterminate.
- Authoritative physical evidence: archive `deploy/diagnostics/20260901T065715Z-keepalive-prevention` passes strict validation and recorded checksums. Four `k1-50-v1` boundaries completed 1.694333–2.852750 ms after plan, capture remained healthy, boundary four preceded the cue, `ACTIVE_AT_CUE` was recorded, and exactly one canonical wire-0 square press/release pair occurred in-window. Endpoint and result are `pass`.
- Blockers: none for K03. This closes K03 only; it does not complete the separate B01 brightness-zero matrix or select the production idle policy.
- Parallel boundary: read-only contract audit may overlap planning; implementation ownership remains exclusive.

### M-02-F01-B01 — Archived brightness-zero matrix

- Status: complete on 2026-09-03 by explicit retrospective owner acceptance of the technically valid replacement archive. The prospectively authorized first run remains a valid class-failure; the owner-initiated second run is authoritative for the bounded one-device B01 decision. This is a procedural authorization deviation and does not establish repeatability.
- Goal: classify required non-encoder inputs while brightness persists at zero, the encoder-triggered brightness-restoration transition, and configured-brightness recovery in one trusted archive.
- Scope: run the revised owner-confirmed matrix once; capture exact wide-13, button-15/16, and square-0 pairs before one encoder rotation; require a closed structured brightness-100 attestation; restore configured brightness once; validate archive metadata, manifest, observations, and exit status.
- Constraints: use position `0_0` for the baseline; do not use a failed, partial, indeterminate, or not-run archive as evidence; do not silently substitute prior informal probe observations.
- Acceptance: every required zero-persistent pair is exact; the first encoder-17/18/19 left/right rotation ends the zero window and is not counted as zero-state evidence; only `BRIGHTNESS_100_OBSERVED` supports the transition; post-transition input before recovery fails; configured brightness is restored exactly once; the recovery square pair and all stages pass in a checksum-verified archive.
- Roles: main agent reviews and operates the harness; owner performs prompted inputs; tester independently validates a completed archive if one is produced.
- Dependencies: record-cap review; independent of K02 after K01 verification.
- Verification gate: archive validation passes before M-02-F01-P01.
- Verification: structured brightness attestation, exact matrix ordering, encoder-transition classification, pre-shutdown trailing-input invalidation, configured restore-once/no-retry behavior, and jq/Python/Ruby archive agreement pass focused, full diagnostic, race, vet, command, shell, and archive gates. Repository-wide cgo-free tests remain limited only by sandbox-denied Unix sockets in the unrelated IPC package.
- Physical result: archive `deploy/diagnostics/20260902T235304Z-brightness-zero` records passing baseline, zero write, structured `BRIGHTNESS_100_OBSERVED`, configured restore, and recovery. It records exact wide-13 and button-15/16 pairs, then encoder-17 left; the required zero-state square-0 pair is missing, so the matrix is `class-failure`, result is `fail`, and exit status is 1. All three archive hashes match the manifest.
- Authoritative result: archive `deploy/diagnostics/20260903T032301Z-brightness-zero` has matching metadata/stdout/stderr hashes, passes strict validation, and records the complete baseline, zero-state wide-13/button-15/button-16/square-0 sequence, encoder-17-left transition, structured `BRIGHTNESS_100_OBSERVED`, configured restore, and recovery pair with no contrary or trailing record.
- Governance: this replacement was initiated outside the consumed no-retry authorization. On 2026-09-03 the owner explicitly accepted it retrospectively as authoritative and sufficient. Preserve the first class-failure and this deviation; no third B01 run is justified.
- Blockers: none for B01. M-02-F01-P01 may proceed to explicit owner idle-policy selection.
- Parallel boundary: source review can overlap K01, but physical execution cannot overlap any other HID trial.

### M-02-F01-P01 — Evidence-based production idle policy

- Status: complete on 2026-09-03 after automatic, architecture, and owner-present physical gates passed. Optional `idle_timeout_seconds` defaults to 300, accepts 0 to disable application dimming, and is bounded at 86,400. Connected sessions retain fixed absolute 50-second `0x0002` keepalives even when dimming is disabled. Idle sends brightness zero once; the first known physical gesture restores configured brightness and is consumed as a complete press/release pair or one rotation. Unknown input does not wake. Any uncertain write fail-stops the runtime without retry; IPC and supervisor policy are unchanged.
- Goal: select and verify the smallest production change supported by K02 and B01.
- Scope: review measured evidence with the architect; update the decision-review record; implement only the selected wake/keepalive and application-owned idle behavior; verify failure reporting and shutdown.
- Constraints: do not infer prevention from wake sufficiency, generalize beyond the tested firmware, or add configuration/UI scope without a new owner decision.
- Acceptance: the selected policy is traceable to measured results; automatic tests and an independent tester pass; the owner verifies the relevant physical outcome; roadmap, research, log, and handoff are current.
- Roles: architect advises policy; main agent decides integration boundary with the owner; executor and tester are assigned after the evidence gate.
- Dependencies: M-02-F01-K02 and M-02-F01-B01.
- Verification gate: explicit owner confirmation of the evidence-backed policy before production source changes.
- Implementation: P01-R01/R02 add the optional strict configuration field and schema plus a runtime-owned injectable idle coordinator. Encoder-marker press/release support was corrected after independent V01 found it missing. Complete gesture suppression keys marker and wire; unrelated events remain deliverable; all policy goroutines and timers finish before session close.
- Automatic verification: independent V01/R02 passed configuration/schema parity, deterministic scheduling and boundary precedence, active/dimmed/disabled keepalive, all known button/encoder gestures, fail-stop/no-retry behavior, bounded output, lifecycle, full tests, race, vet, build, schema staleness, formatting, and diff checks without HID access. Final architect review passed. Milestone-close V03 repeated the full, race, vet, build, schema, formatting, and diff gates and passed P01 closure. Its 1,000-repeat race stress found two low-severity fixed-wait test-synchronization weaknesses, not runtime defects; hardening them is deferred rather than required for P01 acceptance.
- Physical gate: passed on 2026-09-03 in one owner-present acceptance session using temporary `idle_timeout_seconds = 5` and verbose logging. The owner confirmed idle blanking and that the display remained blank through the first scheduled post-startup `0x0002`. The first square `0_0` pair restored configured brightness and emitted no input JSON; after re-idle, a first quick pair was again consumed and a second quick pair emitted exactly one ordered pressed/released JSON pair. The runtime then dimmed once more and clean SIGINT shutdown removed the Unix socket. An earlier setup run interrupted for requested temporary-file cleanup is excluded. Precise timing remains automatic-test evidence.
- Blockers: none.
- Parallel boundary: no production implementation before both evidence dependencies are reviewed.

## M-02-F02 — Ulanzi Studio static interoperability analysis

- Status: complete on 2026-08-30 after bounded static analysis and independent command-path cross-check.
- Goal: derive implementation-neutral evidence for unresolved D200X packet constructors and state transitions from a lawfully installed Ulanzi Studio bundle.
- Scope: preserve a temporary specimen copy; record hashes, Mach-O architecture, signing metadata, dependencies, and analysis-tool provenance; statically narrow D200X framing, command construction, and the `hid_write` boundary; prioritize `0x0003`, `0x000b`, `0x000d`, `0x0011`, `0x010b`, and `0x0303`.
- Constraints: installed application remains untouched and unlaunched; do not inspect application data, preferences, logs, accounts, telemetry, or unrelated assets; do not bypass encryption, hardened runtime, signing, DRM, authentication, or access controls; repository records contain only offsets, hashes, pseudocode, byte contracts, and evidence classifications—not proprietary code or assets.
- Acceptance: each finding is classified as captured bytes, observed chronology, hypothesis, or causal claim; static evidence names its specimen hash and method; unresolved interpretations remain explicit; dynamic tracing requires a separate owner approval.
- Excludes: application launch, debugger attachment, code injection, patching, resigning, redistribution, proprietary asset extraction, and production implementation before evidence review.

## M-02-F03 — Ulanzi Studio bounded LLDB observation

- Status: static, connection, T03-T04 font deltas, T05-T07 targeted-key, T08 mode-100, T09-T11 input, and T12 wide-background research complete on 2026-08-30. Two metadata-only trials, two full-payload repeats, controlled `0x000d`/`0x0011` archives, exact `0x0101` input frames, and visible background rendering were captured from authorized owner-only, ad-hoc-signed disposable copies. Screensaver trials remain owner-driven.
- Goal: capture exact controlled D200X command payloads and inbound responses at the already identified application HID boundary.
- Initial scope: two repeat connection-only trials, T01 and T02. The owner selected the existing macOS account and accepted prior local application state, while restricting capture to command IDs, lengths, inbound eight-byte headers, and bounded stacks without payload contents. A validated per-process network-deny enclosure was attempted but invalidated application startup; the owner then explicitly accepted normal network access and its stated disclosure risk for the disposable copy.
- Preparation: static specimen/hash preflight, ASLR-safe application breakpoints, owner-only temporary workspaces, bounded capture hashing, manifest comparison, and an interactive runbook.
- Gate: T03-T12 are complete except for the separately planned screensaver-causality trials. T09-T11 independently confirmed square and middle-encoder `0x0101` wire-index, marker, and action bytes. Proceed only with fresh-state screensaver interventions, one candidate command per state. Ordinary Studio display edits transmit immediately, while T12 established that background artwork uses a distinct Save boundary.
- Constraints: ordinary LLDB operation only; apart from the recorded disposable-copy ad-hoc-signing exception, do not patch, resign, inject, weaken platform security, inspect unrelated memory or application state, or store raw captures in the repository by default.
- Acceptance: captures have command, direction, length, hash, call origin, action, chronology, outcome, evidence classification, and explicit uncertainties; repeated observations remain chronology unless controlled intervention supports causality.
- Prior blocker: ordinary LLDB launch failed before target execution. The authorized disposable ad-hoc-signed copy resolved the attachment issue without changing SIP, AMFI, debugger authorization, entitlements, or other system controls.
- Authorized exception: ad-hoc sign only a new temporary bundle; require whole-executable identity before signing and identical `__TEXT,__text` machine-code bytes afterward because embedded-signature replacement necessarily changes the whole-file hash. Leave the installed bundle and static copies unchanged; preserve metadata-only capture; do not change SIP, AMFI, entitlements, debugger authorization, or other system controls.
- Rejected sandbox run: strict signature verification passed and `__TEXT,__text` matched the installed specimen, but the target reported sandbox initialization failure under per-process network denial and neither breakpoint fired. This run is invalid protocol evidence.
- Network exception: normal application network access is permitted only for the disposable T01/T02 research copy because the network-deny enclosure invalidated startup. Do not inspect network traffic or unrelated application state; discard target stdout/stderr; preserve no-login, metadata-only capture, and the T01/T02 stop gate.
- Valid metadata-only result: T01 and T02 repeated the same eight-event initialization prefix: outbound `0x0003/0`, `0x0001/5633`, `0x000b/144`; inbound `0x0303/1014`; outbound `0x000a/2`, `0x0003/0`; inbound `0x0303/1014`; outbound `0x000a/2`. Both then emitted periodic outbound `0x0006`; its length was 26 in T01 and 25 in T02. That difference was unexplained within the metadata-only evidence; the later payload repeats established a data-dependent grammar that accounts for it. The sequence remains observed chronology, not a causal device ordering contract.
- Payload-inspection expansion: the owner clarified on 2026-08-30 that maximizing protocol learning is the governing goal and authorized inspection of complete D200X packets and their contents, stating that the existing application and device data contain nothing secret. This expansion covers logical HID payloads and derived JSON, ZIP, image, profile, and device-metadata content. It does not cover unrelated application memory or network-traffic inspection. Repeat connection trials `T01P` and `T02P` retained raw captures owner-only outside Git; the newly created disposable app copy was removed at the review gate.
- Full-payload result: `0x0003` is empty; `0x000b` is stable 144-byte indented six-field font JSON; inbound `0x0303` is stable 149-byte five-field device JSON plus 865 NUL bytes; `0x000a` is stable ASCII `44`; and mode-`100` `0x0006` is a data-dependent pipe-delimited metrics/time record. The `0x0001` ZIP changes raw UUID filenames, order, timestamps, and compressed bytes across launches, while its normalized manifest and PNG-content multiset remain stable. Manual dump stops perturb chronology, so the original auto-continue trials remain the timing evidence.
- Final static result: `0x0001`, `0x000d`, and mode-100 `0x0011` share one manifest/archive builder; `0x000d` selects one key and `0x0011` selects current-page `Encoder` profiles. `0x010b` triggers retransmission of the current `0x000b` font JSON. Studio consumes `SerialNumber`, `Dversion`, and optional `HardwareVersion` from `0x0303`. `0x000a` reads persisted per-device brightness. Remaining questions are device-side causal effects or cross-firmware variability.
- T05-T07 result: a built-in Text action at `0_0` emits one position-keyed render entry; equal-length title changes alter only `Text`; delete emits an explicit empty `Font`/`Text` tombstone; moving to `1_0` emitted new content followed by the old-position tombstone. Repeat normalized manifests and PNG bytes were stable. No independent device-side ordering requirement is claimed.
- T08 result: static and dynamic evidence corrected the trigger assumption. `0x0011` is emitted by selecting Studio's mode-100 `Knob` radio, not by assigning an encoder action. Two controlled `Time` to `Knob` transitions each emitted exactly one 1,866-byte ZIP; normalized manifests and PNG bytes matched. The manifest maps knobs 1-3 to positions `2_3`, `3_3`, and `4_3`, with explicit tombstones for the two empty knobs. Firmware necessity, minimal fields, and ordering relative to `0x0006` remain unresolved.
- T03 result: two controlled `bottom` to `center` title-alignment edits each emitted one 1,680-byte `0x000d`. Normalized manifests and PNG bytes matched, and only `Font.Align` differs from the retained bottom baseline.
- T04 result: one title-size increment from 10 to 11 emitted one 1,678-byte `0x000d`. After UUID normalization only `Font.Size` differs from the retained baseline; PNG bytes are unchanged.
- T12 result: the wide tile is `3_2`, and Studio's Background radio supplies numeric mode `2`. No immediate `0x0006`/`2|` followed the controlled radio transition. Saving a project-owned 458-by-196 diagnostic image emitted one 1,608-byte `0x000d` archive with `SmallViewMode: 2`; Studio converted RGB to RGBA and applied rounded transparent corners without changing dimensions. The owner confirmed correct full-width device rendering.

### M-02-F03-T13 — Studio screensaver-artwork upload

- Status: bounded dynamic research completed on 2026-09-02. SS-U0 produced only periodic traffic and no visible change. SS-U1 captured an attributable `0x0009` upload for A and the owner confirmed A visible. SS-U2 captured an attributable `0x0009` upload for B and the owner confirmed B visible, but its chronology hit the 256-event safety cap before commit. The owner waived SS-U3 restoration as unnecessary for implementation.
- Goal: identify the logical D200X command, payload/archive structure, and transmission boundary used by Studio's screensaver-artwork editor.
- Scope: use two project-owned metadata-free `1220 × 708` PNGs; capture `SS-U0` click-and-cancel, `SS-U1` upload A, `SS-U2` upload B, and `SS-U3` revert to A from fresh processes; retain application-boundary chronology and inspect only payloads attributable to the controlled images.
- Constraints: `Stored Image` opens the macOS picker and `Set Image` is the explicit commit action; do not alter crop, zoom, pan, rotation, adjacent settings, brightness, or physical controls; raw captures remain owner-only outside Git; no network capture or application-state inspection.
- Acceptance: partially satisfied. The explicit commit boundary and visible A/B outcomes establish `0x0009` as the screensaver-artwork upload command. Deterministic A restoration was not tested, and SS-U2 is payload/outcome evidence rather than complete chronology evidence.
- Verification: deterministic metadata-free fixtures, owner-only marked workspaces, closed marker/specimen authorization, bounded chronology, stopped payload capture, payload-file reconciliation, LLDB ABI fakes, refusal cases, and static no-launch/HID/network checks pass. Independent V03 ran 59 fresh-workspace checks and closed all V02 defects.
- Blockers: none for implementing a thin screensaver-artwork upload slice. Exact `0x0009` payload structure, deterministic re-encoding, and restoration equality remain research gaps.

### M-02-F03-T14 — Screensaver payload contract

- Status: complete as qualified offline research on 2026-09-03 after direct artifact reconciliation and architect review. Production implementation is deferred behind M-02-F01-P01.
- Goal: identify the framing, archive/image representation, and controlled A/B differences in the retained attributable `0x0009` payloads.
- Scope: inspect only the synthetic SS-U1 A and SS-U2 B payload artifacts; record hashes, structural parsing, dimensions, compression or container signatures, and byte-delta attribution.
- Constraints: raw artifacts remain outside Git; do not infer deterministic re-encoding because SS-U3 was waived; do not inspect unrelated captures or application state.
- Acceptance: every derived field is tied to both controlled artifacts, uncertainties are explicit, and the result is sufficient to propose or reject a clean-room encoder boundary.
- Dependencies: M-02-F03-T13.
- Result: both logical payloads are one-entry ZIP archives using Deflate method 8 and containing a Studio-reencoded `1220 × 708`, 8-bit RGB PNG with one `pHYs` chunk. A is 40,982 payload bytes with a 47,567-byte PNG; B is 130,798 payload bytes with a 138,324-byte PNG. Both payload hashes, lengths, names, and authorization records reconcile.
- Boundary: a clean-room candidate may encode a bounded `1220 × 708` image as one PNG inside one standard Deflate ZIP and send it as `0x0009`. RGB conversion, alpha behavior, `pHYs`, filename, timestamps, compression settings, and byte determinism are observed Studio details rather than established firmware requirements.
- Verification: direct hash/member reconciliation passed. Architect review was conditional: close T14 as research, defer implementation until P01, and require deterministic encoder/parser tests plus one separately authorized physical acceptance test before adding `0x0009` to production.
