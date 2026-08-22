# Hidhogg handoff

Updated: 2026-08-22

## Current objective

Complete the blocked physical portion of `S-01`, then return the combined evidence for owner decision `D-01`.

## Current state

- The repository began with only an Apache-2.0 license.
- Planning documents and both isolated spike implementations exist.
- `S-02` is complete: TOML passed 34/34 required cases and is provisionally recommended; JSONC/HuJSON did not meet strict byte preservation.
- `S-01` automatic checks pass and read-only enumeration selects one exact control collection. The first physical open returned `0xe00002e2` before any write.
- No production architecture or stable configuration format has been selected.
- Bounded brightness and diagnostic-display writes remain authorized after the open-permission blocker is resolved.

## Constraints

- Do not read secret-like paths, environment variables, personal data, or device serial numbers.
- Keep `UlanziDeckControl` reference-only.
- Do not mark the Go gate passed without every required physical observation.
- Do not publish a configuration schema before the owner resolves `D-01`.

## Next actions

1. Grant the executing application the required macOS HID/Input Monitoring permission, or run the documented physical commands from an authorized terminal.
2. Re-run the 20 open/close iterations, input matrix, brightness sequence, numbered display upload, and three reconnect cycles.
3. Record each physical criterion as pass, fail, or not run in `docs/research.md`.
4. Request owner decision `D-01`; do not scaffold production code before it is recorded.
