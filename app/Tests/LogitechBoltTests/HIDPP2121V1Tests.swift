import Testing
@testable import LogitechBolt

@Test func wheelV1LiteralCodecSeparatesInversionFromResolution() throws {
    let capabilities = try HIDPP2121V1.Capabilities([12, 0])
    #expect(capabilities.multiplier == 12)
    #expect(!capabilities.supportsInversion)
    #expect(try HIDPP2121V1.Mode([6, 0]).rawValue == 6)
    #expect(try HIDPP2121V1.physicalMode(current: 4, original: 4, ownedMask: 0,
        inverted: nil, highResolution: true, restoreReleasedFields: false, capabilities: capabilities) == 6)
    #expect(throws: BoltFailure.unsupported) {
        try HIDPP2121V1.physicalMode(current: 4, original: 4, ownedMask: 0,
            inverted: false, highResolution: true, restoreReleasedFields: false, capabilities: capabilities)
    }
}

@Test func wheelV1LiteralPlannerRestoresOwnedFieldsAndRefusesRouting() throws {
    let capabilities = try HIDPP2121V1.Capabilities([12, 8])
    #expect(try HIDPP2121V1.physicalMode(current: 6, original: 0, ownedMask: 6,
        inverted: nil, highResolution: true, restoreReleasedFields: true, capabilities: capabilities) == 2)
    #expect(try HIDPP2121V1.physicalMode(current: 6, original: 0, ownedMask: 6,
        inverted: false, highResolution: nil, restoreReleasedFields: false, capabilities: capabilities) == 2)
    #expect(!HIDPP2121V1.permitsPhysicalChange(from: 0, to: 1, capabilities: capabilities))
    #expect(!HIDPP2121V1.permitsPhysicalChange(from: 1, to: 0, capabilities: capabilities))
}

@Test(arguments: [[UInt8](), [12]])
func wheelV1LiteralCodecRejectsShortCapabilities(reply: [UInt8]) {
    #expect(throws: BoltFailure.malformed) { try HIDPP2121V1.Capabilities(reply) }
}

@Test(arguments: [[UInt8](), [6], [0, 1], [8, 0]])
func wheelV1LiteralCodecRejectsShortOrForeignMode(reply: [UInt8]) {
    #expect(throws: (any Error).self) { try HIDPP2121V1.Mode(reply) }
}

@Test(arguments: [[0, 0, 0], [23, 0, 2], [23, 32, 1], [23, 0]])
func wheelV1LiteralCodecRejectsAbsentUnknownOrMalformedRoot(reply: [UInt8]) {
    #expect(throws: (any Error).self) { try HIDPP2121V1.featureIndex(reply) }
}
