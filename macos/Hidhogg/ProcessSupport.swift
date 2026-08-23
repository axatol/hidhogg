import Foundation
import Darwin

public final class OutputTail: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage = Data()

    public init(capacity: Int = 65_536) {
        self.capacity = max(0, capacity)
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
    }

    public var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

public final class OutputDrainer: @unchecked Sendable {
    public let standardOutputTail: OutputTail
    public let standardErrorTail: OutputTail
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let lock = NSLock()
    private var stopped = false

    public init(
        standardOutput: FileHandle,
        standardError: FileHandle,
        standardOutputTail: OutputTail = OutputTail(),
        standardErrorTail: OutputTail = OutputTail()
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTail = standardOutputTail
        self.standardErrorTail = standardErrorTail
    }

    public func start() {
        standardOutput.readabilityHandler = { [weak self] handle in
            self?.drain(handle: handle, into: self?.standardOutputTail)
        }
        standardError.readabilityHandler = { [weak self] handle in
            self?.drain(handle: handle, into: self?.standardErrorTail)
        }
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
    }

    private func drain(handle: FileHandle, into tail: OutputTail?) {
        guard let tail else { return }
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        tail.append(data)
    }
}

public struct LaunchRequest: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public enum ProcessExit: Equatable, Sendable {
    case exit(status: Int32)
    case signal(Int32)
}

public protocol ManagedProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    var exit: ProcessExit? { get }
    func terminate()
    func forceTerminate()
}

public protocol ProcessLaunching: Sendable {
    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess
}

public final class FoundationManagedProcess: @unchecked Sendable, ManagedProcess {
    private let process: Process
    private let drainer: OutputDrainer

    public init(process: Process, drainer: OutputDrainer) {
        self.process = process
        self.drainer = drainer
    }

    deinit {
        drainer.stop()
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public var exit: ProcessExit? {
        guard !process.isRunning else { return nil }
        drainer.stop()
        switch process.terminationReason {
        case .exit:
            return .exit(status: process.terminationStatus)
        case .uncaughtSignal:
            return .signal(process.terminationStatus)
        @unknown default:
            return .exit(status: process.terminationStatus)
        }
    }

    public func terminate() {
        process.terminate()
    }

    public func forceTerminate() {
        guard process.processIdentifier > 0 else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    public func stopDraining() {
        drainer.stop()
    }
}

public struct FoundationProcessLauncher: ProcessLaunching, Sendable {
    public init() {}

    public func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        let drainer = OutputDrainer(
            standardOutput: standardOutputPipe.fileHandleForReading,
            standardError: standardErrorPipe.fileHandleForReading,
            standardOutputTail: standardOutputTail,
            standardErrorTail: standardErrorTail
        )
        try process.run()
        drainer.start()
        return FoundationManagedProcess(process: process, drainer: drainer)
    }
}
