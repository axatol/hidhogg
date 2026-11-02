import Darwin
import Foundation
import HidhoggDomain

struct D200XDialRotationPresetPackage: Codable, Equatable, Sendable {
    static let maximumBytes = 256 * 1024
    var kind: String = "dial_rotation"
    var version: Int = 1
    var preset: D200XDialRotationPreset

    func validated() throws -> Self {
        guard kind == "dial_rotation", version == 1 else { throw D200XTilePresetPackage.Failure.invalidPackage }
        _ = try preset.validated()
        return self
    }

    static func read(from url: URL) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw D200XTilePresetPackage.Failure.invalidPackage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= off_t(maximumBytes) else {
            throw D200XTilePresetPackage.Failure.invalidPackage
        }
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["kind", "version", "preset"],
              let preset = object["preset"] as? [String: Any] else {
            throw D200XTilePresetPackage.Failure.invalidPackage
        }
        try validateKeys(preset, allowed: ["name", "left", "right", "actions", "nativeActions"])
        try validateBinding(preset["left"])
        try validateBinding(preset["right"])
        if let value = preset["actions"] {
            guard let actions = value as? [String: Any] else { throw D200XTilePresetPackage.Failure.invalidPackage }
            for action in actions.values {
                try validateKeys(action, allowed: ["executable", "arguments", "workingDirectory", "timeoutSeconds"])
            }
        }
        if let value = preset["nativeActions"] {
            guard let actions = value as? [String: Any] else { throw D200XTilePresetPackage.Failure.invalidPackage }
            for action in actions.values {
                try validateKeys(action, allowed: ["kind", "media", "volume", "percent", "target", "topic", "text", "appID", "ttlSeconds", "shortcut"])
                if let shortcut = (action as? [String: Any])?["shortcut"] {
                    try validateKeys(shortcut, allowed: ["keyCode", "modifiers"])
                }
            }
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw D200XTilePresetPackage.Failure.invalidPackage }
        return data
    }

    private static func validateBinding(_ value: Any?) throws {
        try validateKeys(value, allowed: ["kind", "shortcut", "actionID"])
        if let shortcut = (value as? [String: Any])?["shortcut"] {
            try validateKeys(shortcut, allowed: ["keyCode", "modifiers"])
        }
    }

    private static func validateKeys(_ value: Any?, allowed: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
            throw D200XTilePresetPackage.Failure.invalidPackage
        }
    }
}
