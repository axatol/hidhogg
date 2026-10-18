# M-10-F01 — Compact schema v4

Status: implemented and independently verified offline; selected-file migration complete, owner device acceptance pending
Updated: 2026-10-01

Historical milestone record. Its Go implementation details and owner-device status reflect the 2026-10-01 checkpoint; V2-V01 later accepted the Swift implementation using simulated D200X. See [v2-plan.md](v2-plan.md) for current architecture and limits.

## Confirmed contract

The goal is compact, readable configuration with strict validation. Schema v4 is the sole accepted production format; predecessor versions are rejected, not silently migrated. Offline implementation does not automatically change user-selected configuration files. A separately owner-authorized one-time selected-file conversion was completed on 2026-10-01; no compatibility path ships.

- `profiles` is keyed by immutable, case-sensitive profile ID. Existing profile display labels remain required and editable; profile keys are not display labels.
- Each profile's `positions` table is keyed by a supported `column_row` coordinate. Separate tile `id` and `position` fields are removed from the source. Coordinates become canonical tile IDs in normalized runtime/editor/history values.
- Inline and expanded tile tables have identical semantics. Supported coordinates remain the 14 D200X positions, including wide `3_2`; `4_2` is invalid.
- Omitted positions, omitted tiles and `{}` tiles normalize to blank text, black background, no action and no notification sources. An explicit empty label is valid and may coexist with a configured action. Whitespace/control-only labels and other invalid explicitly supplied fields remain rejected.
- Tile `label` defaults to `""`; `background` defaults to `"#000000"`. Existing alignment, size, gesture, execution-timeout and application-idle defaults remain unchanged. No inheritance, implicit profile fallback or invalid-value coercion is added.
- Normalize to the existing complete 14-position runtime layout in wire order. Profile catalog order is default first, then remaining IDs lexicographically. Source declaration order and map iteration order do not cause semantic changes.
- Required global fields, profile-count limits, profile display-label rules, action variants, reference checks, notification-source rules and diagnostic disclosure boundaries remain strict.
- Generated JSON Schema represents keyed source data and rejects unsupported coordinate/field names. Exact-digest lossless edits retain unrelated bytes/comments, including inline syntax, omitted label insertion and keyed profile clone/delete. Clone output is canonical semantic source appended last; blank/default-only positions may be omitted. A wholly inline root `profiles` value instead receives a lossless inline insertion because TOML cannot extend a closed inline table with a later header.

## Implementation boundaries

- Config executor: keyed source decoding/projection/schema, config fixtures/tests and blank-label support in the neutral profile model. Preserve the public normalized `Config`/catalog consumer shape where practical.
- Editor executor: keyed lossless profile/position edits and preservation fixtures/tests; coordinate identity, absent-tile insertion and semantic clone/delete.
- Main: cross-package fixture migration, Swift request/UI blank-label support and bootstrap, D200X blank rendering, integration, durable documents and tracking.
- Explorer: bounded read-only audit of test helpers, renderer/Swift assumptions and migration requirements.

The original offline implementation excluded dependency upgrades, broad refactors, live integration tests, app/device launches, selected configuration reads/edits and protected environment files. The later migration grant covered only the resolved selected TOML and its exact backup; other exclusions remain.

## Gates and checklist

- [x] Keyed source strict/default validation and deterministic normalized/source projection.
- [x] Blank tiles pass neutral profile and D200X page/render validation and clear previous content in generated full-page data.
- [x] Inline/expanded/sparse lossless edit, clone/delete, quoted keys and stale-digest regressions.
- [x] Go full uncached tests and race suite, vet, command build, module verification and generated-schema comparison.
- [x] Final Swift offline tests/build: 129/129 pass with hardware-touching `LiveIntegrationTests` excluded in the test-host configuration. The corrected client fixture separately passes 1/1; final broad run uses a 30-second per-test bound.
- [x] Independent review and corrections within three cycles: canonical editor IPC coordinate checks and a missed Swift client fixture were corrected; final reviews find no remaining blocker.
- [x] Durable handoff and concise owner migration/verification instructions in [the v4 guide](compact-config-v4.md).
- [x] Separate owner-authorized selected-file conversion with exact backup; strict v4 decode, semantic comparison and exact candidate-byte comparison pass on 2026-10-01. Disposable converter tests/race/vet pass independently; no compatibility tool ships.
- [ ] Owner verifies live v4 blank clearing, profile switching and editing after rebuilding/running Hidhogg in Xcode. No agent-run app/device test is authorized.

The two cancelled post-correction Swift attempts are not passing evidence. They exposed the remaining client fixture with legacy IDs; after migration, focused and full offline reruns pass. The precise stall mechanism was not established.
