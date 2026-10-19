# Vendored TOML engine

`Sources/HidhoggCore/Toml` is derived from
[`akira-toriyama/swift-toml-edit` tag `v3.0.0`](https://github.com/akira-toriyama/swift-toml-edit/tree/v3.0.0),
commit [`603c402868e1fb5c4348d130f16e73b401f531f8`](https://github.com/akira-toriyama/swift-toml-edit/commit/603c402868e1fb5c4348d130f16e73b401f531f8).
The upstream project is MIT-licensed; its license is retained in
`THIRD_PARTY_LICENSES/swift-toml-edit.txt`.

The vendored surface contains the source-preserving `Annotated` DOM and the
strict typed-tree decoder. Lossy parser projections and editing operations are
not included. The existing strict engine is extended locally for TOML 1.1 and
for exact UTF-8 key identity and parser-backed source locations. Hidhogg's
configuration layer applies the v4 schema and projects safe diagnostics with
complete field paths. Upstream source comments are preserved with the
implementation.

The package has no external SwiftPM dependencies. Its independent corrected-
source unit suite passed 30/30 on 2026-10-02. The official TOML 1.1 corpus
passed 214 valid and 467 invalid cases, with zero failures or skips, using
[`toml-test` v2.2.0](https://github.com/toml-lang/toml-test/commit/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c).
The seven vendored parser source files matched the final frozen-source hash
manifest. The test log is
`/Volumes/Data/tmp/hidhogg-v2-c01-verification/toml-test-v2.2.0-1.1-final.log`.
The temporary runner change removed its explicit `NO_COLOR` lookup and
disabled color by default without changing TOML test selection or comparison.
