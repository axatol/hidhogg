import Darwin
import Foundation
import LofreeFlowLite84

@main
struct FlowLite84StatusProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let refreshOnce = arguments == ["--read-only", "--refresh-once"]
        guard arguments == ["--read-only"] || refreshOnce else {
            print("Usage: flowlite84-status --read-only [--refresh-once]")
            return
        }

        let progress = ProbeProgress()
        let session = FlowLite84Session(makeTransport: { ProbeTransport(progress: progress) })
        do {
            let snapshot = try await withThrowingTaskGroup(of: FlowLite84Snapshot.self) { group in
                group.addTask {
                    let events = session.events
                    let result = Task {
                        var snapshots = 0
                        for await event in events {
                            if case .snapshot(let snapshot, _) = event {
                                snapshots += 1
                                if snapshots == (refreshOnce ? 2 : 1) { return snapshot }
                            }
                            try Task.checkCancellation()
                        }
                        throw FlowLite84Failure.cancelled
                    }
                    return try await withTaskCancellationHandler {
                        do {
                            try await session.connect()
                            if refreshOnce {
                                progress.markRefreshWait()
                                try await Task.sleep(for: .seconds(2))
                                progress.markRefresh()
                                try await session.refresh()
                            }
                            return try await result.value
                        } catch {
                            result.cancel()
                            throw error
                        }
                    } onCancel: {
                        result.cancel()
                        Task { await session.disconnect() }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw FlowLite84Failure.timeout
                }
                defer { group.cancelAll() }
                guard let snapshot = try await group.next() else { throw FlowLite84Failure.cancelled }
                return snapshot
            }
            await session.disconnect()
            emit(snapshot, progress: progress)
        } catch {
            let status = await session.status
            let failure: FlowLite84Failure?
            if case .failed(let cause) = status {
                failure = cause
            } else {
                failure = error as? FlowLite84Failure
            }
            await session.disconnect()
            let message = failure?.userMessage ?? "The read-only status probe failed."
            emitJSON(["status": "unavailable", "message": message, "failure": failure.map { String(describing: $0) } ?? "unknown", "stage": progress.stage, "stages": progress.stages])
            exit(EXIT_FAILURE)
        }
    }

    private static func emit(_ snapshot: FlowLite84Snapshot, progress: ProbeProgress) {
        var output: [String: Any] = [
            "status": "read", "online": snapshot.online,
            "identity": ["cid": snapshot.identity.cid, "mid": snapshot.identity.mid,
                         "connectionType": snapshot.identity.connectionType],
            "readAt": ISO8601DateFormatter().string(from: snapshot.readAt),
            "unavailableFields": snapshot.unavailableFields,
            "stages": progress.stages
        ]
        output["keyboardVersion"] = snapshot.keyboardVersion
        output["receiverVersion"] = snapshot.receiverVersion
        output["systemMode"] = snapshot.systemMode
        if let battery = snapshot.battery {
            var fields: [String: Any] = [:]
            fields["reportedLevel"] = battery.reportedLevel
            fields["charging"] = battery.charging
            fields["voltageMillivolts"] = battery.voltageMillivolts
            output["battery"] = fields
        }
        if let lighting = snapshot.lighting {
            var fields: [String: Any] = ["mode": lighting.mode, "enabled": lighting.enabled,
                                         "idleOffUnits": lighting.idleOffUnits]
            fields["brightnessLevel"] = lighting.brightnessLevel
            fields["speedLevel"] = lighting.speedLevel
            output["lighting"] = fields
        }
        emitJSON(output)
    }

    private static func emitJSON(_ output: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

private final class ProbeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "open"
    private var history: [String] = []

    var stage: String { lock.withLock { value } }
    var stages: [String] { lock.withLock { history } }

    func markRefresh() { recordLabel("manual-refresh") }
    func markRefreshWait() { recordLabel("wait-for-refresh") }

    func markWriteComplete() {
        lock.withLock {
            if history.count < 64 { history.append("\(value)-write-complete") }
        }
    }

    private func recordLabel(_ label: String) {
        lock.withLock {
            value = label
            if history.count < 64 { history.append(label) }
        }
    }

    func record(_ report: Data) {
        guard report.count == 17, report.first == 8 else { return }
        let command = report[1]
        let label: String
        switch command {
        case 1: label = "identity"
        case 3: label = "online"
        case 4: label = "battery"
        case 18: label = "keyboard-version"
        case 29: label = "receiver-version"
        case 8:
            let address = UInt16(report[3]) << 8 | UInt16(report[4])
            switch address {
            case 8496: label = "lighting-mode"
            case 8498: label = "lighting-enabled"
            case 8500: label = "lighting-idle"
            case 9416: label = "system-mode"
            default: label = "lighting-parameters"
            }
        default: label = "unsupported-request"
        }
        recordLabel(label)
    }
}

private struct ProbeTransport: FlowLite84Transport {
    let progress: ProbeProgress
    private let transport = IOKitFlowLite84Transport()

    var reports: AsyncThrowingStream<Data, Error> { transport.reports }
    func open() async throws { try await transport.open() }
    func close() async { await transport.close() }
    func write(_ report: Data) async throws {
        progress.record(report)
        try await transport.write(report)
        progress.markWriteComplete()
    }
}
