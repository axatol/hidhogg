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
- One reconnect/session-replacement cycle is recorded. The gate still requires two more cycles.
