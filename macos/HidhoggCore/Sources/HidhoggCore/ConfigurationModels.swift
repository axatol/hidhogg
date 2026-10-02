import Foundation

public struct HidhoggConfiguration: Sendable, Equatable {
    public let schemaVersion: Int
    public let adapter: String
    public let brightness: Int
    public let idleTimeoutSeconds: Int
    public let defaultProfileID: String
    public let profiles: [ConfiguredProfile]

    public static let supportedPositions: [PositionSpec] = [
        .init(name: "0_0", wireIndex: 0),
        .init(name: "1_0", wireIndex: 1),
        .init(name: "2_0", wireIndex: 2),
        .init(name: "3_0", wireIndex: 3),
        .init(name: "4_0", wireIndex: 4),
        .init(name: "0_1", wireIndex: 5),
        .init(name: "1_1", wireIndex: 6),
        .init(name: "2_1", wireIndex: 7),
        .init(name: "3_1", wireIndex: 8),
        .init(name: "4_1", wireIndex: 9),
        .init(name: "0_2", wireIndex: 10),
        .init(name: "1_2", wireIndex: 11),
        .init(name: "2_2", wireIndex: 12),
        .init(name: "3_2", wireIndex: 13, isWide: true),
    ]

    public func profile(id: String) -> ConfiguredProfile? {
        profiles.first { areByteEqual($0.id, id) }
    }
}

public struct PositionSpec: Sendable, Equatable {
    public let name: String
    public let wireIndex: UInt8
    public let isWide: Bool

    public init(name: String, wireIndex: UInt8, isWide: Bool = false) {
        self.name = name
        self.wireIndex = wireIndex
        self.isWide = isWide
    }
}

public struct ConfiguredProfile: Sendable, Equatable {
    public let id: String
    public let label: String
    public let positions: [ConfiguredPosition]

    public func position(named name: String) -> ConfiguredPosition? {
        positions.first { areByteEqual($0.position, name) }
    }

    public static func == (lhs: ConfiguredProfile, rhs: ConfiguredProfile) -> Bool {
        lhs.id == rhs.id && areByteEqual(lhs.label, rhs.label) && lhs.positions == rhs.positions
    }
}

public struct ConfiguredPosition: Sendable, Equatable {
    public let id: String
    public let position: String
    public let label: String
    public let background: String
    public let notificationSources: [String]?
    public let labelAlignment: String
    public let labelSize: Int
    public let action: ConfiguredAction?

    public static func == (lhs: ConfiguredPosition, rhs: ConfiguredPosition) -> Bool {
        lhs.id == rhs.id &&
            lhs.position == rhs.position &&
            areByteEqual(lhs.label, rhs.label) &&
            lhs.background == rhs.background &&
            lhs.notificationSources == rhs.notificationSources &&
            lhs.labelAlignment == rhs.labelAlignment &&
            lhs.labelSize == rhs.labelSize &&
            lhs.action == rhs.action
    }
}

public enum ButtonGesture: String, Sendable, Equatable {
    case press
    case release
}

public enum ConfiguredAction: Sendable, Equatable {
    case activateProfile(profileID: String, gesture: ButtonGesture)
    case execute(executable: String, arguments: [String], timeoutSeconds: Int, gesture: ButtonGesture)
    case typeText(text: String, gesture: ButtonGesture)
    case keyPress(key: String, gesture: ButtonGesture)

    public static func == (lhs: ConfiguredAction, rhs: ConfiguredAction) -> Bool {
        switch (lhs, rhs) {
        case let (.activateProfile(leftID, leftGesture), .activateProfile(rightID, rightGesture)):
            return leftID == rightID && leftGesture == rightGesture
        case let (.execute(leftPath, leftArguments, leftTimeout, leftGesture),
                  .execute(rightPath, rightArguments, rightTimeout, rightGesture)):
            return areByteEqual(leftPath, rightPath) &&
                leftArguments.count == rightArguments.count &&
                zip(leftArguments, rightArguments).allSatisfy { areByteEqual($0.0, $0.1) } &&
                leftTimeout == rightTimeout && leftGesture == rightGesture
        case let (.typeText(leftText, leftGesture), .typeText(rightText, rightGesture)):
            return areByteEqual(leftText, rightText) && leftGesture == rightGesture
        case let (.keyPress(leftKey, leftGesture), .keyPress(rightKey, rightGesture)):
            return leftKey == rightKey && leftGesture == rightGesture
        default:
            return false
        }
    }
}

private func areByteEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}
