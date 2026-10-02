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
    private let handlerLock = NSLock()
    private var stopped = false
    private var standardOutputHandlerUnregistered = false
    private var standardErrorHandlerUnregistered = false
    private var finalDrainStarted = false

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
            self?.drain(handle: handle, into: self?.standardOutputTail, isStandardError: false)
        }
        standardError.readabilityHandler = { [weak self] handle in
            self?.drain(handle: handle, into: self?.standardErrorTail, isStandardError: true)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        unregisterHandlers()
    }

    public func finishAfterProcessExit() {
        lock.lock()
        stopped = true
        let shouldDrain = !finalDrainStarted
        finalDrainStarted = true
        lock.unlock()

        unregisterHandlers()
        guard shouldDrain else { return }

        lock.lock()
        drainAvailable(standardOutput, into: standardOutputTail)
        drainAvailable(standardError, into: standardErrorTail)
        lock.unlock()
    }

    private func unregisterHandlers() {
        unregisterHandler(isStandardError: false)
        unregisterHandler(isStandardError: true)
    }

    private func unregisterHandler(isStandardError: Bool) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        if isStandardError {
            guard !standardErrorHandlerUnregistered else { return }
            standardErrorHandlerUnregistered = true
            standardError.readabilityHandler = nil
            return
        }
        guard !standardOutputHandlerUnregistered else { return }
        standardOutputHandlerUnregistered = true
        standardOutput.readabilityHandler = nil
    }

    private func drain(handle: FileHandle, into tail: OutputTail?, isStandardError: Bool) {
        guard let tail else { return }
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let data = handle.availableData
        if data.isEmpty {
            lock.unlock()
            DispatchQueue.global().async { [weak self] in
                self?.unregisterHandler(isStandardError: isStandardError)
            }
            return
        }
        tail.append(data)
        lock.unlock()
    }

    private func drainAvailable(_ handle: FileHandle, into tail: OutputTail) {
        let maximumBytes = min(tail.capacity, 65_536)
        guard maximumBytes > 0 else { return }
        let descriptor = handle.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            return
        }
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

        var remainingBytes = maximumBytes
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes))
        while remainingBytes > 0 {
            let bytesRead = buffer.withUnsafeMutableBytes { bufferBytes in
                guard let baseAddress = bufferBytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, min(bufferBytes.count, remainingBytes))
            }
            guard bytesRead >= 0 else {
                if errno == EINTR { continue }
                return
            }
            guard bytesRead > 0 else { return }
            tail.append(Data(buffer.prefix(bytesRead)))
            remainingBytes -= bytesRead
        }
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
        drainer.finishAfterProcessExit()
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
