import Foundation
import HidhoggDomain

public struct FileRevision: Equatable, Sendable {
    public let exists: Bool
    private let contents: Data?

    init(contents: Data?) {
        self.exists = contents != nil
        self.contents = contents
    }

    public static let missing = Self(contents: nil)
}

public struct ConfigurationSnapshot: Equatable, Sendable {
    public let configuration: AppConfiguration
    public let revision: FileRevision

    public init(configuration: AppConfiguration, revision: FileRevision) {
        self.configuration = configuration
        self.revision = revision
    }
}
