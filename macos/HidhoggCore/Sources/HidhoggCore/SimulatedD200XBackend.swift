import Foundation

enum D200XSimulatorWriteDecision {
    case send
    case fail
    case removed
}

final class D200XSimulatorControl: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [D200XDecodedFrame]()
    private var inputHandler: (@Sendable (Data) -> Void)?
    private var failureHandler: (@Sendable (D200XSessionFailure) -> Void)?
    private var failureWriteAttempt: Int?
    private var writeAttempts = 0
    private var removed = false
    private var screenUnlocked = false
    private var uploadedArchive: Data?
    private var currentBrightness: Int?
    private var inputStreamEnabled = false
    private var inputStreamEnableCount = 0

    var receivedFrames: [D200XDecodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var reportWriteAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeAttempts
    }

    var deviceRemoved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return removed
    }

    var isScreenUnlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return screenUnlocked
    }

    var displayArchive: Data? {
        lock.lock()
        defer { lock.unlock() }
        return uploadedArchive
    }

    var brightness: Int? {
        lock.lock()
        defer { lock.unlock() }
        return currentBrightness
    }

    var isInputStreamEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inputStreamEnabled
    }

    var inputStreamEnableCountValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return inputStreamEnableCount
    }

    func failReportWrite(at attempt: Int) {
        lock.lock()
        failureWriteAttempt = attempt
        lock.unlock()
    }

    func removeDevice() {
        lock.lock()
        removed = true
        let handler = failureHandler
        lock.unlock()
        handler?(.deviceRemoved)
    }

    func emitInputReport(_ packet: Data) {
        lock.lock()
        let handler = inputHandler
        lock.unlock()
        handler?(Data(packet))
    }

    fileprivate func record(_ frame: D200XDecodedFrame) throws {
        lock.lock()
        defer { lock.unlock() }

        switch frame.command {
        case D200XOutboundCommand.unlockScreen.rawValue:
            guard frame.payload.isEmpty else { throw D200XSessionError.invalidSyntheticReport }
            screenUnlocked = true
        case D200XOutboundCommand.completeDisplayUpload.rawValue:
            uploadedArchive = frame.payload
        case D200XOutboundCommand.brightness.rawValue:
            guard let valueString = String(data: frame.payload, encoding: .utf8),
                  let value = Int(valueString),
                  (0...100).contains(value),
                  String(value) == valueString else {
                throw D200XSessionError.invalidSyntheticReport
            }
            currentBrightness = value
        case D200XOutboundCommand.enableInputStream.rawValue:
            guard frame.payload.isEmpty else { throw D200XSessionError.invalidSyntheticReport }
            inputStreamEnabled = true
            inputStreamEnableCount += 1
        default:
            throw D200XSessionError.invalidSyntheticReport
        }
        frames.append(frame)
    }

    fileprivate func setInputHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        inputHandler = handler
        lock.unlock()
    }

    fileprivate func setFailureHandler(_ handler: (@Sendable (D200XSessionFailure) -> Void)?) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    fileprivate func beginReportWrite() -> D200XSimulatorWriteDecision {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return .removed }
        writeAttempts += 1
        return writeAttempts == failureWriteAttempt ? .fail : .send
    }
}

final class SimulatedD200XBackend: D200XSessionBackend, @unchecked Sendable {
    private static let candidate = D200XDeviceCandidate(
        registryID: 1,
        vendorID: 0x2207,
        productID: 0x0019,
        interfaceNumber: 0,
        usagePage: 0x000c,
        usage: 0x0001,
        maximumOutputReportSize: D200XFrameCodec.packetSize
    )

    private let lock = NSLock()
    private let control: D200XSimulatorControl
    private var opened = false
    private var stopped = false
    private var outputAssembler: D200XFrameAssembler?
    private var inputAssembler: D200XFrameAssembler?
    private var inputHandler: (@Sendable (D200XInputEvent) -> Void)?
    private var failureHandler: (@Sendable (D200XSessionFailure) -> Void)?

    init(control: D200XSimulatorControl = D200XSimulatorControl()) {
        self.control = control
    }

    func candidates() throws -> [D200XDeviceCandidate] {
        withLock { stopped || control.deviceRemoved ? [] : [Self.candidate] }
    }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) throws {
        try withLock {
            guard !stopped else { throw D200XSessionError.sessionClosed }
            guard candidate == Self.candidate else { throw D200XSessionError.selectedDeviceChanged }
            guard !opened else { throw D200XSessionError.sessionClosed }
            opened = true
            inputHandler = onInput
            failureHandler = onFailure
        }
        control.setInputHandler { [weak self] report in self?.receiveInput(report) }
        control.setFailureHandler { [weak self] failure in self?.receiveFailure(failure) }
    }

    func send(reportID: UInt32, packet: Data) throws {
        guard reportID == 0, packet.count == D200XFrameCodec.packetSize else {
            throw D200XSessionError.invalidSyntheticReport
        }
        switch control.beginReportWrite() {
        case .send: break
        case .fail: throw D200XSessionError.writeFailed
        case .removed: throw D200XSessionError.sessionClosed
        }

        try withLock {
            guard opened, !stopped else { throw D200XSessionError.sessionClosed }
            do {
                if outputAssembler == nil {
                    outputAssembler = try D200XFrameAssembler(firstReport: packet)
                } else {
                    try outputAssembler?.append(packet)
                }
                guard let outputAssembler, outputAssembler.isComplete else { return }
                try control.record(try outputAssembler.frame())
                self.outputAssembler = nil
            } catch {
                outputAssembler = nil
                throw D200XSessionError.invalidSyntheticReport
            }
        }
    }

    func stop() async -> D200XSessionStopOutcome {
        withLock {
            guard !stopped else { return .closed }
            stopped = true
            opened = false
            outputAssembler = nil
            inputAssembler = nil
            inputHandler = nil
            failureHandler = nil
            control.setInputHandler(nil)
            control.setFailureHandler(nil)
            return .closed
        }
    }

    private func receiveInput(_ packet: Data) {
        let result: Result<D200XInputEvent?, D200XSessionFailure> = withLock {
            guard opened, !stopped else { return .success(nil) }
            guard packet.count == D200XFrameCodec.packetSize else {
                return .failure(.malformedInput)
            }
            do {
                if inputAssembler == nil {
                    inputAssembler = try D200XFrameAssembler(firstReport: packet)
                } else {
                    try inputAssembler?.append(packet)
                }
                guard let inputAssembler, inputAssembler.isComplete else { return .success(nil) }
                let frame = try inputAssembler.frame()
                self.inputAssembler = nil
                return .success(try D200XFrameCodec.decodeInput(frame))
            } catch {
                inputAssembler = nil
                return .failure(.malformedInput)
            }
        }

        switch result {
        case let .success(event):
            guard let event else { return }
            withLock { inputHandler }?(event)
        case let .failure(failure):
            withLock { failureHandler }?(failure)
        }
    }

    private func receiveFailure(_ failure: D200XSessionFailure) {
        withLock { failureHandler }?(failure)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
