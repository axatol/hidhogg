import Foundation

struct HIDPPHardwareSnapshot: Equatable {
    let identifier: UInt16
    let root: [UInt8]
    let capabilities: [UInt8]
    let values: [UInt16]
    var index: UInt8 { root[0] }
    var readFunction: UInt8 {
        switch identifier {
        case 0x2110, 0x2205: 0
        case 0x2111, 0x19B0: 1
        default: 2
        }
    }
    var setFunction: UInt8 { readFunction + 1 }
    var readFunctions: [UInt8] {
        switch identifier {
        case 0x2110, 0x2205: [0]
        case 0x2111: [0, 1]
        case 0x19B0: [0, 1, 3]
        default: [0, 1, 2]
        }
    }

    func hasSameContract(as other: Self) -> Bool {
        identifier == other.identifier && root == other.root && capabilities == other.capabilities
    }

    func parameters(values: [UInt16], mask: [UInt16]) -> [UInt8] {
        switch identifier {
        case 0x2110, 0x2111:
            return values.enumerated().map { mask[$0.offset] == 0 ? 0 : UInt8($0.element) }
        case 0x2201: return [0] + BoltWire.bytes(values[0])
        case 0x2205: return BoltWire.bytes(values[0])
        case 0x19B0: return [UInt8(values[0]), UInt8(values[1]), 0]
        default: return [0] + BoltWire.bytes(values[0])
        }
    }

    func plan(_ preferences: BoltHardwareSettingsPreferences) throws -> (values: [UInt16], mask: [UInt16]) {
        var result = values
        var mask = Array(repeating: UInt16(0), count: values.count)
        switch identifier {
        case 0x2110, 0x2111:
            if let threshold = preferences.smartShiftThreshold {
                guard threshold > 0 else { throw BoltFailure.unsupported }
                result[1] = UInt16(threshold); mask[1] = 0xFF
            }
            if let mode = preferences.smartShiftMode {
                result[0] = mode == .freeSpin ? 1 : 2; mask[0] = 0xFF
                if mode == .ratchet { result[1] = 255; mask[1] = 0xFF }
                if mode == .automatic {
                    guard result[1] > 0, result[1] < 255 else { throw BoltFailure.unsupported }
                }
            }
            if let torque = preferences.smartShiftTorque {
                guard identifier == 0x2111, capabilities[0] & 1 != 0,
                      torque > 0, torque <= 100, torque <= capabilities[3] else { throw BoltFailure.unsupported }
                result[2] = UInt16(torque); mask[2] = 0xFF
            }
        case 0x2201:
            if let dpi = preferences.dpi {
                guard root[2] <= 1, values[0] > 0 else { throw BoltFailure.unsupported }
                guard try HIDPPHardwareCodec.dpiValues(Array(capabilities.dropFirst())).contains(dpi) else { throw BoltFailure.unsupported }
                result[0] = dpi; mask[0] = 0xFFFF
            }
        case 0x2205:
            if let speed = preferences.pointerSpeed {
                guard speed.isFinite, speed >= 46.0 / 256, speed <= 511.0 / 256 else { throw BoltFailure.unsupported }
                result[0] = UInt16((speed * 256).rounded()); mask[0] = 0xFFFF
            }
        case 0x19B0:
            if let enabled = preferences.hapticsEnabled {
                result[0] = enabled ? result[0] | 1 : result[0] & ~1; mask[0] |= 1
            }
            if let saving = preferences.hapticPowerSaving {
                result[0] = saving ? result[0] | 2 : result[0] & ~2; mask[0] |= 2
            }
            if let intensity = preferences.hapticIntensity {
                guard intensity <= 100, capabilities[8] >> 4 > 0, capabilities[8] & 15 > 0 else { throw BoltFailure.unsupported }
                result[1] = UInt16(intensity); mask[1] = 0xFF
            }
        case 0x19C0:
            if let threshold = preferences.forceThreshold {
                guard BoltWire.word(capabilities, 0) & 1 != 0,
                      threshold >= BoltWire.word(capabilities, 6), threshold <= BoltWire.word(capabilities, 4) else { throw BoltFailure.unsupported }
                result[0] = threshold; mask[0] = 0xFFFF
            }
        default: throw BoltFailure.unsupported
        }
        return (result, mask)
    }
}

enum HIDPPHardwareCodec {
    static func dpiValues(_ bytes: [UInt8]) throws -> [UInt16] {
        guard bytes.count >= 2 else { throw BoltFailure.malformed }
        var values: [UInt16] = []
        var offset = 0
        while offset + 1 < bytes.count {
            let item = BoltWire.word(bytes, offset)
            if item == 0 {
                guard !values.isEmpty else { throw BoltFailure.malformed }
                return Array(Set(values)).sorted()
            }
            offset += 2
            if item & 0xE000 == 0xE000 {
                let step = item & 0x1FFF
                guard let start = values.last, step > 0, offset + 1 < bytes.count else { throw BoltFailure.malformed }
                let end = BoltWire.word(bytes, offset)
                guard end >= start, end < 0xE000 else { throw BoltFailure.malformed }
                let count = Int((end - start) / step)
                guard values.count + count + 1 <= 4096 else { throw BoltFailure.malformed }
                for value in stride(from: Int(start) + Int(step), through: Int(end), by: Int(step)) { values.append(UInt16(value)) }
                if values.last != end { values.append(end) }
                offset += 2
            } else {
                values.append(item)
            }
        }
        guard bytes.count == 15, offset == 14, !values.isEmpty else { throw BoltFailure.malformed }
        return Array(Set(values)).sorted()
    }

    static func merge(current: [UInt16], desired: [UInt16], mask: [UInt16]) -> [UInt16] {
        zip(zip(current, desired), mask).map { ($0.0.0 & ~$0.1) | ($0.0.1 & $0.1) }
    }

    static func matches(_ first: [UInt16], _ second: [UInt16], mask: [UInt16]) -> Bool {
        zip(zip(first, second), mask).allSatisfy { $0.0.0 & $0.1 == $0.0.1 & $0.1 }
    }
}
