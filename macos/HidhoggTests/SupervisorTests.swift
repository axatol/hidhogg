import Foundation
import Darwin
import XCTest
@testable import Hidhogg

final class SupervisorTests: XCTestCase {
    func testReadinessUsesInjectedHealthClientAndPassesGenerationArguments() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = FakeManagedProcess(running: true)
        let launcher = FakeLauncher(processes: [process])
        let healthFactory = FakeHealthFactory { requestID, instanceID in
            RuntimeResponse(
                requestID: requestID,
                instanceID: instanceID,
                state: "ready",
                protocolVersion: nil,
                error: nil
            )
        }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 2_000_000,
                readinessPollNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: SystemHidhoggClock(),
            requestIDProvider: FixedRequestIDProvider(),
            instanceIDProvider: FixedUUIDProvider(),
            healthClientFactory: healthFactory,
            socketIdentityValidator: FixedSocketIdentityValidator()
        )

        let runTask = Task { await supervisor.run() }
        for _ in 0..<100 {
            let snapshot = await supervisor.snapshot()
            if snapshot.state == .ready { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let readySnapshot = await supervisor.snapshot()
        XCTAssertEqual(readySnapshot.state, .ready)
        await supervisor.quit()
        await runTask.value

        let request = try XCTUnwrap(launcher.requests.first)
        XCTAssertEqual(request.executablePath, "/tmp/hidhogg-runtime")
        XCTAssertEqual(request.arguments.count, 6)
        XCTAssertEqual(request.arguments[0], "--socket-path")
        XCTAssertEqual(request.arguments[2], "--instance-id")
        XCTAssertEqual(request.arguments[3], FixedUUIDProvider.value.uuidString.lowercased())
        XCTAssertEqual(request.arguments[4], "--config-path")
        XCTAssertEqual(request.arguments[5], "/tmp/hidhogg-test.toml")
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.forceTerminateCount, 0)
    }

    func testQuitBeforeRunPreventsChildLaunch() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher(processes: [FakeManagedProcess(running: true)])
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml"
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.quit()
        await supervisor.run()

        XCTAssertEqual(launcher.requests, [])
        let stoppedSnapshot = await supervisor.snapshot()
        XCTAssertEqual(stoppedSnapshot.state, .stopped)
    }

    func testSocketSubstitutionFailsWithoutAdoptingReplacement() async throws {
        let root = try makeTemporaryRoot()
        let substitution = SocketSubstitutionCoordinator()
        defer {
            substitution.cleanup()
            try? FileManager.default.removeItem(at: root)
        }

        let process = FakeManagedProcess(running: true)
        let launcher = FakeLauncher(processes: [process]) { request in
            try substitution.installSocket(at: request.arguments[1])
        }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 5_000_000,
                readinessPollNanoseconds: 1_000_000,
                restartDelayNanoseconds: 100_000_000,
                terminateGraceNanoseconds: 1_000_000,
                killGraceNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: SystemHidhoggClock(),
            requestIDProvider: FixedRequestIDProvider(),
            instanceIDProvider: FixedUUIDProvider(),
            healthClientFactory: SubstitutingHealthFactory(coordinator: substitution)
        )

        let runTask = Task { await supervisor.run() }
        var observedSecurityFailure = false
        for _ in 0..<100 {
            let snapshot = await supervisor.snapshot()
            if case .failed(.security) = snapshot.state {
                observedSecurityFailure = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(observedSecurityFailure)
        await supervisor.quit()
        await runTask.value

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.forceTerminateCount, 0)
        XCTAssertTrue(substitution.replacementExists())
        XCTAssertNoThrow(try substitution.validateReplacement())
    }

    func testSecondFailureIsTerminalAfterExactlyOneRestart() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FakeManagedProcess(running: false, exit: .exit(status: 7))
        let second = FakeManagedProcess(running: false, exit: .signal(9))
        let launcher = FakeLauncher(processes: [first, second])
        let clock = RecordingClock()
        let instanceIDs = SequenceUUIDProvider(values: [
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        ])
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: clock,
            requestIDProvider: FixedRequestIDProvider(),
            instanceIDProvider: instanceIDs,
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()
        let snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.restartExhausted))
        XCTAssertEqual(snapshot.restartCount, 1)
        XCTAssertEqual(launcher.requests.count, 2)
        XCTAssertEqual(launcher.requests[0].arguments[3], "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertEqual(launcher.requests[1].arguments[3], "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let sleeps = await clock.recordedSleeps()
        XCTAssertEqual(sleeps.filter { $0 == 500_000_000 }, [500_000_000])
    }

    func testRestartExhaustionCapturesNewestBoundedPrintableStderrLine() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = "D200X_HID_OPEN_PATH_FAILED: \(String(repeating: "x", count: 300))"
        let launcher = StderrSequenceLauncher(outputs: [
            "first generation detail\n",
            "older second-generation detail\n\(detail)\u{0001}\n"
                + "D200X_HID_OPEN_PATH_CAUSE: /dev/hidraw7 serial=sample\n"
        ])
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1,
                restartDelayNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: RecordingClock(),
            instanceIDProvider: SequenceUUIDProvider(values: [
                UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
            ]),
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()

        let snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.restartExhausted))
        XCTAssertEqual(snapshot.lastFailureDetail, String(detail.prefix(240)))
        XCTAssertFalse(snapshot.lastFailureDetail?.contains("\n") ?? true)
        XCTAssertFalse(snapshot.lastFailureDetail?.contains("\u{0001}") ?? true)
    }

    func testRestartExhaustionHasNoFailureDetailWhenStderrIsEmpty() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1,
                restartDelayNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: StderrSequenceLauncher(outputs: ["", ""]),
            clock: RecordingClock(),
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()

        let snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.restartExhausted))
        XCTAssertNil(snapshot.lastFailureDetail)
        XCTAssertEqual(SupervisorFailure.restartExhausted.description, "runtime failed after one restart")
    }

    func testRestartExhaustionDoesNotReuseFirstAttemptDetailWhenSecondStderrIsEmpty() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1,
                restartDelayNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: StderrSequenceLauncher(outputs: [
                "D200X_HID_OPEN_PATH_FAILED: first attempt only\n",
                ""
            ]),
            clock: RecordingClock(),
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()

        let snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.restartExhausted))
        XCTAssertNil(snapshot.lastFailureDetail)
    }

    func testExitedProcessDrainsUnreadFinalStderrBytes() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'D200X_HID_OPEN_PATH_FAILED: final stderr detail\\n' >&2"]
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        let standardErrorTail = OutputTail()
        let drainer = OutputDrainer(
            standardOutput: standardOutputPipe.fileHandleForReading,
            standardError: standardErrorPipe.fileHandleForReading,
            standardErrorTail: standardErrorTail
        )

        try process.run()
        standardOutputPipe.fileHandleForWriting.closeFile()
        standardErrorPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let managedProcess = FoundationManagedProcess(process: process, drainer: drainer)
        XCTAssertEqual(managedProcess.exit, .exit(status: 0))
        XCTAssertEqual(standardErrorTail.text, "D200X_HID_OPEN_PATH_FAILED: final stderr detail\n")
    }

    func testStartedDrainerHandlesConcurrentStopAndPostExitDrain() async throws {
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardErrorTail = OutputTail()
        let drainer = OutputDrainer(
            standardOutput: standardOutputPipe.fileHandleForReading,
            standardError: standardErrorPipe.fileHandleForReading,
            standardErrorTail: standardErrorTail
        )
        let initialOutput = "initial diagnostic\n"
        let finalOutput = "final diagnostic\n"
        drainer.start()
        try standardErrorPipe.fileHandleForWriting.write(contentsOf: Data(initialOutput.utf8))

        for _ in 0..<200 {
            if standardErrorTail.text == initialOutput { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(standardErrorTail.text, initialOutput)

        try standardErrorPipe.fileHandleForWriting.write(contentsOf: Data(finalOutput.utf8))
        let completionGroup = DispatchGroup()
        completionGroup.enter()
        DispatchQueue.global().async {
            defer { completionGroup.leave() }
            drainer.stop()
        }
        completionGroup.enter()
        DispatchQueue.global().async {
            defer { completionGroup.leave() }
            drainer.finishAfterProcessExit()
        }
        XCTAssertEqual(completionGroup.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(standardErrorTail.text, initialOutput + finalOutput)
        drainer.finishAfterProcessExit()
        drainer.stop()
        XCTAssertEqual(standardErrorTail.text, initialOutput + finalOutput)
        standardOutputPipe.fileHandleForWriting.closeFile()
        standardErrorPipe.fileHandleForWriting.closeFile()
    }

    func testFailedLaunchAttemptsRemoveEveryGeneration() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FailingLauncher(failures: 2)
        let instanceIDs = SequenceUUIDProvider(values: [
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        ])
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1,
                restartDelayNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: RecordingClock(),
            instanceIDProvider: instanceIDs,
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()

        let snapshot = await supervisor.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.restartExhausted))
        XCTAssertEqual(launcher.requests.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCleanupFailureIsObservableAndPreventsRestart() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FailingLauncher(failures: 1) { request in
            let generation = URL(fileURLWithPath: request.arguments[1]).deletingLastPathComponent()
            try Data([0x01]).write(to: generation.appendingPathComponent("unexpected"))
        }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 1,
                readinessPollNanoseconds: 1,
                restartDelayNanoseconds: 1
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: RecordingClock(),
            instanceIDProvider: FixedUUIDProvider(),
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(requestID: requestID, instanceID: instanceID, state: "ready", protocolVersion: nil, error: nil)
            }
        )

        await supervisor.run()

        let snapshot = await supervisor.snapshot()
        guard case .failed(.cleanup(let message)) = snapshot.state else {
            XCTFail("cleanup failure was not observable: \(snapshot.state)")
            return
        }
        XCTAssertTrue(message.contains("notEmpty"))
        XCTAssertEqual(launcher.requests.count, 1)
    }

    func testQuitCleanupFailureSurvivesPendingRunFinalCleanup() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = FakeManagedProcess(running: true)
        let launcher = FakeLauncher(processes: [process]) { request in
            let generation = URL(fileURLWithPath: request.arguments[1]).deletingLastPathComponent()
            try Data([0x01]).write(to: generation.appendingPathComponent("unexpected"))
        }
        let clock = ReadyThenGatedClock()
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 2_000_000,
                readinessPollNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: clock,
            instanceIDProvider: FixedUUIDProvider(),
            healthClientFactory: FakeHealthFactory { requestID, instanceID in
                RuntimeResponse(
                    requestID: requestID,
                    instanceID: instanceID,
                    state: "ready",
                    protocolVersion: nil,
                    error: nil
                )
            },
            socketIdentityValidator: FixedSocketIdentityValidator()
        )

        let runTask = Task { await supervisor.run() }
        await clock.waitUntilGated()
        await supervisor.quit()

        let quitSnapshot = await supervisor.snapshot()
        guard case .failed(.cleanup(let quitFailure)) = quitSnapshot.state else {
            XCTFail("quit did not expose the generation cleanup failure: \(quitSnapshot.state)")
            await clock.release()
            await runTask.value
            return
        }
        XCTAssertTrue(quitFailure.contains("notEmpty"))

        await clock.release()
        await runTask.value

        let finalSnapshot = await supervisor.snapshot()
        guard case .failed(.cleanup(let finalFailure)) = finalSnapshot.state else {
            XCTFail("run finalization replaced the cleanup failure: \(finalSnapshot.state)")
            return
        }
        XCTAssertEqual(finalFailure, quitFailure)
        XCTAssertEqual(process.terminateCount, 1)
    }

    func testQuitEscalatesFromTermToKillWhenChildIgnoresTerm() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = FakeManagedProcess(running: true, ignoresTermination: true)
        let launcher = FakeLauncher(processes: [process])
        let healthFactory = FakeHealthFactory { requestID, instanceID in
            RuntimeResponse(
                requestID: requestID,
                instanceID: instanceID,
                state: "ready",
                protocolVersion: nil,
                error: nil
            )
        }
        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: "/tmp/hidhogg-runtime",
                configurationPath: "/tmp/hidhogg-test.toml",
                readinessTimeoutNanoseconds: 2_000_000,
                readinessPollNanoseconds: 1_000_000,
                terminateGraceNanoseconds: 2_000_000,
                killGraceNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root),
            launcher: launcher,
            clock: SystemHidhoggClock(),
            requestIDProvider: FixedRequestIDProvider(),
            instanceIDProvider: FixedUUIDProvider(),
            healthClientFactory: healthFactory,
            socketIdentityValidator: FixedSocketIdentityValidator()
        )

        let runTask = Task { await supervisor.run() }
        for _ in 0..<100 {
            let snapshot = await supervisor.snapshot()
            if snapshot.state == .ready { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let readySnapshot = await supervisor.snapshot()
        XCTAssertEqual(readySnapshot.state, .ready)
        await supervisor.quit()
        await runTask.value

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.forceTerminateCount, 1)
    }

    private func makeTemporaryRoot() throws -> URL {
        for _ in 0..<32 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let root = URL(fileURLWithPath: "/private/tmp/hh-\(suffix)", isDirectory: true)
            let result = root.path.withCString { Darwin.mkdir($0, 0o700) }
            guard result != 0 else {
                let maximumGenerationName = "hidhogg-\(geteuid())-\(String(repeating: "f", count: 36))"
                let maximumSocketPath = root
                    .appendingPathComponent(maximumGenerationName, isDirectory: true)
                    .appendingPathComponent("runtime.sock")
                    .path
                XCTAssertTrue(root.path.hasPrefix("/private/tmp/"))
                XCTAssertLessThanOrEqual(maximumSocketPath.utf8.count + 1, PathSecurity.unixPathBytes)
                return root
            }
            if errno != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        throw NSError(domain: "HidhoggTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not allocate a short test root"])
    }
}

private actor RecordingClock: HidhoggClock {
    private var sleeps: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
    }

    func recordedSleeps() -> [UInt64] {
        sleeps
    }
}

private actor ReadyThenGatedClock: HidhoggClock {
    private var sleepCount = 0
    private var gateReleased = false
    private var isGated = false
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(nanoseconds: UInt64) async throws {
        sleepCount += 1
        guard sleepCount > 1, !gateReleased else { return }
        isGated = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
        }
    }

    func waitUntilGated() async {
        while !isGated {
            await Task.yield()
        }
    }

    func release() {
        gateReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FixedUUIDProvider: UUIDProviding, Sendable {
    static let value = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    func makeUUID() -> UUID { Self.value }
}

private final class SequenceUUIDProvider: @unchecked Sendable, UUIDProviding {
    private let lock = NSLock()
    private let values: [UUID]
    private var index = 0

    init(values: [UUID]) {
        self.values = values
    }

    func makeUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private struct FixedRequestIDProvider: RequestIDProviding, Sendable {
    func makeRequestID() -> String { "11111111-1111-4111-8111-111111111111" }
}

private struct FixedSocketIdentityValidator: SocketIdentityValidating, Sendable {
    private static let identity = FileIdentity(device: 1, inode: 1)

    func validateSocket(_ socket: URL) throws -> FileIdentity {
        Self.identity
    }
}

private final class FakeManagedProcess: @unchecked Sendable, ManagedProcess {
    private let lock = NSLock()
    private var runningStorage: Bool
    private let exitStorage: ProcessExit?
    private let ignoresTermination: Bool
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0

    init(running: Bool, exit: ProcessExit? = nil, ignoresTermination: Bool = false) {
        runningStorage = running
        exitStorage = exit
        self.ignoresTermination = ignoresTermination
    }

    var processIdentifier: Int32 { 42 }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage
    }

    var exit: ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage ? nil : exitStorage
    }

    func terminate() {
        lock.lock()
        terminateCount += 1
        if !ignoresTermination {
            runningStorage = false
        }
        lock.unlock()
    }

    func forceTerminate() {
        lock.lock()
        forceTerminateCount += 1
        runningStorage = false
        lock.unlock()
    }
}

private final class FakeLauncher: @unchecked Sendable, ProcessLaunching {
    private let lock = NSLock()
    private let processes: [FakeManagedProcess]
    private let onLaunch: (@Sendable (LaunchRequest) throws -> Void)?
    private(set) var requests: [LaunchRequest] = []
    private var nextProcess = 0

    init(
        processes: [FakeManagedProcess],
        onLaunch: (@Sendable (LaunchRequest) throws -> Void)? = nil
    ) {
        self.processes = processes
        self.onLaunch = onLaunch
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard nextProcess < processes.count else {
            throw FakeLauncherError.exhausted
        }
        try onLaunch?(request)
        requests.append(request)
        let process = processes[nextProcess]
        nextProcess += 1
        return process
    }
}

private final class StderrSequenceLauncher: @unchecked Sendable, ProcessLaunching {
    private let lock = NSLock()
    private let outputs: [String]
    private var nextOutput = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard nextOutput < outputs.count else {
            throw FakeLauncherError.exhausted
        }
        let output = outputs[nextOutput]
        nextOutput += 1
        standardErrorTail.append(Data(output.utf8))
        return FakeManagedProcess(running: false, exit: .exit(status: 1))
    }
}

private enum FakeLauncherError: Error {
    case exhausted
}

private final class FailingLauncher: @unchecked Sendable, ProcessLaunching {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let onLaunch: (@Sendable (LaunchRequest) throws -> Void)?
    private(set) var requests: [LaunchRequest] = []

    init(
        failures: Int,
        onLaunch: (@Sendable (LaunchRequest) throws -> Void)? = nil
    ) {
        remainingFailures = failures
        self.onLaunch = onLaunch
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else {
            throw FakeLauncherError.exhausted
        }
        remainingFailures -= 1
        try onLaunch?(request)
        requests.append(request)
        throw NSError(domain: "HidhoggTests", code: 1)
    }
}

private final class FakeHealthFactory: @unchecked Sendable, RuntimeHealthClientCreating {
    private let response: (String, String) -> RuntimeResponse

    init(response: @escaping (String, String) -> RuntimeResponse) {
        self.response = response
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeHealthChecking {
        FakeHealthClient(instanceID: instanceID, response: response)
    }
}

private final class FakeHealthClient: @unchecked Sendable, RuntimeHealthChecking {
    private let instanceID: String
    private let response: (String, String) -> RuntimeResponse

    init(instanceID: String, response: @escaping (String, String) -> RuntimeResponse) {
        self.instanceID = instanceID
        self.response = response
    }

    func health(requestID: String) throws -> RuntimeResponse {
        response(requestID, instanceID)
    }
}

private final class SubstitutingHealthFactory: @unchecked Sendable, RuntimeHealthClientCreating {
    private let coordinator: SocketSubstitutionCoordinator

    init(coordinator: SocketSubstitutionCoordinator) {
        self.coordinator = coordinator
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeHealthChecking {
        SubstitutingHealthClient(coordinator: coordinator, instanceID: instanceID)
    }
}

private final class SubstitutingHealthClient: @unchecked Sendable, RuntimeHealthChecking {
    private let coordinator: SocketSubstitutionCoordinator
    private let instanceID: String

    init(coordinator: SocketSubstitutionCoordinator, instanceID: String) {
        self.coordinator = coordinator
        self.instanceID = instanceID
    }

    func health(requestID: String) throws -> RuntimeResponse {
        try coordinator.substituteSocket()
        return RuntimeResponse(
            requestID: requestID,
            instanceID: instanceID,
            state: "starting",
            protocolVersion: nil,
            error: nil
        )
    }
}

private final class SocketSubstitutionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    private var originalDescriptor: Int32?
    private var replacementDescriptor: Int32?

    func installSocket(at path: String) throws {
        let descriptor = try makeUnixSocket(at: path)
        lock.lock()
        self.path = path
        originalDescriptor = descriptor
        lock.unlock()
    }

    func substituteSocket() throws {
        lock.lock()
        guard let path, let descriptor = originalDescriptor, replacementDescriptor == nil else {
            lock.unlock()
            throw NSError(domain: "HidhoggTests", code: 3)
        }
        originalDescriptor = nil
        lock.unlock()

        _ = Darwin.close(descriptor)
        guard Darwin.unlink(path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let replacement = try makeUnixSocket(at: path)
        lock.lock()
        replacementDescriptor = replacement
        lock.unlock()
    }

    func replacementExists() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func validateReplacement() throws {
        lock.lock()
        let path = self.path
        lock.unlock()
        guard let path else { throw NSError(domain: "HidhoggTests", code: 4) }
        _ = try PathSecurity.validateSocket(URL(fileURLWithPath: path))
    }

    func cleanup() {
        lock.lock()
        let path = self.path
        let original = originalDescriptor
        let replacement = replacementDescriptor
        self.path = nil
        originalDescriptor = nil
        replacementDescriptor = nil
        lock.unlock()

        if let original { _ = Darwin.close(original) }
        if let replacement { _ = Darwin.close(replacement) }
        if let path {
            _ = path.withCString { Darwin.unlink($0) }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeUnixSocket(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for offset in 0..<rawBuffer.count {
                rawBuffer[offset] = 0
            }
            for (offset, byte) in pathBytes.enumerated() where offset < rawBuffer.count - 1 {
                rawBuffer[offset] = byte
            }
        }

        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        guard Darwin.chmod(path, 0o600) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return descriptor
    }
}
