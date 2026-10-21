import Foundation

struct DiagnosticSource: Equatable, Sendable {
    let fileID: String
    let line: UInt

    init(fileID: String = #fileID, line: UInt = #line) {
        self.fileID = Self.safeFileID(fileID)
        self.line = line
    }

    var description: String { "\(fileID):\(line)" }

    private static func safeFileID(_ fileID: String) -> String {
        let components = fileID.split(separator: "/").filter { $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return "unknown" }
        return components.suffix(2).joined(separator: "/")
    }
}

struct DiagnosticEvent: Equatable, Sendable {
    let id: UUID
    let date: Date
    let code: DiagnosticCode
    let message: String
    let isError: Bool
    let source: DiagnosticSource

    init(
        id: UUID = UUID(),
        date: Date = .now,
        code: DiagnosticCode,
        message: String,
        isError: Bool = false,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        self.id = id
        self.date = date
        self.code = code
        self.message = message
        self.isError = isError
        source = DiagnosticSource(fileID: fileID, line: line)
    }

    init(
        id: UUID = UUID(),
        date: Date = .now,
        code: DiagnosticCode,
        message: String,
        isError: Bool = false,
        source: DiagnosticSource
    ) {
        self.id = id
        self.date = date
        self.code = code
        self.message = message
        self.isError = isError
        self.source = source
    }

    func consolePrefix(buildID: String) -> String {
        "code=\(code.rawValue) id=\(id.uuidString) build=\(buildID) source=\(source.description)"
    }

    func consoleMessage(buildID: String) -> String {
        "\(consolePrefix(buildID: buildID)) message=\(message)"
    }
}
