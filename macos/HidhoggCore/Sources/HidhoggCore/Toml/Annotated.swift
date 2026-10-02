// Toml.Annotated — the lossless, format-preserving DOM.
//
// This is the value-add over sill's lossy `Toml` (which keeps only parsed
// values). `Annotated` preserves EVERY byte: comments, blank lines, ordering,
// indentation, quoting style, number spelling and the `#:schema` pragma. The
// invariant, checked in CI, is byte-identical round-trip:
//
//     try Toml.Annotated(parsing: s).render() == s        // for any document we parse
//
// It guarantees this the way toml_edit / tomlkit do: every node stores its
// exact source spelling (`raw`) plus the verbatim trivia (comments + blank
// lines) attached to it, and rendering concatenates those spans. An UNEDITED
// node always re-emits its original bytes; only an edited block re-renders,
// so neighbours stay byte-stable.
//
// Node types are nested under `Annotated` (`Toml.Annotated.Block` / `.Body` /
// `.Entry`) so they do NOT collide with the lossy projection's `Toml.Value` /
// `Toml.Document`, which keep their sill names for the consumer swap.
//
// Trivia attribution (the wand#129 rule): a run of comments / blank lines
// attaches to the header (or key) block that immediately FOLLOWS it — so it
// travels with that block on reorder / delete. The bytes before the very
// first content token (the `#:schema` pragma + file header) are document-level
// `leading` and never move.
//
// Scope: the parser tiles every construct losslessly for round-trip — std
// tables (incl. dotted / quoted-key / numeric-segment headers), arrays-of-
// tables, single-line inline tables, single- and multi-line arrays, and
// single- AND multi-line basic / literal strings (`"""`/`'''`, M2 step 1).
// Values are kept as raw spelling; a typed decode is available on demand via
// `Entry.value`. The remaining M2 work is on the strict typed DECODE layer
// (full datetimes, octal / binary, float specials, the redefinition state
// machine, invalid-value rejection) and per-element editing — additive, since
// it reads the raw spelling without touching this byte-preserving contract.

import Foundation

public extension Toml {

    /// A lossless, round-trippable TOML document. Value type (Sendable),
    /// so edits return a NEW document (`reorderingArrayOfTables` / `removing`).
    struct Annotated: Sendable, Equatable {
        /// Document-level leading trivia: every byte before the first content
        /// token (e.g. the `#:schema` pragma + file header comments + the BOM
        /// if any). Never moves on edit.
        public var leading: String
        /// Top-level key/values that precede the first `[header]` (the
        /// implicit root table).
        public var root: Body
        /// The `[std-table]` / `[[array-table]]` blocks, in document order.
        public var blocks: [Block]

        public init(leading: String = "", root: Body = .init(), blocks: [Block] = []) {
            self.leading = leading
            self.root = root
            self.blocks = blocks
        }
    }
}

public extension Toml.Annotated {

    /// The key/values under one scope (the root, a `[table]`, or a `[[aot]]`
    /// element), in document order, plus any trivia trailing the last entry.
    struct Body: Sendable, Equatable {
        public var entries: [Entry] = []
        /// Trivia after the last entry, before the next header or EOF. Only
        /// the document's final body ever carries a non-empty `trailing`
        /// (trivia mid-document is always the leading of the following node).
        public var trailing: String = ""

        public init(entries: [Entry] = [], trailing: String = "") {
            self.entries = entries
            self.trailing = trailing
        }

        /// First entry whose key matches `key`, or nil. `key` is interpreted as
        /// dotted-key SOURCE syntax — `a.b` is the two-segment path `["a","b"]`,
        /// so a key literally NAMED `a.b` must be quoted (`"a.b"`) or looked up
        /// via `entry(forKeyParts:)`. Quoting style of bare segments does not
        /// matter (`"x"` and `x` both resolve to `["x"]`).
        public func entry(forKey key: String) -> Entry? {
            guard let path = try? Toml.lexDottedPathStrict(key, line: 0) else { return nil }
            return entry(forKeyParts: path)
        }

        /// First entry whose parsed key parts equal `parts`, or nil. Use this
        /// to look up a key whose name contains a literal dot (pass
        /// `["a.b"]`), or to reuse an `Entry.key` directly without re-quoting.
        public func entry(forKeyParts parts: [String]) -> Entry? {
            entries.first { $0.key == parts }
        }
    }

    /// One `key = value` assignment. The value may span physical lines (a
    /// multi-line array); `raw` then covers all of them.
    struct Entry: Sendable, Equatable {
        /// Comments / blank lines immediately before this entry (a banner) —
        /// moves and deletes with it.
        public var leading: String
        /// The exact source of the assignment, including any same-line inline
        /// comment and the trailing newline. Round-trip emits this verbatim.
        public var raw: String
        /// The parsed dotted key, unquoted (`"q.k" = …` → `["q.k"]`,
        /// `a.b = …` → `["a","b"]`). For lookup / navigation.
        public var key: [String]
        /// The value portion's source spelling, comment-stripped and trimmed
        /// (e.g. `"neon"`, `6000`, `["a", "b"]`).
        public var valueText: String
        public var line: Int
        public var column: Int
        public var valueColumn: Int
        var keySourceRange: SourceByteRange? = nil
        var valueSourceRange: SourceByteRange? = nil
        var valueSourceByteOffsets: [Int] = []

        public init(leading: String, raw: String, key: [String], valueText: String,
                    line: Int = 0, column: Int = 0, valueColumn: Int = 0) {
            self.leading = leading
            self.raw = raw
            self.key = key
            self.valueText = valueText
            self.line = line
            self.column = column
            self.valueColumn = valueColumn
        }
    }

    /// A `[std-table]` header block or one `[[array-table]]` element block,
    /// with the key/values that follow it.
    struct Block: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case table          // `[header]`
            case arrayElement   // `[[header]]` — one element of an array-of-tables
        }
        /// Banner comments / blank lines before the header line — moves and
        /// deletes with the block (the wand#129 rule).
        public var leading: String
        public var kind: Kind
        /// The exact header line, including any same-line inline comment and
        /// the trailing newline (e.g. `"[cast.overlay.trail]\n"`).
        public var headerRaw: String
        /// The parsed dotted header path, unquoted (`[behavior."com.apple.x"]`
        /// → `["behavior","com.apple.x"]`). Identifies an array-of-tables.
        public var path: [String]
        public var body: Body
        public var line: Int
        public var column: Int
        var keyColumn: Int = 0

        public init(leading: String, kind: Kind, headerRaw: String,
                    path: [String], body: Body, line: Int = 0, column: Int = 0) {
            self.leading = leading
            self.kind = kind
            self.headerRaw = headerRaw
            self.path = path
            self.body = body
            self.line = line
            self.column = column
        }
    }
}

// MARK: - Render (serialize)

public extension Toml.Annotated {
    /// Serialize back to TOML. Byte-identical to the parsed source for an
    /// unedited document; an edited block re-renders while its neighbours
    /// keep their verbatim bytes.
    func render() -> String {
        var out = leading
        out += root.render()
        for block in blocks { out += block.render() }
        return out
    }
}

extension Toml.Annotated.Body {
    func render() -> String {
        var out = ""
        for entry in entries {
            out += entry.leading
            out += entry.raw
        }
        out += trailing
        return out
    }
}

extension Toml.Annotated.Block {
    func render() -> String {
        leading + headerRaw + body.render()
    }
}
