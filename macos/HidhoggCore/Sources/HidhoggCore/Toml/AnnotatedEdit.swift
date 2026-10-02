import Foundation

struct TomlSourceMutation {
    private var bytes: [UInt8]

    init(_ source: Data) throws {
        guard String(data: source, encoding: .utf8) != nil else { throw TomlSourceMutationError.invalidSource }
        bytes = Array(source)
        _ = try snapshot()
    }

    var data: Data { Data(bytes) }

    func value(at path: [String]) throws -> Toml.TypedValue? {
        let tree = try snapshot().tree.value
        var current = tree
        for component in path {
            guard case .table(let entries) = current,
                  let entry = entries.first(where: { ExactTomlKey($0.key) == ExactTomlKey(component) }) else {
                return nil
            }
            current = entry.value
        }
        return current
    }

    func containsValue(at path: [String]) throws -> Bool {
        let tree = try snapshot().tree
        let exactPath = ExactTomlPath(path)
        return tree.valueSpans[exactPath] != nil
            || tree.inlineTables[exactPath] != nil
            || tree.headerPaths.contains(exactPath)
            || tree.valueSpans.keys.contains { $0.hasPrefix(path) }
            || tree.inlineTables.keys.contains { $0.hasPrefix(path) }
    }

    func hasInlineTable(at path: [String]) throws -> Bool {
        try snapshot().tree.inlineTables[ExactTomlPath(path)] != nil
    }

    mutating func appendBlock(_ block: String) {
        if !bytes.isEmpty {
            let hasTwoLineEndings = bytes.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A])
                || bytes.suffix(2).elementsEqual([0x0A, 0x0A])
            if !hasTwoLineEndings {
                if bytes.last == 0x0A {
                    bytes.append(contentsOf: lineEnding.utf8)
                } else {
                    bytes.append(contentsOf: lineEnding.utf8)
                    bytes.append(contentsOf: lineEnding.utf8)
                }
            }
        }
        bytes.append(contentsOf: block.utf8)
    }

    mutating func set(_ path: [String], value: String) throws {
        guard !path.isEmpty else { throw TomlSourceMutationError.invalidPath }
        let state = try snapshot()
        let exactPath = ExactTomlPath(path)
        if let span = state.tree.valueSpans[exactPath] {
            try replace(span, with: value)
            return
        }

        let parent = Array(path.dropLast())
        if let table = state.tree.inlineTables
            .filter({ exactPath.hasPrefix($0.key.values) })
            .max(by: { $0.key.count < $1.key.count }) {
            let remaining = Array(path.dropFirst(table.key.count))
            let first = ExactTomlKey(remaining[0])
            let existingTopLevel = table.value.entries.contains { entry in
                let relativeEntry = Array(entry.path.values.dropFirst(table.key.count))
                return relativeEntry.first.map { ExactTomlKey($0) == first } ?? false
            }
            if existingTopLevel {
                try insert(value, keyPath: remaining, into: table.value)
            } else {
                let nested = remaining.count == 1
                    ? value
                    : nestedInlineTable(Array(remaining.dropFirst()), value: value)
                try insert(nested, keyPath: [remaining[0]], into: table.value)
            }
            return
        }

        var document = state.document
        let blockIndex = document.blocks.indices
            .filter { ExactTomlPath(document.blocks[$0].path).values.count <= parent.count &&
                ExactTomlPath(parent).hasPrefix(document.blocks[$0].path) }
            .max { document.blocks[$0].path.count < document.blocks[$1].path.count }
        let basePath = blockIndex.map { document.blocks[$0].path } ?? []
        let relativePath = Array(path.dropFirst(basePath.count))
        guard !relativePath.isEmpty else { throw TomlSourceMutationError.invalidPath }
        var entry = Toml.Annotated.Entry(
            leading: "",
            raw: encodedKeyPath(relativePath) + " = " + value + lineEnding + "",
            key: relativePath,
            valueText: value
        )
        if let blockIndex {
            var block = document.blocks[blockIndex]
            if let last = block.body.entries.last, !hasLineEnding(last.raw) {
                entry.leading = lineEnding
            } else if block.body.entries.isEmpty, !hasLineEnding(block.headerRaw) {
                entry.leading = lineEnding
            }
            block.body.entries.append(entry)
            document.blocks[blockIndex] = block
        } else {
            if let last = document.root.entries.last, !hasLineEnding(last.raw) {
                entry.leading = lineEnding
            }
            document.root.entries.append(entry)
        }
        bytes = Array(document.render().utf8)
    }

    mutating func delete(_ path: [String]) throws {
        guard !path.isEmpty else { throw TomlSourceMutationError.invalidPath }
        let state = try snapshot()
        let exactPath = ExactTomlPath(path)
        if try deleteInlineEntry(exactPath) {
            return
        }

        var document = state.document
        let prefix = ExactTomlPath(path)
        var removed = false
        removed = removeEntries(&document.root.entries, under: [], prefix: prefix) || removed
        for index in document.blocks.indices {
            removed = removeEntries(&document.blocks[index].body.entries,
                                   under: document.blocks[index].path,
                                   prefix: prefix) || removed
        }
        let priorCount = document.blocks.count
        document.blocks.removeAll { ExactTomlPath($0.path).hasPrefix(path) }
        removed = removed || document.blocks.count != priorCount
        guard removed else { throw TomlSourceMutationError.pathNotFound }
        bytes = Array(document.render().utf8)
    }

    mutating func deleteSubtree(_ path: [String]) throws {
        guard !path.isEmpty else { throw TomlSourceMutationError.invalidPath }
        let prefix = ExactTomlPath(path)
        if try deleteInlineEntry(prefix) {
            return
        }

        var removedInlineEntries = false
        while try deleteInlineDescendant(prefix) { removedInlineEntries = true }

        let state = try snapshot()
        var document = state.document
        var removed = removedInlineEntries
        removed = removeEntries(&document.root.entries, under: [], prefix: prefix) || removed
        for index in document.blocks.indices {
            removed = removeEntries(&document.blocks[index].body.entries,
                                   under: document.blocks[index].path,
                                   prefix: prefix) || removed
        }
        let priorCount = document.blocks.count
        document.blocks.removeAll { ExactTomlPath($0.path).hasPrefix(path) }
        removed = removed || document.blocks.count != priorCount
        guard removed else { throw TomlSourceMutationError.pathNotFound }
        bytes = Array(document.render().utf8)
    }

    private func snapshot() throws -> (document: Toml.Annotated, tree: Toml.LocatedTree) {
        guard let source = String(bytes: bytes, encoding: .utf8) else { throw TomlSourceMutationError.invalidSource }
        let document: Toml.Annotated
        let tree: Toml.LocatedTree
        do {
            document = try Toml.Annotated(parsing: source)
            tree = try document.typedTreeWithLocations()
        } catch {
            throw TomlSourceMutationError.invalidSource
        }
        return (document, tree)
    }

    private mutating func replace(_ range: SourceByteRange, with replacement: String) throws {
        guard range.start >= 0, range.end >= range.start, range.end <= bytes.count else {
            throw TomlSourceMutationError.invalidSource
        }
        bytes.replaceSubrange(range.start..<range.end, with: replacement.utf8)
    }

    private mutating func deleteInlineEntry(_ path: ExactTomlPath) throws -> Bool {
        let state = try snapshot()
        for table in state.tree.inlineTables.values {
            guard let index = table.entries.firstIndex(where: { $0.path == path }) else { continue }
            try removeInlineEntry(table, at: index)
            return true
        }
        return false
    }

    private mutating func deleteInlineDescendant(_ prefix: ExactTomlPath) throws -> Bool {
        let state = try snapshot()
        let tables = state.tree.inlineTables.values.sorted { $0.range.start < $1.range.start }
        for table in tables {
            guard let index = table.entries.firstIndex(where: { $0.path.hasPrefix(prefix.values) }) else { continue }
            try removeInlineEntry(table, at: index)
            return true
        }
        return false
    }

    private mutating func removeInlineEntry(_ table: InlineTableSource, at index: Int) throws {
        let entry = table.entries[index]
        let range: SourceByteRange
        if table.entries.count == 1 {
            range = entry.range
        } else if index == 0 {
            guard let comma = entry.commaOffset else { throw TomlSourceMutationError.invalidSource }
            range = SourceByteRange(start: entry.range.start, end: comma + 1)
        } else {
            guard let comma = table.entries[index - 1].commaOffset else { throw TomlSourceMutationError.invalidSource }
            range = SourceByteRange(start: comma, end: entry.range.end)
        }
        try replace(range, with: "")
    }

    private mutating func insert(_ value: String, keyPath: [String], into table: InlineTableSource) throws {
        let pair = encodedKeyPath(keyPath) + " = " + value
        let fragment = Array(bytes[table.range.start..<table.range.end])
        let multiline = fragment.contains(0x0A)
        let indent = table.entries.last.map { indentation(at: $0.range.start) } ?? []
        let insertion: (offset: Int, text: String)
        if table.entries.isEmpty {
            insertion = (table.closeOffset, pair)
        } else if let comma = table.entries.last?.commaOffset {
            if multiline {
                insertion = (comma + 1, lineEnding + String(decoding: indent, as: UTF8.self) + pair + ",")
            } else {
                insertion = (comma + 1, " " + pair + ",")
            }
        } else if let last = table.entries.last {
            if multiline {
                insertion = (last.valueRange.end, "," + lineEnding + String(decoding: indent, as: UTF8.self) + pair)
            } else {
                insertion = (last.valueRange.end, ", " + pair)
            }
        } else {
            throw TomlSourceMutationError.invalidSource
        }
        guard insertion.offset >= 0, insertion.offset <= bytes.count else { throw TomlSourceMutationError.invalidSource }
        bytes.insert(contentsOf: insertion.text.utf8, at: insertion.offset)
    }

    private func indentation(at offset: Int) -> [UInt8] {
        guard offset > 0 else { return [] }
        let prefix = bytes[..<offset]
        let lineStart = prefix.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return Array(bytes[lineStart..<offset].prefix { $0 == 0x20 || $0 == 0x09 })
    }

    private func removeEntries(_ entries: inout [Toml.Annotated.Entry], under path: [String], prefix: ExactTomlPath) -> Bool {
        let oldCount = entries.count
        entries.removeAll { entry in
            ExactTomlPath(path + entry.key).hasPrefix(prefix.values)
        }
        return oldCount != entries.count
    }

    private var lineEnding: String {
        for index in bytes.indices where bytes[index] == 0x0A {
            return index > 0 && bytes[index - 1] == 0x0D ? "\r\n" : "\n"
        }
        return "\n"
    }
}

enum TomlSourceMutationError: Error {
    case invalidSource
    case invalidPath
    case pathNotFound
}

func encodedKeyPath(_ path: [String]) -> String {
    path.map(encodedKey).joined(separator: ".")
}

func encodedKey(_ key: String) -> String {
    guard !key.isEmpty,
          key.utf8.allSatisfy({
              ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) ||
              ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D
          }) else {
        return encodedString(key)
    }
    return key
}

func encodedString(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x08: output += "\\b"
        case 0x09: output += "\\t"
        case 0x0A: output += "\\n"
        case 0x0C: output += "\\f"
        case 0x0D: output += "\\r"
        case 0x22: output += "\\\""
        case 0x5C: output += "\\\\"
        case 0...0x1F, 0x7F...0x9F:
            output += scalar.value <= 0xFFFF
                ? String(format: "\\u%04X", scalar.value)
                : String(format: "\\U%08X", scalar.value)
        default: output.unicodeScalars.append(scalar)
        }
    }
    output += "\""
    return output
}

func nestedInlineTable(_ path: [String], value: String) -> String {
    guard let first = path.first else { return value }
    let nested = path.count == 1
        ? value
        : nestedInlineTable(Array(path.dropFirst()), value: value)
    return "{ " + encodedKey(first) + " = " + nested + " }"
}

private func hasLineEnding(_ value: String) -> Bool {
    value.hasSuffix("\n") || value.hasSuffix("\r")
}
