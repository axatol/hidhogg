struct VerticalWheelDirection: Equatable, Sendable {
    let nativeNaturalScrolling: Bool

    func hardwareInverted(for naturalScrolling: Bool) -> Bool {
        naturalScrolling != nativeNaturalScrolling
    }

    func naturalScrolling(for mode: UInt8) -> Bool {
        (mode & 0x04 != 0) != nativeNaturalScrolling
    }
}
