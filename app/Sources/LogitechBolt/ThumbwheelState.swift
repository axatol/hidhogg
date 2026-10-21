import Foundation

struct ThumbwheelState {
    struct Info: Equatable {
        let nativeResolution: UInt16
        let divertedResolution: UInt16
        let defaultInverted: Bool
        let capabilities: UInt8
        let timeUnit: UInt16

        init(_ reply: [UInt8]) throws {
            guard reply.count >= 8, reply[4] & 0xFE == 0, reply[5] & 0xF0 == 0 else { throw BoltFailure.malformed }
            nativeResolution = BoltWire.word(reply, 0)
            divertedResolution = BoltWire.word(reply, 2)
            defaultInverted = reply[4] & 1 != 0
            capabilities = reply[5]
            timeUnit = BoltWire.word(reply, 6)
        }
    }

    struct Mode: Equatable {
        let diverted: Bool
        let inverted: Bool

        var parameters: [UInt8] { [diverted ? 1 : 0, inverted ? 1 : 0] }

        static func decode(_ reply: [UInt8]) throws -> Mode {
            guard reply.count >= 2, reply[0] <= 1, reply[1] & 0xF8 == 0 else { throw BoltFailure.foreignState }
            return Mode(diverted: reply[0] == 1, inverted: reply[1] & 1 != 0)
        }
    }

    struct Ownership {
        let original: Mode
        let target: Mode
    }

    struct Capture {
        let native: Mode
        var captured: Mode { Mode(diverted: true, inverted: false) }
    }

    struct Request: Equatable {
        let inverted: Bool?
        let restore: Bool
    }

    var support: BoltThumbwheelStatus.Support = .unknown
    var feature: UInt8?
    var info: Info?
    var baseline: Mode?
    var latest: Mode?
    var ownership: Ownership?
    var pendingRollback: Mode?
    var capture: Capture?
    var captureVerified = false
    var associationLost = false
    var restore = false
    var request: Request?
    var generation: UInt64 = 0
    var enabledAt: ContinuousClock.Instant = .now
    var blocker: String?
    var message: String?

    var status: BoltThumbwheelStatus {
        BoltThumbwheelStatus(support: support, observedInverted: latest?.inverted,
                             isOwned: ownership != nil || capture != nil,
                             captureActive: capture != nil && captureVerified && blocker == nil,
                             effectiveInverted: capture?.native.inverted, captureBlocker: blocker, message: message)
    }
}
