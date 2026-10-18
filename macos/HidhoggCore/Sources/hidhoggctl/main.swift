import Darwin
import Foundation
import HidhoggCore

@main
struct HidhoggCtl {
    static func main() async {
        do {
            let invocation = try IPCCommandLineParser.parse(Array(CommandLine.arguments.dropFirst()))
            let runtime = try IPCRuntimeDiscovery.resolve(invocation.runtimeDirectory)
            let response = try await IPCClient(runtime: runtime).call(invocation.command)
            if let failure = response.failure {
                write(.object([
                    ("error", .object([
                        ("code", .string(failure.code)),
                        ("message", .string(failure.message)),
                    ])),
                ]), to: .standardError)
                Darwin.exit(EXIT_FAILURE)
            }
            guard let result = response.result else {
                write(.object([("error", .string("invalid response"))]), to: .standardError)
                Darwin.exit(EXIT_FAILURE)
            }
            write(result, to: .standardOutput)
        } catch IPCCommandLineError.usage {
            write(.string(Self.usage), to: .standardError)
            Darwin.exit(EX_USAGE)
        } catch {
            write(.object([("error", .string("runtime request failed"))]), to: .standardError)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static let usage = "usage: hidhoggctl --runtime-dir PATH health | status | profiles list | profiles activate ID | notifications emit --source ID --text TEXT [--ttl-seconds N] | notifications clear UUID"

    private static func write(_ value: IPCJSONValue, to handle: FileHandle) {
        var bytes = IPCJSONCodec.encode(value)
        bytes.append(0x0a)
        handle.write(bytes)
    }
}
