import Foundation
import HidhoggDomain

public struct FileRevision: Equatable, Sendable {
    public let exists: Bool
    private let contents: Data?
    private let references: [String: Data]
    var rootContents: Data? { contents }
    var referencedContents: [String: Data] { references }

    init(contents: Data?, references: [String: Data] = [:]) {
        self.references = references
        self.exists = contents != nil
        self.contents = contents
    }

    public static let missing = Self(contents: nil)
}

public struct ConfigurationSnapshot: Equatable, Sendable {
    public let configuration: AppConfiguration
    public let revision: FileRevision
    public let workspace: WorkspaceConfiguration

    public init(configuration: AppConfiguration, revision: FileRevision) {
        self.workspace = WorkspaceConfiguration(legacy: configuration)
        self.configuration = configuration
        self.revision = revision
    }

    public init(workspace: WorkspaceConfiguration, revision: FileRevision) {
        self.workspace = workspace
        self.configuration = workspace.configuration
        self.revision = revision
    }
}
