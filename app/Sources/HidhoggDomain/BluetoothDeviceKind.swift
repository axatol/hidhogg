import Foundation

public enum BluetoothDeviceKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case generic
    case keyboard
    case mouse
    case headphones
    case speaker
    case glasses
    case watch
    case phone
    case computer
    case gameController

    public var title: String {
        switch self {
        case .generic: "Generic Bluetooth"
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .headphones: "Headphones"
        case .speaker: "Speaker"
        case .glasses: "Glasses"
        case .watch: "Watch"
        case .phone: "Phone"
        case .computer: "Computer"
        case .gameController: "Game Controller"
        }
    }

    public var optionalSystemSymbol: String? {
        switch self {
        case .generic: nil
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .glasses: "eyeglasses"
        case .watch: "applewatch"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .gameController: "gamecontroller"
        }
    }

    public static func preferred(iconOverride: Self?, reported: Self?) -> Self {
        iconOverride ?? reported ?? .generic
    }

    public static func reported(majorDeviceClass major: UInt32, minorDeviceClass minor: UInt32) -> Self? {
        guard major <= 0x1F, minor <= 0x3F else { return nil }
        return switch major {
        case 0x01:
            minor == 0x06 ? .watch : .computer
        case 0x02:
            .phone
        case 0x04:
            switch minor {
            case 0x01, 0x02, 0x06: .headphones
            case 0x05: .speaker
            default: nil
            }
        case 0x05:
            switch minor & 0x30 {
            case 0x10: .keyboard
            case 0x20: .mouse
            case 0x30: nil
            default:
                switch minor & 0x0F {
                case 0x01, 0x02: .gameController
                default: nil
                }
            }
        case 0x07:
            switch minor {
            case 0x01: .watch
            case 0x05: .glasses
            default: nil
            }
        default:
            nil
        }
    }
}
