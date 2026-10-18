import Foundation

public enum IPCCommandLineError: Error, Sendable, Equatable {
    case usage
}

public struct IPCCommandLineInvocation: Sendable {
    public let runtimeDirectory: String
    public let command: IPCCommand

    init(runtimeDirectory: String, command: IPCCommand) {
        self.runtimeDirectory = runtimeDirectory
        self.command = command
    }
}

public enum IPCCommandLineParser {
    public static func parse(_ arguments: [String]) throws -> IPCCommandLineInvocation {
        guard arguments.count >= 3, arguments[0] == "--runtime-dir", !arguments[1].isEmpty else {
            throw IPCCommandLineError.usage
        }
        let runtimeDirectory = arguments[1]
        let commandArguments = Array(arguments.dropFirst(2))
        let command = try parseCommand(commandArguments)
        return IPCCommandLineInvocation(runtimeDirectory: runtimeDirectory, command: command)
    }

    private static func parseCommand(_ arguments: [String]) throws -> IPCCommand {
        guard let first = arguments.first else { throw IPCCommandLineError.usage }
        switch first {
        case "health":
            guard arguments.count == 1 else { throw IPCCommandLineError.usage }
            return .health
        case "status":
            guard arguments.count == 1 else { throw IPCCommandLineError.usage }
            return .status
        case "profiles":
            guard arguments.count == 2 || arguments.count == 3 else { throw IPCCommandLineError.usage }
            switch arguments[1] {
            case "list" where arguments.count == 2:
                return .profilesList
            case "activate" where arguments.count == 3:
                return .profilesActivate(profileID: arguments[2])
            default:
                throw IPCCommandLineError.usage
            }
        case "notifications":
            return try parseNotification(Array(arguments.dropFirst()))
        default:
            throw IPCCommandLineError.usage
        }
    }

    private static func parseNotification(_ arguments: [String]) throws -> IPCCommand {
        guard let action = arguments.first else { throw IPCCommandLineError.usage }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "clear":
            guard rest.count == 1 else { throw IPCCommandLineError.usage }
            return .clearNotification(id: rest[0])
        case "emit":
            var fields = [String: String]()
            var index = 0
            while index < rest.count {
                guard index + 1 < rest.count, rest[index].hasPrefix("--") else { throw IPCCommandLineError.usage }
                let key = rest[index]
                guard ["--source", "--text", "--ttl-seconds"].contains(key), fields[key] == nil else {
                    throw IPCCommandLineError.usage
                }
                fields[key] = rest[index + 1]
                index += 2
            }
            guard let source = fields["--source"], let text = fields["--text"] else { throw IPCCommandLineError.usage }
            let ttl: Int?
            if let rawTTL = fields["--ttl-seconds"] {
                guard let value = Int(rawTTL) else { throw IPCCommandLineError.usage }
                ttl = value
            } else {
                ttl = nil
            }
            return .emitNotification(source: source, text: text, ttlSeconds: ttl)
        default:
            throw IPCCommandLineError.usage
        }
    }
}
