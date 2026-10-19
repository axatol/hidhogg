# Compact configuration v4

Status: implemented; offline Go/Swift gates and independent review pass, owner physical acceptance pending
Updated: 2026-10-01

Profiles use stable keys. Tiles use physical `column_row` keys. The source may omit blank tiles; Go still builds a complete ordered 14-tile page.

```toml
#:schema ../schema/hidhogg-d200x-v4.json
schema_version = 4
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "default"

[profiles.default]
label = "Default"

[profiles.default.positions]
0_0 = { label = "1", action = { type = "type_text", text = "1", gesture = "press" } }
1_0 = { label = "2" }
2_0 = {}

[profiles.default.positions.3_2]
label = "Enter"
label_alignment = "center"
label_size = 32

[profiles.default.positions.3_2.action]
type = "key_press"
key = "enter"
gesture = "press"
```

Do not define the same tile using both inline and expanded forms. An inline table is self-contained; keep its action inside it, or use an expanded tile/action table instead.

## Defaults and strictness

| Omitted source value | Effective value |
|---|---|
| Tile | Blank, black, no action or notification subscription |
| Tile `label` | `""` |
| Tile `background` | `"#000000"` |
| Tile `label_alignment` | `"bottom"` |
| Tile `label_size` | `10` |
| Action `gesture` | `"release"` |
| Execute `arguments` | `[]` |
| Execute `timeout_seconds` | `10` |
| Root `idle_timeout_seconds` | `300`; explicit `0` disables the application dimmer |

Root schema/adapter/brightness/default-profile/profiles and each profile's visible display label remain required. Profile labels cannot be blank. An empty tile label is valid even if it has an action; a missing tile has no action. Explicit whitespace-only labels, invalid types, unsupported fields/coordinates, invalid action variants, and unresolved profile references are rejected rather than defaulted.

```text
         column →
row 0    0_0  1_0  2_0  3_0  4_0
row 1    0_1  1_1  2_1  3_1  4_1
row 2    0_2  1_2  2_2  [  3_2  ]
```

`4_2` is not a separate tile. Profile order is default first, then remaining profile keys lexicographically. Tile order is fixed physical/wire order, irrespective of TOML declaration order.

Profile keys remain case-sensitive immutable identities for app mappings and activation actions. Edit the profile's `label` to rename its menu display. IDs containing dots must be quoted as one key, for example `[profiles."work.dev".positions.0_0]`.

Profile cloning appends a canonical sparse keyed block without copying source comments. If the entire root `profiles` value is inline, the clone is inserted losslessly into that inline table instead: TOML forbids extending a closed inline table with a later header. Unrelated source bytes remain unchanged in either form.

## Explicit migration from v3

There is no automatic compatibility/migration path. Keep an exact backup before editing an existing file. The original implementation left selected user files unchanged. A separate owner-authorized one-time conversion on 2026-10-01 subsequently migrated the selected file; no migration command or predecessor-format support ships in the app.

| v3 source | v4 source |
|---|---|
| `schema_version = 3` | `schema_version = 4` |
| `[[profiles]]` followed by `id = "work"` | `[profiles.work]`; remove `id` |
| `[[profiles.positions]]` with `position = "0_0"` | `[profiles.work.positions.0_0]`; remove tile `id` and `position` |
| `[profiles.positions.action]` | `[profiles.work.positions.0_0.action]` |
| v3 lint-schema annotation | `schema/hidhogg-d200x-v4.json` at the appropriate relative path |

Keep labels, colours, styles, subscriptions and action fields unchanged during conversion. Tile IDs exposed in runtime/editor/history now use coordinates; profile IDs and their references are unchanged. Blank-only tile blocks can then be omitted, and simple tiles can optionally be written inline.

An unconverted selected v3 file is deliberately preserved by Swift bootstrap and will be rejected by the rebuilt v4 runtime until explicitly converted. Do not replace it with the minimal template if preserving existing profiles/actions is required.

## Owner verification after offline gates

The selected-file conversion passed strict v4 decoding, permitted semantic-tree comparison and exact generated-candidate byte comparison, preserving two profiles, 28 tiles, 14 actions and comments. The exact v3 backup remains beside the selected file as `config.toml.v3-backup-20261001T070139Z`; both files retain mode 0600. The disposable converter passed independent focused tests/race/vet and was removed afterward. No app restart or device command was performed for migration.

Use the backed-up, converted configuration. Rebuild and run the Hidhogg target in Xcode, verify Ready, switch profiles, clear one tile label, restore it, and clone/rename/delete only a temporary profile. Confirm omitted tiles clear old displayed content and the wide label still renders. A deliberately invalid supplied field should be rejected with a key diagnostic while the last-known-good live profile remains; restore valid source afterward. Agent-run device tests are excluded.
