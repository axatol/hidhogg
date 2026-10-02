import Darwin
import Foundation

public struct DefaultConfigurationBootstrap: Sendable {
    public enum Target: Equatable, Sendable {
        case selected(path: String)
        case defaultConfiguration(path: String)
        case invalidSelectedPath(path: String)

        public var path: String {
            switch self {
            case .selected(let path), .defaultConfiguration(let path), .invalidSelectedPath(let path):
                path
            }
        }
    }

    private let xdgConfigHome: String?
    private let homeDirectory: URL
    private let templateData: Data

    public init(xdgConfigHome: String?, homeDirectory: URL, templateData: Data) {
        self.xdgConfigHome = xdgConfigHome
        self.homeDirectory = homeDirectory
        self.templateData = templateData
    }

    public func resolve(persistedSelectedPath: String?) -> Target {
        if let persistedSelectedPath {
            guard let validPath = AppPreferences.validConfigurationPath(persistedSelectedPath) else {
                return .invalidSelectedPath(path: persistedSelectedPath)
            }
            return .selected(path: validPath)
        }

        let configurationHome = AppPreferences.validConfigurationPath(xdgConfigHome)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
        let configurationPath = configurationHome
            .appendingPathComponent("hidhogg", isDirectory: true)
            .appendingPathComponent("config.toml")
            .path

        return .defaultConfiguration(path: configurationPath)
    }

    public func prepare(_ target: Target) throws {
        switch target {
        case .selected:
            return
        case .invalidSelectedPath(let path):
            throw DefaultConfigurationBootstrapError.invalidSelectedPath(path: path)
        case .defaultConfiguration(let path):
            try createDefaultConfiguration(at: path)
        }
    }

    private func createDefaultConfiguration(at path: String) throws {
        let configurationURL = URL(fileURLWithPath: path)
        let configurationDirectory = configurationURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: configurationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DefaultConfigurationBootstrapError.directoryCreationFailed(
                path: path,
                reason: error.localizedDescription
            )
        }

        if try hasExistingConfigurationEntry(at: path) { return }
        guard !templateData.isEmpty else {
            throw DefaultConfigurationBootstrapError.templateUnavailable(path: path)
        }

        try stageAndPublishTemplate(at: path, in: configurationDirectory)
    }

    private func hasExistingConfigurationEntry(at path: String) throws -> Bool {
        var entryInformation = stat()
        let entryResult = path.withCString { Darwin.lstat($0, &entryInformation) }
        guard entryResult == 0 else {
            let entryError = errno
            if entryError == ENOENT { return false }
            throw DefaultConfigurationBootstrapError.fileCreationFailed(
                path: path,
                reason: Self.errorDescription(for: entryError)
            )
        }

        guard (entryInformation.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) else { return true }
        let targetResult = path.withCString { Darwin.access($0, F_OK) }
        guard targetResult == 0 else {
            let targetError = errno
            let reason = targetError == ENOENT || targetError == ENOTDIR
                ? "The configuration path is a dangling symbolic link."
                : Self.errorDescription(for: targetError)
            throw DefaultConfigurationBootstrapError.fileCreationFailed(path: path, reason: reason)
        }

        return true
    }

    private func stageAndPublishTemplate(at path: String, in directory: URL) throws {
        let temporaryURL = directory.appendingPathComponent(".config.toml.XXXXXX")
        var temporaryPathBytes = Array(temporaryURL.path.utf8CString)
        let temporaryFile = temporaryPathBytes.withUnsafeMutableBufferPointer {
            buffer -> (descriptor: Int32, path: String?) in
            guard let baseAddress = buffer.baseAddress else { return (-1, nil) }
            let descriptor = Darwin.mkstemp(baseAddress)
            guard descriptor >= 0 else { return (descriptor, nil) }
            return (descriptor, String(cString: baseAddress))
        }
        guard temporaryFile.descriptor >= 0, let temporaryPath = temporaryFile.path else {
            let createError = errno
            throw DefaultConfigurationBootstrapError.fileCreationFailed(
                path: path,
                reason: Self.errorDescription(for: createError)
            )
        }
        let descriptor = temporaryFile.descriptor
        var descriptorNeedsClose = true
        defer {
            if descriptorNeedsClose { _ = Darwin.close(descriptor) }
            _ = temporaryPath.withCString { Darwin.unlink($0) }
        }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let permissionError = errno
            throw DefaultConfigurationBootstrapError.fileWriteFailed(
                path: path,
                reason: Self.errorDescription(for: permissionError)
            )
        }

        let writeError = templateData.withUnsafeBytes { buffer -> Int32? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    let currentError = errno
                    if currentError == EINTR { continue }
                    return currentError
                }
                if written == 0 { return EIO }
                offset += written
            }
            return nil
        }
        if let writeError {
            throw DefaultConfigurationBootstrapError.fileWriteFailed(
                path: path,
                reason: Self.errorDescription(for: writeError)
            )
        }

        guard fsync(descriptor) == 0 else {
            let syncError = errno
            throw DefaultConfigurationBootstrapError.fileWriteFailed(
                path: path,
                reason: Self.errorDescription(for: syncError)
            )
        }

        let closeResult = Darwin.close(descriptor)
        let closeError = errno
        descriptorNeedsClose = false
        guard closeResult == 0 else {
            throw DefaultConfigurationBootstrapError.fileWriteFailed(
                path: path,
                reason: Self.errorDescription(for: closeError)
            )
        }

        let linkResult = temporaryPath.withCString { temporaryPath in
            path.withCString { finalPath in
                Darwin.link(temporaryPath, finalPath)
            }
        }
        guard linkResult == 0 else {
            let linkError = errno
            if linkError == EEXIST {
                if try hasExistingConfigurationEntry(at: path) { return }
            }
            throw DefaultConfigurationBootstrapError.fileCreationFailed(
                path: path,
                reason: Self.errorDescription(for: linkError)
            )
        }
    }

    private static func errorDescription(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

public enum DefaultConfigurationBootstrapError: Error, LocalizedError, Equatable, Sendable {
    case invalidSelectedPath(path: String)
    case templateUnavailable(path: String)
    case directoryCreationFailed(path: String, reason: String)
    case fileCreationFailed(path: String, reason: String)
    case fileWriteFailed(path: String, reason: String)

    public var path: String {
        switch self {
        case .invalidSelectedPath(let path),
             .templateUnavailable(let path),
             .directoryCreationFailed(let path, _),
             .fileCreationFailed(let path, _),
             .fileWriteFailed(let path, _):
            path
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSelectedPath:
            "The saved configuration path is not a valid absolute path."
        case .templateUnavailable:
            "The bundled default configuration template is unavailable."
        case .directoryCreationFailed(_, let reason):
            "Could not create the configuration directory: \(reason)"
        case .fileCreationFailed(_, let reason):
            "Could not create the configuration file: \(reason)"
        case .fileWriteFailed(_, let reason):
            "Could not write the configuration file: \(reason)"
        }
    }
}
