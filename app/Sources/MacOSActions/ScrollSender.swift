import CoreGraphics
import Foundation
import HidhoggDomain

public enum AmountAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

public enum ScrollDeliveryError: Error, Equatable, LocalizedError {
    case permissionDenied
    case invalidAmount
    case invalidDelta
    case staleTimestamp
    case futureTimestamp
    case eventOutOfRange
    case allocationFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "macOS event posting permission is required."
        case .invalidAmount: "Wheel scroll amount must be between 0.25 and 10."
        case .invalidDelta: "The normalized wheel delta is outside its supported range."
        case .staleTimestamp: "The wheel report timestamp is stale."
        case .futureTimestamp: "The wheel report timestamp is in the future."
        case .eventOutOfRange: "The wheel report cannot be represented as a line event."
        case .allocationFailed: "macOS could not create the scroll event."
        }
    }
}

@MainActor
public final class ScrollSender {
    private static let maximumInputMagnitude = 32_768.0
    private static let maximumReportGap = Duration.milliseconds(250)

    private let preflight: () -> Bool
    private let post: (Int32, Int32) throws -> Void
    private let now: () -> ContinuousClock.Instant
    private var verticalFraction = 0.0
    private var horizontalFraction = 0.0
    private var activeGeneration: UInt64?
    private var activeAmount: Double?
    private var activeAmountAxis: AmountAxis?
    private var lastObservedAt: ContinuousClock.Instant?

    public convenience init() {
        self.init(preflight: { CGPreflightPostEventAccess() }, post: Self.postNativeScroll)
    }

    public init(
        preflight: @escaping () -> Bool,
        post: @escaping (Int32, Int32) throws -> Void,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.preflight = preflight
        self.post = post
        self.now = now
    }

    public func canPostEvents() -> Bool {
        preflight()
    }

    public func reset() {
        verticalFraction = 0
        horizontalFraction = 0
        activeGeneration = nil
        activeAmount = nil
        activeAmountAxis = nil
        lastObservedAt = nil
    }

    public func send(
        vertical: Double,
        horizontal: Double,
        amount: Double,
        amountAxis: AmountAxis = .vertical,
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        resetFractionsBefore: Bool = false,
        resetFractionsAfter: Bool = false
    ) throws {
        var consumeTimestampOnError = false

        do {
            guard WheelScrollAmount.contains(amount) else {
                throw ScrollDeliveryError.invalidAmount
            }
            guard vertical.isFinite, horizontal.isFinite,
                  abs(vertical) <= Self.maximumInputMagnitude,
                  abs(horizontal) <= Self.maximumInputMagnitude else {
                throw ScrollDeliveryError.invalidDelta
            }

            let currentInstant = now()
            guard observedAt <= currentInstant else { throw ScrollDeliveryError.futureTimestamp }
            guard currentInstant - observedAt <= Self.maximumReportGap else {
                throw ScrollDeliveryError.staleTimestamp
            }
            if let lastObservedAt, observedAt <= lastObservedAt {
                throw ScrollDeliveryError.staleTimestamp
            }
            consumeTimestampOnError = true

            let contextChanged = activeGeneration != generation || activeAmount != amount || activeAmountAxis != amountAxis
            let reportGap = lastObservedAt.map { observedAt - $0 > Self.maximumReportGap } ?? false
            let resetPriorFractions = contextChanged || reportGap || resetFractionsBefore
            let priorVertical = resetPriorFractions ? 0 : verticalFraction
            let priorHorizontal = resetPriorFractions ? 0 : horizontalFraction
            let scaledVertical = amountAxis == .vertical ? vertical * amount : vertical
            let scaledHorizontal = amountAxis == .horizontal ? horizontal * amount : horizontal
            let (verticalUnits, nextVerticalFraction) = try Self.lineUnits(priorVertical + scaledVertical)
            let (horizontalUnits, nextHorizontalFraction) = try Self.lineUnits(priorHorizontal + scaledHorizontal)

            guard canPostEvents() else { throw ScrollDeliveryError.permissionDenied }
            if verticalUnits != 0 || horizontalUnits != 0 {
                try post(verticalUnits, horizontalUnits)
            }

            verticalFraction = resetFractionsAfter ? 0 : nextVerticalFraction
            horizontalFraction = resetFractionsAfter ? 0 : nextHorizontalFraction
            activeGeneration = generation
            activeAmount = amount
            activeAmountAxis = amountAxis
            lastObservedAt = observedAt
        } catch {
            verticalFraction = 0
            horizontalFraction = 0
            activeGeneration = nil
            activeAmount = nil
            activeAmountAxis = nil
            if consumeTimestampOnError { lastObservedAt = observedAt }
            throw error
        }
    }

    private static func lineUnits(_ total: Double) throws -> (Int32, Double) {
        guard total.isFinite,
              total >= Double(Int32.min), total <= Double(Int32.max) else {
            throw ScrollDeliveryError.eventOutOfRange
        }

        let nearestInteger = total.rounded()
        let precisionTolerance = max(1, abs(total)) * Double.ulpOfOne * 8
        let stableTotal = abs(total - nearestInteger) <= precisionTolerance ? nearestInteger : total
        let wholeUnits = stableTotal.rounded(.towardZero)
        guard wholeUnits >= Double(Int32.min), wholeUnits <= Double(Int32.max) else {
            throw ScrollDeliveryError.eventOutOfRange
        }

        return (Int32(wholeUnits), stableTotal - wholeUnits)
    }

    private static func postNativeScroll(vertical: Int32, horizontal: Int32) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .line,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
              ) else {
            throw ScrollDeliveryError.allocationFailed
        }

        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.post(tap: .cghidEventTap)
    }
}
