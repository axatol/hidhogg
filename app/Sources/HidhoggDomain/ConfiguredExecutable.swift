import Foundation

public struct ConfiguredExecutable: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var timeoutSeconds: Int

    public init(executable: String, arguments: [String] = [], workingDirectory: String? = nil, timeoutSeconds: Int = 10) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func validated() throws -> Self {
        guard executable.hasPrefix("/"), executable.utf8.count <= 4096,
              !executable.contains("\0"), (1...60).contains(timeoutSeconds),
              arguments.count <= 64, arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
              workingDirectory.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true else {
            throw ConfigurationValidationError.invalidD200XAction
        }
        return self
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), let first = value.utf8.first,
              isAlphanumeric(first) else { return false }
        return value.utf8.allSatisfy { isAlphanumeric($0) || [45, 46, 95].contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
