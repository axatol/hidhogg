import Foundation
import HidhoggDomain
import Darwin

struct D200XTilePresetPackage: Codable, Equatable, Sendable {
    static let maximumBytes = 24 * 1024 * 1024
    var version: Int = 1
    var preset: D200XTilePreset
    var image: Data?

    enum Failure: LocalizedError {
        case invalidPackage
        case actionConflict
        case duplicatePreset
        case presetChanged

        var errorDescription: String? {
            switch self {
            case .invalidPackage: "The preset package is invalid, incomplete or too large."
            case .actionConflict: "An action with this ID already exists with different settings. Import appearance only or rename the action first."
            case .duplicatePreset: "Choose a unique preset ID."
            case .presetChanged: "This preset changed or was removed while you were editing. Reload it before saving."
            }
        }
    }

    func validated(assetDirectory: URL) throws -> Self {
        guard version == 1 || version == 2, version == 2 || preset.nativeActions.isEmpty else { throw Failure.invalidPackage }
        _ = try preset.validated()
        if let reference = preset.appearance.imageAsset {
            guard let image else { throw Failure.invalidPackage }
            try D200XAssetStore(directory: assetDirectory).validateAsset(image, reference: reference)
        } else if image != nil { throw Failure.invalidPackage }
        return self
    }

    static func read(from url: URL, assetDirectory: URL) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.invalidPackage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= off_t(maximumBytes) else { throw Failure.invalidPackage }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.invalidPackage }
        return try decode(data, assetDirectory: assetDirectory)
    }

    static func decode(_ data: Data, assetDirectory: URL) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "preset", "image"]) else { throw Failure.invalidPackage }
        try validateKeys(object["preset"], allowed: ["name", "appearance", "binding", "actions", "nativeActions"])
        guard let preset = object["preset"] as? [String: Any] else { throw Failure.invalidPackage }
        try validateKeys(preset["appearance"], allowed: ["label", "backgroundHex", "imageAsset", "titleSize", "titleColorHex", "titlePlacement", "titleAlignment", "showTitle"])
        if let binding = preset["binding"] {
            try validateKeys(binding, allowed: ["kind", "shortcut", "actionID"])
            if let shortcut = (binding as? [String: Any])?["shortcut"] {
                try validateKeys(shortcut, allowed: ["keyCode", "modifiers"])
            }
        }
        if let actions = preset["actions"] as? [String: Any] {
            for action in actions.values {
                try validateKeys(action, allowed: ["executable", "arguments", "workingDirectory", "timeoutSeconds"])
            }
        }
        if let actions = preset["nativeActions"] as? [String: Any] {
            for action in actions.values {
                try validateKeys(action, allowed: ["kind", "media", "volume", "percent", "target", "topic", "text", "ttlSeconds", "shortcut"])
                if let shortcut = (action as? [String: Any])?["shortcut"] {
                    try validateKeys(shortcut, allowed: ["keyCode", "modifiers"])
                }
            }
        }
        return try JSONDecoder().decode(Self.self, from: data).validated(assetDirectory: assetDirectory)
    }

    private static func validateKeys(_ value: Any?, allowed: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
            throw Failure.invalidPackage
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.invalidPackage }
        return data
    }
}
