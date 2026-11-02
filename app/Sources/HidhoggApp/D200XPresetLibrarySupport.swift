import Darwin
import Foundation
import HidhoggDomain

struct D200XPresetAssignmentContext: Hashable, Sendable, Identifiable {
    var id: Self { self }

    enum Target: Hashable, Sendable {
        case control(D200XControl)
        case dialRotation(Int)
    }

    let target: Target
    let applicationID: String?

    init(control: D200XControl, applicationID: String?) {
        if control.gesture == .left || control.gesture == .right {
            target = .dialRotation(control.wireIndex - 17)
        } else {
            target = .control(control)
        }
        self.applicationID = applicationID
    }

    var isDialRotation: Bool {
        if case .dialRotation = target { return true }
        return false
    }

    var control: D200XControl? {
        guard case .control(let control) = target else { return nil }
        return control
    }

    var dialIndex: Int? {
        guard case .dialRotation(let index) = target else { return nil }
        return index
    }

    func matches(control: D200XControl, applicationID: String?) -> Bool {
        guard self.applicationID == applicationID else { return false }
        switch target {
        case .control(let captured):
            return control == captured
        case .dialRotation(let index):
            return control.gesture != nil && control.wireIndex == 17 + index
        }
    }
}

struct D200XPresetImportPackage: Sendable {
    enum Package: Sendable {
        case tile(D200XTilePresetPackage)
        case dialRotation(D200XDialRotationPresetPackage)
    }

    enum Failure: LocalizedError {
        case invalidPackage

        var errorDescription: String? {
            "The preset package is invalid, incomplete or too large."
        }
    }

    static let maximumBytes = D200XTilePresetPackage.maximumBytes

    let package: Package

    var name: String {
        switch package {
        case .tile(let package): package.preset.name
        case .dialRotation(let package): package.preset.name
        }
    }

    static func read(from url: URL, assetDirectory: URL) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalidPackage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              info.st_size <= off_t(maximumBytes) else {
            throw Failure.invalidPackage
        }

        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.invalidPackage }
        return try decode(data, assetDirectory: assetDirectory)
    }

    static func decode(_ data: Data, assetDirectory: URL) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidPackage
        }

        if let kind = object["kind"] {
            guard kind as? String == "dial_rotation" else { throw Failure.invalidPackage }
            return Self(package: .dialRotation(try D200XDialRotationPresetPackage.decode(data)))
        }

        return Self(package: .tile(try D200XTilePresetPackage.decode(data, assetDirectory: assetDirectory)))
    }
}

enum D200XPresetIdentifier {
    static func generated() -> String {
        "preset-\(UUID().uuidString.lowercased())"
    }
}

struct D200XPresetActionPresentation: Equatable {
    let summary: String
    let systemSymbol: String

    init(binding: D200XBinding?, actions: [String: ConfiguredExecutable], nativeActions: [String: NativeAction]) {
        let draft = D200XPresetActionDraft(binding: binding, actions: actions, nativeActions: nativeActions)
        summary = draft.summary
        systemSymbol = draft.systemSymbol
    }
}
