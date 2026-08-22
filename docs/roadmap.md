# Hidhogg roadmap

Status: feasibility investigation
Updated: 2026-08-22

Task IDs are immutable.

| ID | Status | Goal | Dependencies |
|---|---|---|---|
| P-01 | Complete | Establish planning baseline and evidence rules | none |
| S-01 | Blocked: macOS permission | Determine whether a cgo-free Go runtime can operate the physical D200X reliably | P-01 |
| S-02 | Complete | Determine whether required TOML GUI mutations can be lossless; compare JSONC fallback if not | P-01 |
| D-01 | Blocked by evidence | Owner selects runtime architecture and configuration format from the spike report | S-01, S-02 |
| M-01 | Not started | Scaffold the selected production architecture | D-01 |

## P-01 — Planning baseline

- Goal: record product intent, provisional boundaries, stable tasks, and session state.
- Acceptance: required documentation exists, contains only verified facts or explicit hypotheses, and does not claim an architecture decision.
- Verification: documentation review and clean repository inventory.

## S-01 — Cgo-free Go D200X spike

- Goal: evaluate `go-ctap/hid` on macOS 26 with `CGO_ENABLED=0`.
- Scope: deterministic interface-0 enumeration, open/close, input, brightness, diagnostic display, and disconnect/reconnect.
- Constraints: do not log device serials; do not access unrelated HID devices; do not inherit production code from `UlanziDeckControl`.
- Automatic gate: cgo-free build, unit tests for framing/selection, and testable transport lifecycle.
- Physical gate: 20 open/close iterations, representative input matrix, visible brightness/display confirmation, and three unplug/replug cycles without keyboard seizure, duplicate sessions, truncated reports, or dead reads.
- Acceptance: report every criterion as pass, fail, or not run. Recommend Go only if every required physical criterion passes.
- Current evidence: automatic checks and exact read-only collection selection pass. The first physical open returned `0xe00002e2` before any write. The remaining physical matrix is blocked pending execution with macOS HID permission; see [research.md](research.md).

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
- Blocker: owner confirmation is required; implementation must not infer the final choice.

## Parallel boundaries

`S-01` and `S-02` may proceed independently. Production scaffolding, stable schemas, and UI work must wait for `D-01`.
