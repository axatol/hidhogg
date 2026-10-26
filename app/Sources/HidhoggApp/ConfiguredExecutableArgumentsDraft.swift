import Foundation

struct ConfiguredExecutableArgumentsDraft: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        var value: String

        init(value: String) {
            id = UUID()
            self.value = value
        }
    }

    static let maximumArgumentCount = 64

    var rows: [Row]

    init(arguments: [String] = []) {
        rows = arguments.map(Row.init(value:))
    }

    var arguments: [String] {
        rows.map(\.value)
    }

    var canAddArgument: Bool {
        rows.count < Self.maximumArgumentCount
    }

    @discardableResult
    mutating func addArgument() -> Bool {
        guard canAddArgument else { return false }
        rows.append(Row(value: ""))
        return true
    }

    mutating func updateArgument(id: UUID, value: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].value = value
    }

    mutating func removeArgument(id: UUID) {
        rows.removeAll { $0.id == id }
    }
}
