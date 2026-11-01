import Foundation

public struct SystemIORegistryBatteryReport: BluetoothReportReading {
    private let processReport: SystemBluetoothReport

    public init(executable: URL = URL(fileURLWithPath: "/usr/sbin/ioreg"),
                arguments: [String] = ["-a", "-r", "-d", "1", "-k", "BatteryPercent"],
                timeout: TimeInterval = 5, maximumBytes: Int = 1024 * 1024,
                started: (@Sendable () -> Void)? = nil) {
        processReport = SystemBluetoothReport(executable: executable, arguments: arguments,
                                              timeout: timeout, maximumBytes: maximumBytes, started: started)
    }

    public func read() async throws -> Data { try await processReport.read() }
}
