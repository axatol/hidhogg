import Foundation

public struct NativeAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case media, volume, bell, playSound = "play_sound", openApplication = "open_application"
        case openFile = "open_file", openURL = "open_url", deckNotification = "deck_notification", shortcut
    }
    public enum Media: String, Codable, CaseIterable, Sendable { case playPause = "play_pause", nextTrack = "next_track", previousTrack = "previous_track" }
    public enum Volume: String, Codable, CaseIterable, Sendable { case up, down, mute, set }
    public var kind: Kind
    public var media: Media?
    public var volume: Volume?
    public var percent: Int?
    public var target: String?
    public var topic: String?
    public var text: String?
    public var appID: String?
    public var ttlSeconds: Int?
    public var shortcut: KeyboardShortcut?

    public init(kind: Kind, media: Media? = nil, volume: Volume? = nil, percent: Int? = nil,
                target: String? = nil, topic: String? = nil, text: String? = nil, appID: String? = nil,
                ttlSeconds: Int? = nil,
                shortcut: KeyboardShortcut? = nil) {
        self.kind = kind
        self.media = media
        self.volume = volume
        self.percent = percent
        self.target = target
        self.topic = topic
        self.text = text
        self.appID = appID
        self.ttlSeconds = ttlSeconds
        self.shortcut = shortcut
    }

    public func validated() throws -> Self {
        let fields: Set<String> = Set([
            media.map { _ in "media" }, volume.map { _ in "volume" }, percent.map { _ in "percent" },
            target.map { _ in "target" }, topic.map { _ in "topic" }, text.map { _ in "text" },
            appID.map { _ in "appID" }, ttlSeconds.map { _ in "ttlSeconds" }, shortcut.map { _ in "shortcut" }
        ].compactMap { $0 })
        let valid: Bool
        switch kind {
        case .media: valid = fields == ["media"]
        case .volume:
            valid = volume == .set ? fields == ["volume", "percent"] && percent.map({ (0...100).contains($0) }) == true : fields == ["volume"]
        case .bell: valid = fields.isEmpty
        case .playSound, .openFile, .openApplication:
            valid = fields == ["target"] && target.map { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 } == true
                && (kind != .openApplication || target?.lowercased().hasSuffix(".app") == true)
        case .openURL:
            valid = fields == ["target"] && target.map { value in
                guard value.utf8.count <= 4096, !value.contains("\0"), let url = URLComponents(string: value),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return false }
                return !host.isEmpty && url.user == nil && url.password == nil
            } == true
        case .deckNotification:
            valid = fields.isSubset(of: ["topic", "text", "appID", "ttlSeconds"])
                && topic.map(NotificationTopic.isValidTopic) == true
                && (text != nil || appID != nil)
                && (text.map(Self.isValidNotificationText) ?? true)
                && (appID.map(Self.isValidBundleIdentifier) ?? true)
                && (ttlSeconds.map { (1...86_400).contains($0) } ?? true)
        case .shortcut:
            valid = fields == ["shortcut"] && shortcut.map { ConfigurationValueValidation.isValid(binding: .key($0)) } == true
        }
        guard valid else { throw ConfigurationValidationError.invalidD200XAction }
        return self
    }

    private static func isValidNotificationText(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= 64, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && ![0x85, 0x2028, 0x2029, 0x061C, 0x200E, 0x200F,
                0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        }
    }

    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 255, components.count >= 2 else { return false }
        return components.allSatisfy { component in
            guard let first = component.utf8.first, isASCIIAlphanumeric(first) else { return false }
            return component.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == 45 }
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private enum CodingKeys: String, CodingKey { case kind, media, volume, percent, target, topic, text, appID, ttlSeconds, shortcut }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
            media: try c.decodeIfPresent(Media.self, forKey: .media),
            volume: try c.decodeIfPresent(Volume.self, forKey: .volume),
            percent: try c.decodeIfPresent(Int.self, forKey: .percent),
            target: try c.decodeIfPresent(String.self, forKey: .target),
            topic: try c.decodeIfPresent(String.self, forKey: .topic),
            text: try c.decodeIfPresent(String.self, forKey: .text),
            appID: try c.decodeIfPresent(String.self, forKey: .appID),
            ttlSeconds: try c.decodeIfPresent(Int.self, forKey: .ttlSeconds),
            shortcut: try c.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut))
        let allowed: Set<String>
        switch kind {
        case .media: allowed = ["kind", "media"]
        case .volume: allowed = volume == .set ? ["kind", "volume", "percent"] : ["kind", "volume"]
        case .bell: allowed = ["kind"]
        case .playSound, .openFile, .openApplication, .openURL: allowed = ["kind", "target"]
        case .deckNotification: allowed = ["kind", "topic", "text", "appID", "ttlSeconds"]
        case .shortcut: allowed = ["kind", "shortcut"]
        }
        let fields = try decoder.container(keyedBy: FieldKey.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw ConfigurationValidationError.invalidD200XAction }
        if shortcut != nil {
            let nested = try c.superDecoder(forKey: .shortcut).container(keyedBy: FieldKey.self)
            guard Set(nested.allKeys.map(\.stringValue)).isSubset(of: ["keyCode", "modifiers"]) else {
                throw ConfigurationValidationError.invalidD200XAction
            }
        }
        _ = try validated()
    }
}
