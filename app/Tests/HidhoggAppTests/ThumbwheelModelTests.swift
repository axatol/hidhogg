import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class ThumbwheelModelTests: XCTestCase {
    func testThumbwheelAndVerticalFractionsRemainIndependentAcrossZeroStop() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ThumbwheelModelSession()
        let clock = SenderTestClock()
        var wheelPosts = [PostedLines]()
        var thumbwheelPosts = [PostedLines]()
        let model = makeModel(
            root,
            session,
            scrollSender: ScrollSender(
                preflight: { true },
                post: { wheelPosts.append(.init(vertical: $0, horizontal: $1)) },
                now: { clock.now }
            ),
            thumbwheelSender: ScrollSender(
                preflight: { true },
                post: { thumbwheelPosts.append(.init(vertical: $0, horizontal: $1)) },
                now: { clock.now }
            )
        )
        model.setWheelScrollAmount(1)
        model.setThumbwheelScrollAmount(1)
        model.connect()
        await expectEventually { session.wheelCaptureActive && session.thumbwheelCaptureActive }

        var observedAt = clock.now.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitScroll(vertical: 0.5, observedAt: observedAt)
        session.emitThumbwheel(rotation: 0.5, state: 0, observedAt: observedAt)
        await expectEventually { session.admittedWheelCount == 1 && session.admittedThumbwheelCount == 1 }
        XCTAssertTrue(wheelPosts.isEmpty)
        XCTAssertTrue(thumbwheelPosts.isEmpty)

        session.emitThumbwheel(rotation: 1, state: 1, observedAt: observedAt)
        session.emitThumbwheel(rotation: 0, state: 3, observedAt: observedAt)
        await expectEventually { session.thumbwheelAttemptCount == 3 }
        XCTAssertEqual(session.admittedThumbwheelCount, 1)

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitScroll(vertical: 0.5, observedAt: observedAt)
        session.emitThumbwheel(rotation: 0.5, state: 0, observedAt: observedAt)
        await expectEventually { wheelPosts.count == 1 && thumbwheelPosts.count == 1 }
        XCTAssertEqual(wheelPosts, [.init(vertical: 1, horizontal: 0)])
        XCTAssertEqual(thumbwheelPosts, [.init(vertical: 0, horizontal: 1)])

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitThumbwheel(rotation: 0.5, state: 0, observedAt: observedAt)
        await expectEventually { session.admittedThumbwheelCount == 3 }

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitThumbwheel(rotation: 0, state: 3, observedAt: observedAt)
        await expectEventually { session.admittedThumbwheelCount == 4 }

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitScroll(vertical: 0.5, observedAt: observedAt)
        session.emitThumbwheel(rotation: 0.5, state: 0, observedAt: observedAt)
        await expectEventually { session.admittedWheelCount == 3 && session.admittedThumbwheelCount == 5 }
        XCTAssertEqual(wheelPosts.count, 1)
        XCTAssertEqual(thumbwheelPosts.count, 1)

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitScroll(vertical: 0.5, observedAt: observedAt)
        session.emitThumbwheel(rotation: 0.5, state: 0, observedAt: observedAt)
        await expectEventually { wheelPosts.count == 2 && thumbwheelPosts.count == 2 }
        XCTAssertEqual(wheelPosts, [.init(vertical: 1, horizontal: 0), .init(vertical: 1, horizontal: 0)])
        XCTAssertEqual(thumbwheelPosts, [.init(vertical: 0, horizontal: 1), .init(vertical: 0, horizontal: 1)])

        model.disconnect()
        await expectEventually { !session.wheelCaptureActive && !session.thumbwheelCaptureActive }
    }

    func testThumbwheelFailureLatchIsIndependentAndOnlyExplicitRetryRearmsCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ThumbwheelModelSession()
        let clock = SenderTestClock()
        var failThumbwheelPost = true
        var wheelPosts = [PostedLines]()
        var thumbwheelPosts = [PostedLines]()
        let model = makeModel(
            root,
            session,
            scrollSender: ScrollSender(
                preflight: { true },
                post: { wheelPosts.append(.init(vertical: $0, horizontal: $1)) },
                now: { clock.now }
            ),
            thumbwheelSender: ScrollSender(
                preflight: { true },
                post: {
                    if failThumbwheelPost { throw ScrollDeliveryError.allocationFailed }
                    thumbwheelPosts.append(.init(vertical: $0, horizontal: $1))
                },
                now: { clock.now }
            )
        )
        model.setWheelScrollAmount(1)
        model.setThumbwheelScrollAmount(1)
        model.connect()
        await expectEventually { session.wheelCaptureActive && session.thumbwheelCaptureActive }

        var observedAt = clock.now.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitThumbwheel(rotation: 1, state: 0, observedAt: observedAt)
        await expectEventually { session.lastThumbwheelRequest?.scrollPostingAllowed == false }
        XCTAssertFalse(session.thumbwheelCaptureActive)
        XCTAssertTrue(session.wheelCaptureActive)
        XCTAssertTrue(model.scrollAmountStatus.hasPrefix("Active"))
        XCTAssertTrue(model.thumbwheelScrollAmountStatus.hasPrefix("Blocked"))

        let requestCount = session.thumbwheelRequests.count
        _ = model.refreshPermission()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(session.thumbwheelRequests.count, requestCount)
        XCTAssertFalse(session.thumbwheelCaptureActive)

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        session.emitScroll(vertical: 1, observedAt: observedAt)
        await expectEventually { wheelPosts.count == 1 }
        XCTAssertEqual(wheelPosts, [.init(vertical: 1, horizontal: 0)])

        failThumbwheelPost = false
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        _ = model.refreshPermission(retryScrollCapture: true)
        await expectEventually { session.thumbwheelCaptureActive && session.lastThumbwheelRequest?.scrollPostingAllowed == true }
        session.emitThumbwheel(rotation: 1, state: 0, observedAt: observedAt)
        await expectEventually { thumbwheelPosts.count == 1 }
        XCTAssertEqual(thumbwheelPosts, [.init(vertical: 0, horizontal: 1)])

        model.disconnect()
        await expectEventually { !session.wheelCaptureActive && !session.thumbwheelCaptureActive }
    }

    func testThumbwheelDefaultsStayNativeAndEditsAutosaveReloadAndCoalesceOffOn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ThumbwheelModelSession()
        let model = makeModel(
            root,
            session,
            scrollSender: ScrollSender(preflight: { true }, post: { _, _ in }),
            thumbwheelSender: ScrollSender(preflight: { true }, post: { _, _ in })
        )

        model.connect()
        await expectEventually { session.phase == .ready }
        XCTAssertTrue(session.thumbwheelRequests.isEmpty)
        XCTAssertEqual(model.thumbwheelScrollAmountDraft, nil)
        XCTAssertEqual(model.observedThumbwheelDirection, "Not observed")

        model.setThumbwheelPreference(true)
        model.setThumbwheelScrollAmount(1)
        await expectEventually { session.thumbwheelCaptureActive }
        let priorRequestCount = session.thumbwheelRequests.count
        model.setThumbwheelScrollAmount(nil)
        model.setThumbwheelScrollAmount(2)
        await expectEventually { session.lastThumbwheelRequest?.amount == 2 && session.thumbwheelCaptureActive }
        XCTAssertFalse(session.thumbwheelRequests.dropFirst(priorRequestCount).contains { $0.amount == nil })
        await expectEventually { !model.isDirty }

        let configurationURL = root.appendingPathComponent("config.toml")
        let saved = try await ConfigurationStore(url: configurationURL).load()
        XCTAssertEqual(saved.configuration.mouse?.thumbwheelInverted, true)
        XCTAssertEqual(saved.configuration.mouse?.thumbwheelScrollAmount, 2)

        model.setThumbwheelScrollAmount(3)
        await expectEventually { model.isDirty }
        model.requestReload()
        XCTAssertTrue(model.isReloadConfirmationPresented)
        model.confirmDiscardAndReload()
        await expectEventually { !model.isLoading }
        XCTAssertEqual(model.thumbwheelScrollAmountDraft, 2)

        model.disconnect()
        await expectEventually { !session.thumbwheelCaptureActive }
    }

    private func makeModel(
        _ root: URL,
        _ session: ThumbwheelModelSession,
        scrollSender: ScrollSender,
        thumbwheelSender: ScrollSender
    ) -> AppModel {
        let url = root.appendingPathComponent("config.toml")
        let shortcut = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        return AppModel(configurationURL: url, store: ConfigurationStore(url: url), bolt: session,
                        sender: shortcut, scrollSender: scrollSender, thumbwheelScrollSender: thumbwheelSender,
                        loadImmediately: false, observeSleep: false, frontmostApplication: { nil })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbwheelModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func expectEventually(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let success = await eventually(predicate)
        XCTAssertTrue(success, file: file, line: line)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private final class ThumbwheelModelSession: BindingSession, @unchecked Sendable {
    struct WheelRequest: Equatable {
        let inverted: Bool?
        let amount: Double?
        let scrollPostingAllowed: Bool
    }

    struct ThumbwheelRequest: Equatable {
        let inverted: Bool?
        let amount: Double?
        let scrollPostingAllowed: Bool
        let restorePreviousSettingsOnDisconnect: Bool
    }

    private let lock = NSLock()
    private let continuation: AsyncStream<BoltEvent>.Continuation
    let events: AsyncStream<BoltEvent>
    private var currentPhase: BoltPhase = .idle
    private var wheelSupport: BoltWheelStatus.Support = .supported
    private var thumbwheelSupport: BoltThumbwheelStatus.Support = .unknown
    private var wheelRequest: WheelRequest?
    private var thumbwheelRequest: ThumbwheelRequest?
    private var wheelActive = false
    private var thumbwheelActive = false
    private var wheelGeneration: UInt64 = 0
    private var thumbwheelGeneration: UInt64 = 0
    private var lastWheelEventAt: ContinuousClock.Instant?
    private var lastThumbwheelEventAt: ContinuousClock.Instant?
    private var wheelAdmissions = 0
    private var thumbwheelAdmissions = 0
    private var thumbwheelAdmissionAttempts = 0
    private var wheelRequestsSent = [WheelRequest]()
    private var thumbwheelRequestsSent = [ThumbwheelRequest]()

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var phase: BoltPhase { lock.withLock { currentPhase } }
    var wheelCaptureActive: Bool { lock.withLock { wheelActive } }
    var thumbwheelCaptureActive: Bool { lock.withLock { thumbwheelActive } }
    var lastThumbwheelRequest: ThumbwheelRequest? { lock.withLock { thumbwheelRequest } }
    var thumbwheelRequests: [ThumbwheelRequest] { lock.withLock { thumbwheelRequestsSent } }
    var admittedWheelCount: Int { lock.withLock { wheelAdmissions } }
    var admittedThumbwheelCount: Int { lock.withLock { thumbwheelAdmissions } }
    var thumbwheelAttemptCount: Int { lock.withLock { thumbwheelAdmissionAttempts } }

    func discover() async { publish(.ready) }
    func enable() async { publish(.enabled) }
    func disable() async { publish(.ready) }

    func stop() async {
        lock.withLock {
            wheelActive = false
            thumbwheelActive = false
            wheelGeneration &+= 1
            thumbwheelGeneration &+= 1
        }
        publish(.idle)
    }

    func stopForRestart() async -> Bool {
        await stop()
        return true
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async {
        lock.withLock {
            let request = WheelRequest(inverted: inverted, amount: amount, scrollPostingAllowed: scrollPostingAllowed)
            wheelRequest = request
            wheelRequestsSent.append(request)
            wheelActive = amount != nil && scrollPostingAllowed
            wheelGeneration &+= 1
            lastWheelEventAt = nil
        }
        publish(.ready)
    }

    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool,
                                    scrollPostingAllowed: Bool) async {
        lock.withLock {
            if inverted != nil || amount != nil { thumbwheelSupport = .supported }
            let request = ThumbwheelRequest(inverted: inverted, amount: amount,
                                            scrollPostingAllowed: scrollPostingAllowed,
                                            restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
            thumbwheelRequest = request
            thumbwheelRequestsSent.append(request)
            thumbwheelActive = thumbwheelSupport == .supported && amount != nil && scrollPostingAllowed
            thumbwheelGeneration &+= 1
            lastThumbwheelEventAt = nil
        }
        publish(.ready)
    }

    func suspendScrollAdmission() { lock.withLock { wheelActive = false } }
    func invalidateScrollAdmission() { lock.withLock { wheelActive = false } }
    func suspendThumbwheelAdmission() { lock.withLock { thumbwheelActive = false } }
    func invalidateThumbwheelAdmission() { lock.withLock { thumbwheelActive = false } }

    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock {
            guard wheelActive, generation == wheelGeneration,
                  lastWheelEventAt.map({ observedAt > $0 }) ?? true else { return false }
            lastWheelEventAt = observedAt
            wheelAdmissions += 1
            operation()
            return true
        }
    }

    func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock {
            thumbwheelAdmissionAttempts += 1
            guard thumbwheelActive, generation == thumbwheelGeneration,
                  lastThumbwheelEventAt.map({ observedAt > $0 }) ?? true else { return false }
            lastThumbwheelEventAt = observedAt
            thumbwheelAdmissions += 1
            operation()
            return true
        }
    }

    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }

    func emitScroll(vertical: Double, observedAt: ContinuousClock.Instant) {
        let generation = lock.withLock { wheelGeneration }
        continuation.yield(.scroll(vertical: vertical, horizontal: 0, generation: generation, observedAt: observedAt))
    }

    func emitThumbwheel(rotation: Double, state: UInt8, observedAt: ContinuousClock.Instant, generation: UInt64? = nil) {
        let eventGeneration = lock.withLock { generation ?? thumbwheelGeneration }
        continuation.yield(.thumbwheel(rotation: rotation, state: state, generation: eventGeneration, observedAt: observedAt))
    }

    private func publish(_ phase: BoltPhase) {
        let status = lock.withLock { () -> BoltStatus in
            currentPhase = phase
            let wheel = BoltWheelStatus(
                support: wheelSupport,
                observedInverted: false,
                isOwned: wheelRequest?.inverted != nil || wheelRequest?.amount != nil,
                captureActive: wheelActive,
                effectiveInverted: wheelRequest?.inverted ?? false
            )
            let thumbwheel = BoltThumbwheelStatus(
                support: thumbwheelSupport,
                observedInverted: false,
                isOwned: thumbwheelRequest?.inverted != nil || thumbwheelRequest?.amount != nil,
                captureActive: thumbwheelActive,
                effectiveInverted: thumbwheelRequest?.inverted ?? false
            )
            return BoltStatus(phase: phase, message: "Fixture", availableControls: Set(MouseControl.allCases),
                              generation: 1, cleanupUncertain: false, wheel: wheel, thumbwheel: thumbwheel)
        }
        continuation.yield(.status(status))
    }
}

@MainActor
private final class SenderTestClock {
    var now = ContinuousClock.now
}

private struct PostedLines: Equatable {
    let vertical: Int32
    let horizontal: Int32
}
