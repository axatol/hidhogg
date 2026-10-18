import Foundation
import Darwin

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
    case cleanup(String)
    case restartExhausted
    case internalFailure

    public var description: String {
        switch self {
        case .cleanup(let message): return "runtime generation cleanup failed: \(bounded(message))"
        case .restartExhausted: return "runtime failed after one restart"
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
}
