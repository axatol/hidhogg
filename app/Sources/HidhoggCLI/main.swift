import Foundation
import Darwin
import HidhoggAutomation

private let usage = """
Usage: hidhoggctl [--socket ABSOLUTE_PATH] COMMAND

  actions invoke ID
  actions history
  notifications emit --topic TOPIC [--text TEXT] [--app-id BUNDLE_ID] [--ttl-seconds N]
  notifications clear UUID
  notifications history
  status
  help

Connects to the running local Hidhogg service. Commands are never retried.
After a timeout or disconnect the outcome may be unknown.
"""

private enum CLIError: Error { case invalidArguments }

private struct Command {
    let socketURL: URL
    let request: AutomationRequest?

    init(arguments: [String]) throws {
        var arguments = arguments
        var socketURL = AutomationEndpoint.defaultSocketURL()
        if arguments.first == "--socket" {
            guard arguments.count >= 3, arguments[1].hasPrefix("/"), !arguments[1].utf8.contains(0) else { throw CLIError.invalidArguments }
            socketURL = URL(fileURLWithPath: arguments[1])
            arguments.removeFirst(2)
        }
        self.socketURL = socketURL
        if arguments == ["help"] || arguments == ["--help"] || arguments.isEmpty {
            request = nil
            return
        }
        if arguments == ["status"] { request = AutomationRequest(method: .status); return }
        if arguments == ["actions", "history"] { request = AutomationRequest(method: .actionsHistory); return }
        if arguments == ["notifications", "history"] { request = AutomationRequest(method: .notificationsHistory); return }
        if arguments.count == 3, arguments.prefix(2) == ["actions", "invoke"] {
            request = AutomationRequest(method: .actionsInvoke, params: AutomationParameters(actionID: arguments[2]))
            try request?.validated()
            return
        }
        if arguments.count == 3, arguments.prefix(2) == ["notifications", "clear"], let id = UUID(uuidString: arguments[2]) {
            request = AutomationRequest(method: .notificationsClear, params: AutomationParameters(notificationID: id))
            return
        }
        guard arguments.count >= 2, arguments.prefix(2) == ["notifications", "emit"] else { throw CLIError.invalidArguments }
        arguments.removeFirst(2)
        var options: [String: String] = [:]
        while !arguments.isEmpty {
            guard arguments.count >= 2, ["--topic", "--text", "--app-id", "--ttl-seconds"].contains(arguments[0]),
                  options[arguments[0]] == nil else {
                throw CLIError.invalidArguments
            }
            options[arguments[0]] = arguments[1]
            arguments.removeFirst(2)
        }
        var ttl: Int?
        if let value = options["--ttl-seconds"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let integer = Int(value) else { throw CLIError.invalidArguments }
            ttl = integer
        }
        request = AutomationRequest(method: .notificationsEmit, params: AutomationParameters(
            topic: options["--topic"], text: options["--text"], ttlSeconds: ttl, appID: options["--app-id"]
        ))
        try request?.validated()
    }
}

do {
    let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
    if let request = command.request {
        let response = try LocalAutomationClient.send(request, socketURL: command.socketURL)
        FileHandle.standardOutput.write(try AutomationFrame.encode(response))
        if response.error != nil { exit(1) }
    } else {
        print(usage)
    }
} catch is CLIError {
    FileHandle.standardError.write(Data("Invalid arguments. Run hidhoggctl help.\n".utf8))
    exit(2)
} catch is AutomationProtocolError {
    FileHandle.standardError.write(Data("Invalid request or service response. Run hidhoggctl help.\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("Local service unavailable or timed out; outcome may be unknown. No retry was attempted.\n".utf8))
    exit(1)
}
