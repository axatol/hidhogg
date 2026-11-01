import Darwin
import Foundation

public struct SystemBluetoothReport: BluetoothReportReading {
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private let started: (@Sendable () -> Void)?

    public init(executable: URL = URL(fileURLWithPath: "/usr/sbin/system_profiler"),
                arguments: [String] = ["-json", "-timeout", "10", "SPBluetoothDataType"],
                timeout: TimeInterval = 12, maximumBytes: Int = 2 * 1024 * 1024,
                started: (@Sendable () -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maximumBytes = maximumBytes
        self.started = started
    }

    public func read() async throws -> Data {
        let operation = BoundedReportOperation(executable: executable, arguments: arguments,
                                             timeout: timeout, maximumBytes: maximumBytes, started: started)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class BoundedReportOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hidhogg.bluetooth-report")
    private let process = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private let started: (@Sendable () -> Void)?
    private var output = Data()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var completed = false

    init(executable: URL, arguments: [String], timeout: TimeInterval, maximumBytes: Int, started: (@Sendable () -> Void)?) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.timeout = timeout
        self.maximumBytes = maximumBytes
        self.started = started
    }

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(BluetoothObservationFailure.cancelled)); return }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                finish(.failure(BluetoothObservationFailure.reportFailed)); return
            }
            process.terminationHandler = { [self] process in
                queue.async { [self] in
                    drain()
                    guard !completed else { return }
                    finish(process.terminationStatus == 0 ? .success(output) : .failure(BluetoothObservationFailure.reportFailed))
                }
            }
            do { try process.run() }
            catch { finish(.failure(BluetoothObservationFailure.reportFailed)); return }
            started?()
            pipe.fileHandleForWriting.closeFile()
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [self] in drain() }
            self.source = source
            source.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + max(0.01, timeout))
            timer.setEventHandler { [self] in finish(.failure(BluetoothObservationFailure.timedOut)) }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { finish(.failure(BluetoothObservationFailure.cancelled)) }
        }
    }

    private func drain() {
        guard !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { return }
            guard count <= maximumBytes - output.count else {
                finish(.failure(BluetoothObservationFailure.outputLimit)); return
            }
            output.append(contentsOf: bytes.prefix(count))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !completed else { return }
        completed = true
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.terminationHandler = nil
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
        let continuation = continuation
        self.continuation = nil
        output.removeAll()
        continuation?.resume(with: result)
    }
}
