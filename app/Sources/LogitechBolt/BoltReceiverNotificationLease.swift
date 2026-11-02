struct BoltReceiverNotificationLease: Sendable {
    static let requiredMask: UInt32 = 0x000900

    let ownedBits: UInt32
    let expectedMask: UInt32

    init(baseline: UInt32) {
        ownedBits = Self.requiredMask & ~baseline
        expectedMask = baseline | Self.requiredMask
    }

    var setupBytes: [UInt8] { Self.bytes(expectedMask) }

    static func bytes(_ mask: UInt32) -> [UInt8] {
        [UInt8((mask >> 16) & 0xFF), UInt8((mask >> 8) & 0xFF), UInt8(mask & 0xFF)]
    }
}
