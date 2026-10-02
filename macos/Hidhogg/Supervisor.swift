import Foundation
import Darwin

public protocol HidhoggClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct SystemHidhoggClock: HidhoggClock, Sendable {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public protocol UUIDProviding: Sendable {
    func makeUUID() -> UUID
}

public struct SystemUUIDProvider: UUIDProviding, Sendable {
    public init() {}

    public func makeUUID() -> UUID { UUID() }
}

public protocol RequestIDProviding: Sendable {
    func makeRequestID() -> String
}

public struct SystemRequestIDProvider: RequestIDProviding, Sendable {
    public init() {}

    public func makeRequestID() -> String {
        UUID().uuidString.lowercased()
    }
}

public struct GenerationDirectory: Equatable, Sendable {
    public let directory: URL
    public let socket: URL
    public let directoryIdentity: FileIdentity
    public let instanceID: String

    public init(directory: URL, directoryIdentity: FileIdentity, instanceID: String) {
        self.directory = directory
        self.socket = directory.appendingPathComponent("runtime.sock")
        self.directoryIdentity = directoryIdentity
        self.instanceID = instanceID
    }
}

public protocol GenerationDirectoryCreating: Sendable {
    func create(instanceID: String) throws -> GenerationDirectory
}

public protocol SocketIdentityValidating: Sendable {
    func validateSocket(_ socket: URL) throws -> FileIdentity
}

public struct PathSecuritySocketIdentityValidator: SocketIdentityValidating, Sendable {
    public init() {}

    public func validateSocket(_ socket: URL) throws -> FileIdentity {
        try PathSecurity.validateSocket(socket)
    }
}

public struct DefaultGenerationDirectoryFactory: GenerationDirectoryCreating, Sendable {
    public static let productionRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    public let root: URL
    public let rootPolicy: GenerationRootPolicy
    private let uuidProvider: any UUIDProviding

    public init(
        root: URL = DefaultGenerationDirectoryFactory.productionRoot,
        uuidProvider: any UUIDProviding = SystemUUIDProvider(),
        rootPolicy: GenerationRootPolicy? = nil
    ) {
        self.root = root
        self.rootPolicy = rootPolicy ?? (root.path == Self.productionRoot.path ? .productionPrivateTemporary : .injected)
        self.uuidProvider = uuidProvider
    }

    public func create(instanceID: String) throws -> GenerationDirectory {
        guard UUIDValidation.isCanonical(instanceID) else {
            throw SupervisorError.invalidInstanceID
        }
        let name = "hidhogg-\(geteuid())-\(uuidProvider.makeUUID().uuidString.lowercased())"
        let socketPath = root.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("runtime.sock")
            .path
        try PathSecurity.validateEncodedSocketPath(socketPath)
        let rootIdentity = try PathSecurity.validateGenerationRoot(root, policy: rootPolicy)
        let result = try PathSecurity.createGenerationDirectory(root: root, directoryName: name)
        guard try PathSecurity.validateGenerationRoot(root, policy: rootPolicy) == rootIdentity else {
            _ = try? PathSecurity.removeMatchingGeneration(
                directory: result.url,
                directoryIdentity: result.identity,
                socket: result.url.appendingPathComponent("runtime.sock"),
                socketIdentity: nil
            )
            throw PathSecurityError.rootChanged
        }
        let generation = GenerationDirectory(
            directory: result.url,
            directoryIdentity: result.identity,
            instanceID: instanceID
        )
        return generation
    }
}

public enum LifecycleState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case configurationRequired
    case starting
    case ready
    case stopping
    case stopped
    case failed(SupervisorFailure)

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .configurationRequired: return "Configuration required"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed(let reason): return "Failed: \(reason.description)"
        }
    }
}

public enum SupervisorFailure: Equatable, Sendable, CustomStringConvertible {
    case launch(String)
    case cleanup(String)
    case readinessTimedOut
    case processExited(ProcessExit?)
    case restartExhausted
    case security(String)
    case internalFailure

    public var description: String {
        switch self {
        case .launch(let message): return bounded(message)
        case .cleanup(let message): return "runtime generation cleanup failed: \(bounded(message))"
        case .readinessTimedOut: return "runtime did not become ready"
        case .processExited(let exit):
            guard let exit else { return "runtime exited" }
            switch exit {
            case .exit(let status): return "runtime exited (status \(status))"
            case .signal(let signal): return "runtime terminated (signal \(signal))"
            }
        case .restartExhausted: return "runtime failed after one restart"
        case .security(let message): return bounded(message)
        case .internalFailure: return "runtime supervision failed"
        }
    }

    private func bounded(_ message: String) -> String {
        let scalars = Array(message)
        return String(scalars.prefix(160))
    }
}

public enum SupervisorError: Error, Equatable, Sendable {
    case invalidInstanceID
    case alreadyStarted
}

public struct SupervisorSnapshot: Equatable, Sendable {
    public let state: LifecycleState
    public let restartCount: Int
    public let instanceID: String?
    public let socketPath: String?
    public let lastFailureDetail: String?

    public init(
        state: LifecycleState,
        restartCount: Int,
        instanceID: String?,
        socketPath: String?,
        lastFailureDetail: String? = nil
    ) {
        self.state = state
        self.restartCount = restartCount
        self.instanceID = instanceID
        self.socketPath = socketPath
        self.lastFailureDetail = lastFailureDetail
    }
}

public struct ProcessSupervisorConfiguration: Sendable {
    public let executablePath: String
    public let configurationPath: String
    public let readinessTimeoutNanoseconds: UInt64
    public let readinessPollNanoseconds: UInt64
    public let restartDelayNanoseconds: UInt64
    public let terminateGraceNanoseconds: UInt64
    public let killGraceNanoseconds: UInt64

    public init(
        executablePath: String,
        configurationPath: String,
        readinessTimeoutNanoseconds: UInt64 = 5_000_000_000,
        readinessPollNanoseconds: UInt64 = 100_000_000,
        restartDelayNanoseconds: UInt64 = 500_000_000,
        terminateGraceNanoseconds: UInt64 = 2_000_000_000,
        killGraceNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.executablePath = executablePath
        self.configurationPath = configurationPath
        self.readinessTimeoutNanoseconds = readinessTimeoutNanoseconds
        self.readinessPollNanoseconds = readinessPollNanoseconds
        self.restartDelayNanoseconds = restartDelayNanoseconds
        self.terminateGraceNanoseconds = terminateGraceNanoseconds
        self.killGraceNanoseconds = killGraceNanoseconds
    }
}

public actor ProcessSupervisor {
    private let configuration: ProcessSupervisorConfiguration
    private let directoryFactory: any GenerationDirectoryCreating
    private let launcher: any ProcessLaunching
    private let clock: any HidhoggClock
    private let requestIDProvider: any RequestIDProviding
    private let instanceIDProvider: any UUIDProviding
    private let healthClientFactory: any RuntimeHealthClientCreating
    private let socketIdentityValidator: any SocketIdentityValidating

    private var state: LifecycleState = .idle
    private var restartCount = 0
    private var started = false
    private var quitRequested = false
    private var terminalCleanupFailure: String?
    private var currentProcess: (any ManagedProcess)?
    private var currentGeneration: GenerationDirectory?
    private var currentSocketIdentity: FileIdentity?
    private var stdoutTail: OutputTail?
    private var stderrTail: OutputTail?
    private var lastFailureDetail: String?

    private static let failureDetailCharacterLimit = 240
    private static let rawHIDCauseMarker = "D200X_HID_OPEN_PATH_CAUSE:"
    private static let safeHIDFailureMarker = "D200X_HID_OPEN_PATH_FAILED:"

    public init(
        configuration: ProcessSupervisorConfiguration,
        directoryFactory: any GenerationDirectoryCreating = DefaultGenerationDirectoryFactory(),
        launcher: any ProcessLaunching = FoundationProcessLauncher(),
        clock: any HidhoggClock = SystemHidhoggClock(),
        requestIDProvider: any RequestIDProviding = SystemRequestIDProvider(),
        instanceIDProvider: any UUIDProviding = SystemUUIDProvider(),
        healthClientFactory: any RuntimeHealthClientCreating = UnixSocketHealthClientFactory(),
        socketIdentityValidator: any SocketIdentityValidating = PathSecuritySocketIdentityValidator()
    ) {
        self.configuration = configuration
        self.directoryFactory = directoryFactory
        self.launcher = launcher
        self.clock = clock
        self.requestIDProvider = requestIDProvider
        self.instanceIDProvider = instanceIDProvider
        self.healthClientFactory = healthClientFactory
        self.socketIdentityValidator = socketIdentityValidator
    }

    public func snapshot() -> SupervisorSnapshot {
        SupervisorSnapshot(
            state: state,
            restartCount: restartCount,
            instanceID: currentGeneration?.instanceID,
            socketPath: currentGeneration?.socket.path,
            lastFailureDetail: lastFailureDetail
        )
    }

    public func run() async {
        guard !started else { return }
        started = true
        restartCount = 0
        guard !quitRequested else {
            state = .stopped
            return
        }
        state = .starting

        while !quitRequested {
            let outcome = await runGeneration()
            if outcome == .quit || quitRequested { break }
            if outcome == .terminalFailure { break }
            guard restartCount == 0 else {
                state = .failed(.restartExhausted)
                break
            }
            restartCount = 1
            do {
                try await clock.sleep(nanoseconds: configuration.restartDelayNanoseconds)
            } catch {
                if !quitRequested { state = .failed(.internalFailure) }
                break
            }
        }

        if quitRequested {
            state = .stopping
            await stopCurrentProcess()
            if let cleanupFailure = cleanupCurrentGeneration() {
                state = .failed(.cleanup(cleanupFailure))
            } else {
                state = .stopped
            }
        }
    }

    public func quit() async {
        quitRequested = true
        await stopCurrentProcess()
        if let cleanupFailure = cleanupCurrentGeneration() {
            state = .failed(.cleanup(cleanupFailure))
        } else if started {
            state = .stopped
        }
    }

    private enum GenerationOutcome: Equatable {
        case failed
        case terminalFailure
        case quit
    }

    private enum SocketIdentityObservation {
        case valid
        case unavailableBeforeCapture
        case terminalFailure
    }

    private func runGeneration() async -> GenerationOutcome {
        lastFailureDetail = nil
        let instanceID = instanceIDProvider.makeUUID().uuidString.lowercased()
        let generation: GenerationDirectory
        do {
            generation = try directoryFactory.create(instanceID: instanceID)
        } catch let error as PathSecurityError {
            state = .failed(.security(String(describing: error)))
            return .failed
        } catch {
            state = .failed(.launch(String(describing: error)))
            return .failed
        }
        currentGeneration = generation
        currentSocketIdentity = nil
        stdoutTail = OutputTail()
        stderrTail = OutputTail()

        let launchRequest = LaunchRequest(
            executablePath: configuration.executablePath,
            arguments: [
                "--socket-path", generation.socket.path,
                "--instance-id", generation.instanceID,
                "--config-path", configuration.configurationPath
            ]
        )
        let process: any ManagedProcess
        do {
            process = try launcher.launch(
                request: launchRequest,
                standardOutputTail: stdoutTail!,
                standardErrorTail: stderrTail!
            )
        } catch {
            let launchFailure = String(describing: error)
            if let cleanupFailure = cleanupCurrentGeneration() {
                state = .failed(.cleanup("launch failed: \(launchFailure); \(cleanupFailure)"))
                return .terminalFailure
            }
            state = .failed(.launch(launchFailure))
            return .failed
        }
        currentProcess = process

        let pollCount = max(1, Int(ceil(Double(configuration.readinessTimeoutNanoseconds) / Double(configuration.readinessPollNanoseconds))))
        for _ in 0..<pollCount {
            if quitRequested {
                await stopCurrentProcess()
                return finishQuitAfterCleanup()
            }
            do {
                try await clock.sleep(nanoseconds: configuration.readinessPollNanoseconds)
            } catch {
                if quitRequested {
                    await stopCurrentProcess()
                    return finishQuitAfterCleanup()
                }
                await stopCurrentProcess()
                return finishFailureAfterCleanup(.internalFailure)
            }
            guard process.isRunning else {
                return finishFailureAfterCleanup(.processExited(process.exit))
            }

            switch observeSocketIdentity(generation.socket) {
            case .valid:
                break
            case .unavailableBeforeCapture:
                continue
            case .terminalFailure:
                return await failForSocketSecurity()
            }

            let requestID = requestIDProvider.makeRequestID()
            let response: RuntimeResponse?
            do {
                let client = try healthClientFactory.make(
                    socketPath: generation.socket.path,
                    instanceID: generation.instanceID
                )
                response = try client.health(requestID: requestID)
            } catch {
                response = nil
            }

            switch observeSocketIdentity(generation.socket) {
            case .valid:
                break
            case .unavailableBeforeCapture, .terminalFailure:
                return await failForSocketSecurity()
            }

            guard let response,
                  process.isRunning,
                  response.requestID == requestID,
                  response.instanceID == generation.instanceID,
                  response.state == "ready" else {
                continue
            }
            state = .ready
            return await monitorReadyProcess(process)
        }

        await stopCurrentProcess()
        if quitRequested {
            return finishQuitAfterCleanup()
        }
        return finishFailureAfterCleanup(.readinessTimedOut)
    }

    private func observeSocketIdentity(_ socket: URL) -> SocketIdentityObservation {
        do {
            let observedIdentity = try socketIdentityValidator.validateSocket(socket)
            if let recordedIdentity = currentSocketIdentity {
                guard recordedIdentity == observedIdentity else {
                    return .terminalFailure
                }
            } else {
                currentSocketIdentity = observedIdentity
            }
            return .valid
        } catch {
            return currentSocketIdentity == nil ? .unavailableBeforeCapture : .terminalFailure
        }
    }

    private func failForSocketSecurity() async -> GenerationOutcome {
        await stopCurrentProcess()
        let cleanupFailure = cleanupCurrentGeneration()
        let message = cleanupFailure.map {
            "runtime socket identity unavailable or changed; \($0)"
        } ?? "runtime socket identity unavailable or changed"
        state = .failed(.security(message))
        return .terminalFailure
    }

    private func monitorReadyProcess(_ process: any ManagedProcess) async -> GenerationOutcome {
        while process.isRunning {
            if quitRequested {
                await stopCurrentProcess()
                return finishQuitAfterCleanup()
            }
            do {
                try await clock.sleep(nanoseconds: configuration.readinessPollNanoseconds)
            } catch {
                if quitRequested {
                    await stopCurrentProcess()
                    return finishQuitAfterCleanup()
                }
                await stopCurrentProcess()
                return finishFailureAfterCleanup(.internalFailure)
            }
            guard let generation = currentGeneration else {
                return await failForSocketSecurity()
            }
            switch observeSocketIdentity(generation.socket) {
            case .valid:
                break
            case .unavailableBeforeCapture, .terminalFailure:
                return await failForSocketSecurity()
            }
        }
        if quitRequested {
            return finishQuitAfterCleanup()
        }
        return finishFailureAfterCleanup(.processExited(process.exit))
    }

    private func finishFailureAfterCleanup(_ failure: SupervisorFailure) -> GenerationOutcome {
        if let cleanupFailure = cleanupCurrentGeneration() {
            state = .failed(.cleanup(cleanupFailure))
            return .terminalFailure
        }
        state = .failed(failure)
        return .failed
    }

    private func finishQuitAfterCleanup() -> GenerationOutcome {
        if let cleanupFailure = cleanupCurrentGeneration() {
            state = .failed(.cleanup(cleanupFailure))
            return .terminalFailure
        }
        return .quit
    }

    private func stopCurrentProcess() async {
        guard let process = currentProcess else { return }
        guard process.isRunning else {
            _ = process.exit
            currentProcess = nil
            return
        }
        currentProcess = nil
        state = .stopping
        process.terminate()
        await waitForProcess(process, nanoseconds: configuration.terminateGraceNanoseconds)
        if process.isRunning {
            process.forceTerminate()
            await waitForProcess(process, nanoseconds: configuration.killGraceNanoseconds)
        }
        if !process.isRunning {
            _ = process.exit
        }
    }

    private func waitForProcess(_ process: any ManagedProcess, nanoseconds: UInt64) async {
        let pollNanoseconds: UInt64 = 100_000_000
        let count = max(1, Int(ceil(Double(nanoseconds) / Double(pollNanoseconds))))
        for _ in 0..<count where process.isRunning {
            do {
                try await clock.sleep(nanoseconds: min(pollNanoseconds, nanoseconds))
            } catch {
                return
            }
        }
    }

    private func cleanupCurrentGeneration() -> String? {
        if let currentProcess, !currentProcess.isRunning {
            _ = currentProcess.exit
        }
        captureLastFailureDetail()
        guard let generation = currentGeneration else { return terminalCleanupFailure }
        let cleanupFailure: String?
        do {
            switch try PathSecurity.removeMatchingGeneration(
                directory: generation.directory,
                directoryIdentity: generation.directoryIdentity,
                socket: generation.socket,
                socketIdentity: currentSocketIdentity
            ) {
            case .removed, .alreadyAbsent:
                cleanupFailure = nil
            case .refused(let reason):
                cleanupFailure = "refused: \(String(describing: reason))"
            }
        } catch {
            cleanupFailure = String(describing: error)
        }
        currentProcess = nil
        currentGeneration = nil
        currentSocketIdentity = nil
        stdoutTail = nil
        stderrTail = nil
        guard let cleanupFailure else { return terminalCleanupFailure }
        let reportedFailure = "generation \(generation.directory.path): \(cleanupFailure)"
        if terminalCleanupFailure == nil {
            terminalCleanupFailure = reportedFailure
        }
        return terminalCleanupFailure
    }

    private func captureLastFailureDetail() {
        guard let stderrTail else { return }
        let output = stderrTail.text
        var safeLines: [String] = []
        for line in output.split(whereSeparator: { $0.isNewline }).reversed() {
            let scalars = line.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }
            let detail = String(String.UnicodeScalarView(scalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty,
                  !detail.contains(Self.rawHIDCauseMarker) else {
                continue
            }
            safeLines.append(detail)
        }
        guard let detail = safeLines.first(where: { $0.contains(Self.safeHIDFailureMarker) })
                ?? safeLines.first else { return }
        lastFailureDetail = String(detail.prefix(Self.failureDetailCharacterLimit))
    }
}
