import Foundation
import LogitechBolt

struct DeviceInformationPresentation {
    struct FirmwareRow: Equatable, Identifiable {
        let id: Int
        let label: String
        let value: String
        let caption: String?
        let isActive: Bool
        let isPrimary: Bool
    }

    let status: BoltStatus

    var batteryText: String {
        guard isConnected else { return "Unavailable" }
        let information = status.deviceInformation
        guard information.batteryState == .available, let battery = information.battery else {
            return stateTitle(information.batteryState)
        }
        let percentage = battery.percentage.map { "\($0)%" } ?? "Percentage unavailable"
        switch battery.charging {
        case .discharging: return percentage
        case .charging: return "\(percentage) · Charging"
        case .slowCharging: return "\(percentage) · Charging slowly"
        case .complete: return "\(percentage) · Charged"
        case .error: return "\(percentage) · Charging error"
        case .unknown: return "\(percentage) · Charging state unknown"
        }
    }

    var batterySymbol: String {
        guard isConnected, status.deviceInformation.batteryState == .available,
              let battery = status.deviceInformation.battery else { return "battery.0percent" }
        if battery.charging == .charging || battery.charging == .slowCharging { return "battery.100percent.bolt" }
        guard let percentage = battery.percentage else { return "battery.0percent" }
        switch percentage {
        case 0..<10: return "battery.0percent"
        case 10..<35: return "battery.25percent"
        case 35..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var firmwareStateText: String {
        isConnected ? stateTitle(status.deviceInformation.firmwareState) : "Unavailable"
    }

    var firmwareRows: [FirmwareRow] {
        guard isConnected, status.deviceInformation.firmwareState == .available else { return [] }

        return status.deviceInformation.firmware.enumerated().map { index, entity in
            let componentType = entity.type & 0x0F
            let prefix = entity.prefix.trimmingCharacters(in: .whitespaces)
            let prefixCaption = prefix.isEmpty ? nil : "Firmware class \(prefix)"
            let label: String
            let caption: String?
            let isPrimary: Bool

            switch componentType {
            case 0:
                label = "MX Master 3S firmware"
                caption = prefixCaption
                isPrimary = true
            case 1:
                label = "Bootloader"
                caption = prefixCaption
                isPrimary = false
            case 2:
                label = "Hardware revision"
                caption = nil
                isPrimary = false
            default:
                label = "Other component"
                let typeCaption = "Unrecognized type \(entity.type)"
                caption = prefixCaption.map { "\($0) · \(typeCaption)" } ?? typeCaption
                isPrimary = false
            }

            return FirmwareRow(
                id: index,
                label: label,
                value: firmwareDescription(entity),
                caption: caption,
                isActive: entity.flags & 0x01 != 0,
                isPrimary: isPrimary
            )
        }
    }

    var isConnected: Bool {
        [.ready, .enabled, .enabling].contains(status.phase)
    }

    func firmwareDescription(_ entity: BoltDeviceInformation.FirmwareEntity) -> String {
        switch entity.type & 0x0F {
        case 0, 1:
            guard let number = packedBCD(entity.rawVersion >> 8, nibbleCount: 2),
                  let revision = packedBCD(entity.rawVersion & 0x00FF, nibbleCount: 2),
                  let build = packedBCD(entity.rawBuild, nibbleCount: 4) else { return "Version unavailable" }
            return "\(number).\(revision).\(build)"
        case 2:
            return entity.hardwareRevision.map { String($0) } ?? "Revision unavailable"
        default:
            return "Version unavailable"
        }
    }

    private func packedBCD(_ value: UInt16, nibbleCount: Int) -> Int? {
        var decimalValue = 0
        for position in stride(from: nibbleCount - 1, through: 0, by: -1) {
            let digit = Int((value >> (position * 4)) & 0x0F)
            guard digit <= 9 else { return nil }
            decimalValue = decimalValue * 10 + digit
        }
        return decimalValue
    }

    private func stateTitle(_ state: BoltDeviceInformation.State) -> String {
        switch state {
        case .unknown: "Not read yet"
        case .loading: "Reading…"
        case .available: "Available"
        case .unsupported: "Unsupported"
        case .unavailable: "Unavailable — refresh to retry"
        }
    }
}
