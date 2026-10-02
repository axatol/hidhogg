// Build a fully-typed, nested value tree from the lossless `Annotated` DOM (the
// toml-test decoder path) AND enforce the TOML 1.1 table/key REDEFINITION state
// machine. The lossless tiler is concerned only with structure + byte-faithful
// round-trip; "is this a duplicate table / a header reopening a dotted-key
// table / an array-over-table clash" is a SEMANTIC check that lives here.
//
// Each table node records HOW it was created, which decides what may later
// touch it:
//   • implicit — an intermediate super-table of `[a.b.c]` or a dotted key.
//     OPEN: may gain sub-tables/keys and may be promoted to an explicit table
//     exactly once.
//   • header   — defined by a `[header]`. Open to deeper headers and to keys in
//     its body, but a second identical `[header]` is an error.
//   • dotted   — created by the non-final part of a dotted key. Open to more
//     sibling dotted keys, but CLOSED to a later `[header]` (a dotted-key table
//     cannot be reopened).
//   • inline   — an inline table `{…}`. CLOSED to every later addition.
// Arrays-of-tables are a list of element tables; only the LAST element is open.
//
// The same machine backs inline tables (so `{a.b=1, a.b.c=2}` and `{b=1, b.c=2}`
// are rejected) — `decodeStrict`'s inline-table parser builds a `TreeTable` too.

public extension Toml.Annotated {
    /// Fold this document into a typed `.table` value, decoding each leaf
    /// strictly and enforcing the redefinition rules. Throws on any malformed
    /// value OR illegal redefinition.
    func typedTree() throws -> Toml.TypedValue {
        try typedTreeWithLocations().value
    }

    internal func typedTreeWithLocations() throws -> Toml.LocatedTree {
        let tree = Toml.TreeTable(kind: .implicit)
        var keyLocations: [ExactTomlPath: Toml.SourceLocation] = [:]
        var valueLocations: [ExactTomlPath: Toml.SourceLocation] = [:]
        var keySpans: [ExactTomlPath: SourceByteRange] = [:]
        var valueSpans: [ExactTomlPath: SourceByteRange] = [:]
        var inlineTables: [ExactTomlPath: InlineTableSource] = [:]
        var headerPaths: Set<ExactTomlPath> = []
        var dottedPaths: Set<ExactTomlPath> = []
        try tree.addKeys(self.root.entries, under: [], keyLocations: &keyLocations,
                         valueLocations: &valueLocations, keySpans: &keySpans,
                         valueSpans: &valueSpans, inlineTables: &inlineTables,
                         dottedPaths: &dottedPaths)
        for block in blocks {
            if block.line > 0, block.keyColumn > 0, !block.path.isEmpty {
                let location = Toml.SourceLocation(line: block.line, column: block.keyColumn)
                headerPaths.insert(ExactTomlPath(block.path))
                for length in 1...block.path.count {
                    let path = Array(block.path.prefix(length))
                    let exactPath = ExactTomlPath(path)
                    if keyLocations[exactPath] == nil { keyLocations[exactPath] = location }
                    if valueLocations[exactPath] == nil { valueLocations[exactPath] = location }
                }
            }
            switch block.kind {
            case .table:
                let t = try tree.defineHeader(block.path, line: block.line, column: block.column)
                try t.addKeys(block.body.entries, under: block.path, keyLocations: &keyLocations,
                              valueLocations: &valueLocations, keySpans: &keySpans,
                              valueSpans: &valueSpans, inlineTables: &inlineTables,
                              dottedPaths: &dottedPaths)
            case .arrayElement:
                let t = try tree.defineArrayElement(block.path, line: block.line, column: block.column)
                try t.addKeys(block.body.entries, under: block.path, keyLocations: &keyLocations,
                              valueLocations: &valueLocations, keySpans: &keySpans,
                              valueSpans: &valueSpans, inlineTables: &inlineTables,
                              dottedPaths: &dottedPaths)
            }
        }
        return Toml.LocatedTree(value: tree.toTyped(), keyLocations: keyLocations,
                                valueLocations: valueLocations, keySpans: keySpans,
                                valueSpans: valueSpans, inlineTables: inlineTables,
                                headerPaths: headerPaths,
                                dottedPaths: dottedPaths)
    }
}

extension Toml.TreeTable {
    /// Decode + insert a body's `key = value` entries (dotted keys included).
    func addKeys(
        _ entries: [Toml.Annotated.Entry],
        under prefix: [String],
        keyLocations: inout [ExactTomlPath: Toml.SourceLocation],
        valueLocations: inout [ExactTomlPath: Toml.SourceLocation],
        keySpans: inout [ExactTomlPath: SourceByteRange],
        valueSpans: inout [ExactTomlPath: SourceByteRange],
        inlineTables: inout [ExactTomlPath: InlineTableSource],
        dottedPaths: inout Set<ExactTomlPath>
    ) throws {
        for e in entries {
            let entryPath = prefix + e.key
            let decoded = try Toml.decodeStrictLocated(
                e.valueText, line: e.line, column: e.valueColumn, path: entryPath,
                sourceByteOffsets: e.valueSourceByteOffsets.isEmpty ? nil : e.valueSourceByteOffsets
            )
            let keySource = Toml.SourceLocation(line: e.line, column: e.column)
            let valueSource = Toml.SourceLocation(line: e.line, column: e.valueColumn)
            if e.key.count > 1 {
                dottedPaths.insert(ExactTomlPath(entryPath))
                for length in (prefix.count + 1)..<entryPath.count {
                    let path = ExactTomlPath(Array(entryPath.prefix(length)))
                    if keyLocations[path] == nil { keyLocations[path] = keySource }
                    if valueLocations[path] == nil { valueLocations[path] = keySource }
                }
            }
            let exactPath = ExactTomlPath(entryPath)
            if let keySpan = e.keySourceRange, keySpans[exactPath] == nil { keySpans[exactPath] = keySpan }
            if let valueSpan = e.valueSourceRange, valueSpans[exactPath] == nil { valueSpans[exactPath] = valueSpan }
            if e.line > 0, e.column > 0, keyLocations[exactPath] == nil { keyLocations[exactPath] = keySource }
            if e.line > 0, e.valueColumn > 0, valueLocations[exactPath] == nil { valueLocations[exactPath] = valueSource }
            keyLocations.merge(decoded.keyLocations) { _, nested in nested }
            valueLocations.merge(decoded.valueLocations) { _, nested in nested }
            keySpans.merge(decoded.keySpans) { _, nested in nested }
            valueSpans.merge(decoded.valueSpans) { _, nested in nested }
            inlineTables.merge(decoded.inlineTables) { _, nested in nested }
            dottedPaths.formUnion(decoded.dottedPaths)
            try setKey(e.key, decoded.value, line: e.line, column: e.column)
        }
    }
}

extension Toml {
    /// A mutable build node for the typed tree + redefinition machine.
    final class TreeTable {
        enum Kind { case implicit, header, dotted, inline }
        enum Child { case leaf(TypedValue); case table(TreeTable); case aot([TreeTable]) }

        var kind: Kind
        private(set) var order: [ExactTomlKey] = []
        private(set) var children: [ExactTomlKey: Child] = [:]

        init(kind: Kind) { self.kind = kind }

        private func put(_ k: String, _ c: Child) {
            let key = ExactTomlKey(k)
            if children[key] == nil { order.append(key) }
            children[key] = c
        }
        func get(_ k: String) -> Child? { children[ExactTomlKey(k)] }

        private func fail(_ m: String, line: Int, column: Int) -> Toml.ParseError {
            Toml.ParseError(line: line, column: column, message: m)
        }

        // MARK: headers

        /// Define `[path]`, returning the target table to fill with the body.
        func defineHeader(_ path: [String], line: Int, column: Int) throws -> TreeTable {
            let parent = try descend(Array(path.dropLast()), line: line, column: column)
            guard let last = path.last else { throw fail("empty table header", line: line, column: column) }
            switch parent.get(last) {
            case nil:
                let t = TreeTable(kind: .header); parent.put(last, .table(t)); return t
            case .table(let t):
                switch t.kind {
                case .implicit: t.kind = .header; return t          // implicit → explicit (once)
                case .header:   throw fail("table '\(last)' defined more than once", line: line, column: column)
                case .dotted:   throw fail("cannot redefine dotted-key table '\(last)' with a header", line: line, column: column)
                case .inline:   throw fail("cannot extend inline table '\(last)'", line: line, column: column)
                }
            case .aot:  throw fail("'\(last)' is already an array of tables", line: line, column: column)
            case .leaf: throw fail("key '\(last)' is not a table", line: line, column: column)
            }
        }

        /// Append a new `[[path]]` element, returning it (to fill with the body).
        func defineArrayElement(_ path: [String], line: Int, column: Int) throws -> TreeTable {
            let parent = try descend(Array(path.dropLast()), line: line, column: column)
            guard let last = path.last else { throw fail("empty array header", line: line, column: column) }
            let element = TreeTable(kind: .header)
            switch parent.get(last) {
            case nil:            parent.put(last, .aot([element]))
            case .aot(var arr):  arr.append(element); parent.put(last, .aot(arr))
            case .table:         throw fail("'\(last)' is already a table, not an array of tables", line: line, column: column)
            case .leaf:          throw fail("key '\(last)' is not an array of tables", line: line, column: column)
            }
            return element
        }

        /// Descend the non-final parts of a HEADER path, creating implicit
        /// super-tables and stepping into the last element of any AoT. A leaf or
        /// an inline table in the way is an error.
        private func descend(_ path: [String], line: Int, column: Int) throws -> TreeTable {
            var cur = self
            for seg in path {
                switch cur.get(seg) {
                case nil:
                    let t = TreeTable(kind: .implicit); cur.put(seg, .table(t)); cur = t
                case .table(let t):
                    if t.kind == .inline { throw fail("cannot extend inline table '\(seg)'", line: line, column: column) }
                    cur = t
                case .aot(let arr):
                    guard let last = arr.last else { throw fail("empty array of tables '\(seg)'", line: line, column: column) }
                    cur = last
                case .leaf:
                    throw fail("key '\(seg)' is not a table", line: line, column: column)
                }
            }
            return cur
        }

        // MARK: keys (plain + dotted), shared by the document and inline tables

        /// Set a (possibly dotted) key to a decoded value, enforcing the
        /// duplicate / closed-table rules. Intermediate tables a dotted key
        /// creates are `dotted` (closed to later headers).
        func setKey(_ path: [String], _ value: TypedValue, line: Int, column: Int) throws {
            guard let head = path.first else { return }
            if path.count == 1 {
                if get(head) != nil { throw fail("duplicate key '\(head)'", line: line, column: column) }
                put(head, .leaf(value))
                return
            }
            let tail = Array(path.dropFirst())
            let sub: TreeTable
            switch get(head) {
            case nil:
                sub = TreeTable(kind: .dotted); put(head, .table(sub))
            case .table(let t):
                // A dotted key may extend a table created by a sibling dotted
                // key (`.dotted`) OR an implicit super-table (`.implicit`, e.g.
                // adding `b.a` under the implicit `b` of a prior `[a.b.c]`). It
                // may NOT reach into a table explicitly defined by a `[header]`
                // (`[a.b.c]` then `[a]` then `b.c.t = …` is invalid) nor into an
                // inline table.
                switch t.kind {
                case .dotted: sub = t
                case .implicit:
                    // Extending an implicit super-table with a dotted key
                    // DEFINES it, sealing it against a later `[header]` on the
                    // same path: `[a.b.c]` / `[a]` / `b.x = 1` / `[a.b]` is a
                    // duplicate-table redefinition (rejected by the reference
                    // decoders). Promote implicit → dotted — still open to more
                    // sibling dotted keys and to DEEPER headers (`[a.b.d]`
                    // descends through it), but an exact-path `[a.b]` now hits
                    // the `.dotted` case in `defineHeader` and is rejected.
                    t.kind = .dotted; sub = t
                case .inline: throw fail("cannot extend inline table '\(head)'", line: line, column: column)
                case .header:
                    throw fail("cannot extend table '\(head)' with a dotted key", line: line, column: column)
                }
            case .aot:  throw fail("cannot extend array of tables '\(head)' with a dotted key", line: line, column: column)
            case .leaf: throw fail("key '\(head)' is not a table", line: line, column: column)
            }
            try sub.setKey(tail, value, line: line, column: column)
        }

        // MARK: lower into the public typed value

        func toTyped() -> TypedValue {
            var out: [(key: String, value: TypedValue)] = []
            for k in order {
                switch children[k]! {
                case .leaf(let v):  out.append((k.value, v))
                case .table(let t): out.append((k.value, t.toTyped()))
                case .aot(let arr): out.append((k.value, .array(arr.map { $0.toTyped() })))
                }
            }
            return .table(out)
        }
    }
}
