# Configuration-editing feasibility spike

This is an isolated, non-production measurement harness for the provisional configuration direction in `docs/overview.md`. It does not define a stable configuration schema or compatibility contract.

Run the complete suite from this directory:

```sh
CGO_ENABLED=0 go test -count=1 ./...
```

`TestFeasibilitySuite` writes [`results.json`](results.json). The artifact is intentionally ephemeral: its fields describe this spike's current measurements and may change as the fixtures or upstream unstable APIs change.

## Dependencies

The module pins the public `v2` branch revision of go-toml because the latest tagged `v2.4.3` module does not contain `unstable/edit`.

| Module | Exact version | License | Use |
|---|---|---|---|
| `github.com/pelletier/go-toml/v2` | `v2.4.4-0.20260718201843-686c980c4758` | MIT | TOML parsing and comment/layout-preserving edits |
| `github.com/tailscale/hujson` | `v0.0.0-20260727124030-b80ff77dac4f` | BSD-3-Clause | HuJSON/JSONC comparison and RFC 6902 patching |

Checksums are recorded in [`go.sum`](go.sum). HuJSON's module metadata also records `github.com/google/go-cmp v0.7.0` (BSD-3-Clause) for its upstream tests; this spike does not import it directly.

## Measurement boundary

The root and device fixtures exercise path-based scalar replacement, insertion, deletion, object reorder, table creation, array-of-table append, array-index replacement, inline-table edits, dotted-key edits, multiline strings, unknown fields, full-line and trailing comments, malformed input, and both LF and CRLF source. The suite validates every successful result with a semantic decode and uses an LCS over complete source lines to compare every line outside an operation-specific allowed edit region byte-for-byte. For array-element, inline-table, and trailing-comment scalar edits, the target line must equal the original line with exactly one value token replaced; adjacent whitespace, delimiters, sibling fields, and comments cannot be admitted through the broader line allowance. These minimal-line checks run for both LF and CRLF. Sentinel entries in the artifact are explicitly labeled `comparison: marker-count` and only check marker presence/count; exact untouched bytes are represented by `comparison: exact-line` or `comparison: lcs-unmodified-lines`.

The write checks cover SHA-256 stale-write refusal and same-directory temporary-file replacement followed by rename. They verify that a stale writer cannot overwrite newer bytes and that an atomic replacement leaves no temporary file behind. An injected post-hash editor write demonstrates the unavoidable TOCTOU boundary: the hash check rejects changes already present when it reads the file, but this writer does not provide a filesystem compare-and-swap against a write occurring between that read and the rename.

If a required TOML case fails, the suite marks `jsonc_mode` as `fallback-required` and runs the equivalent JSONC behavior. The suite currently runs that JSONC path as a comparison baseline even when TOML passes, so the fallback remains exercised. Dotted TOML keys, inline tables, and multiline strings are represented by nested JSON objects or escaped JSON strings in the equivalent JSONC fixture.

## Latest measured result

The checked-in artifact was generated with `CGO_ENABLED=0 go test -count=1 ./...` on the pinned dependencies above:

| Format/check | Result |
|---|---:|
| TOML required cases (17 cases × LF/CRLF) | 34 pass, 0 fail |
| JSONC comparison (malformed-input rejection included) | 2 pass, 32 fail |
| exact minimal-line checks (array/inline/comment cases) | 8 pass, 0 fail |
| stale-write refusal | pass |
| post-hash TOCTOU boundary demonstration | pass (limitation documented) |
| same-directory atomic replacement | pass |
| deterministic artifact regeneration | pass |

The JSONC failures are preservation failures: HuJSON patching removed the trailing comma from an untouched last object member in these fixtures, so the whole untouched line was not byte-identical. This is a measured result for this patch/fixture combination, not a general claim that HuJSON cannot preserve other layouts.

## Claims versus measurements

go-toml's `unstable/edit` documentation claims that `Parse`, `Set`, and `Delete` rewrite only bytes expressing an edit while retaining comments, whitespace, and ordering. This suite measures that claim against the committed root/device fixtures, both newline styles, and the listed operations; it does not prove behavior for all TOML syntax.

HuJSON documents `Pack` as byte-preserving for an unmodified AST and `Patch` as RFC 6902 mutation, recommending `Format` after patching. This suite deliberately measures `Patch` followed by `Pack` without `Format`, because formatting the entire document would not meet the lossless-edit requirement.

No stable schema, production writer, or final TOML-versus-JSONC decision is introduced here. The owner decision remains gated by the S-02 report.
