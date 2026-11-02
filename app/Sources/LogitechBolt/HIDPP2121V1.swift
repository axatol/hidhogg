import Foundation

enum HIDPP2121V1 {
    struct Capabilities: Equatable, Sendable {
        let flags: UInt8
        let multiplier: UInt8
        let supportsInversion: Bool

        init(_ reply: [UInt8]) throws {
            guard reply.count >= 2 else { throw BoltFailure.malformed }
            flags = reply[1]
            multiplier = reply[0]
            supportsInversion = reply[1] & 0x08 != 0
        }
    }

    struct Mode: Equatable, Sendable {
        let rawValue: UInt8

        init(_ reply: [UInt8]) throws {
            guard reply.count >= 2 else { throw BoltFailure.malformed }
            guard reply[1] == 0, reply[0] & 0xF8 == 0 else { throw BoltFailure.foreignState }
            rawValue = reply[0]
        }
    }

    static func featureIndex(_ root: [UInt8]) throws -> UInt8 {
        guard root.count >= 3 else { throw BoltFailure.malformed }
        guard root[0] != 0, root[1] & 0xE0 == 0, root[2] == 1 else { throw BoltFailure.unsupported }
        return root[0]
    }

    static func physicalMode(current: UInt8, original: UInt8, ownedMask: UInt8,
                             inverted: Bool?, highResolution: Bool?, restoreReleasedFields: Bool,
                             capabilities: Capabilities) throws -> UInt8 {
        guard current & 0xF9 == 0, original & 0xF9 == 0, ownedMask & ~0x06 == 0 else {
            throw BoltFailure.foreignState
        }
        guard inverted == nil || capabilities.supportsInversion else { throw BoltFailure.unsupported }
        var target = current
        for (desired, mask) in [(inverted, UInt8(0x04)), (highResolution, UInt8(0x02))] {
            if let desired {
                target = (target & ~mask) | (desired ? mask : 0)
            } else if restoreReleasedFields && ownedMask & mask != 0 {
                target = (target & ~mask) | (original & mask)
            }
        }
        guard (current ^ target) & 0x04 == 0 || capabilities.supportsInversion else {
            throw BoltFailure.unsupported
        }
        return target
    }

    static func permitsPhysicalChange(from current: UInt8, to target: UInt8, capabilities: Capabilities) -> Bool {
        current & 0xF9 == 0 && target & 0xF9 == 0
            && ((current ^ target) & 0x04 == 0 || capabilities.supportsInversion)
    }
}
