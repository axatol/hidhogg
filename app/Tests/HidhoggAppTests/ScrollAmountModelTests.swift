import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class ScrollAmountModelTests: XCTestCase {
    func testOptInAutosavesAndPostsWhileButtonsAreDisabledThenReleasesOnSleep() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollModelSession()
        var posts: [(Int32, Int32)] = []
        let model = makeModel(root, session, ScrollSender(preflight: { true }, post: { posts.append(($0, $1)) }))
        XCTAssertNil(model.wheelScrollAmountDraft)
        model.setWheelScrollAmount(2)
        model.connect()
        await expectEventually { session.lastRequest?.amount == 2 && session.captureActive }
        session.emitScroll(vertical: 3, horizontal: 2)
        await expectEventually { posts.count == 1 }
        XCTAssertEqual(posts.first?.0, 6)
        XCTAssertEqual(posts.first?.1, 2)
        XCTAssertFalse(model.isBindingsEnabled)
        await expectEventually { !model.isDirty }
        let snapshot = try await ConfigurationStore(url: root.appendingPathComponent("config.toml")).load()
        XCTAssertEqual(snapshot.configuration.mouse?.wheelScrollAmount, 2)
        await model.stopForSleep()
        XCTAssertFalse(session.captureActive)
        session.emitScroll(vertical: 3)
        await Task.yield()
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(model.wheelScrollAmountDraft, 2)
    }

    func testPostFailureInvalidatesBeforeCleanupAndAutomaticRefreshDoesNotRearm() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollModelSession()
        var posts = 0
        let model = makeModel(root, session, ScrollSender(preflight: { true }, post: { _, _ in
            posts += 1
            throw ScrollDeliveryError.allocationFailed
        }))
        model.setWheelPreference(true)
        model.setWheelScrollAmount(1)
        model.connect()
        await expectEventually { session.captureActive }
        session.pauseNextRelease()
        session.emitScroll(vertical: 1)
        session.emitScroll(vertical: 1)
        await expectEventually { session.releasePending }
        XCTAssertEqual(posts, 1)
        XCTAssertGreaterThan(session.invalidations, 0)
        XCTAssertEqual(model.wheelScrollAmountDraft, 1)
        XCTAssertEqual(session.lastRequest?.inverted, true)
        for _ in 0..<3 { _ = model.refreshPermission() }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(session.captureActive)
        XCTAssertEqual(session.lastRequest?.allowed, false)
        _ = model.refreshPermission(retryScrollCapture: true)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(session.captureActive)
        session.resumeRelease()
        await expectEventually { session.captureActive }
        model.disconnect()
        await expectEventually { !session.captureActive }
    }

    func testCoalescedOffOnAndDirectionRevertResumeAndIdenticalReloadKeepsCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollModelSession()
        var posts = 0
        let model = makeModel(root, session, ScrollSender(preflight: { true }, post: { _, _ in posts += 1 }))
        model.setWheelPreference(false)
        model.setWheelScrollAmount(1)
        model.connect()
        await expectEventually { session.captureActive }
        model.setWheelScrollAmount(nil)
        model.setWheelScrollAmount(1)
        model.setWheelPreference(true)
        model.setWheelPreference(false)
        await expectEventually { session.captureActive && session.lastRequest?.inverted == false }
        session.emitScroll(vertical: 1)
        await expectEventually { posts == 1 }
        await model.save()
        model.requestReload()
        await expectEventually { !model.isLoading }
        session.emitScroll(vertical: 1)
        await expectEventually { posts == 2 }
        model.disconnect()
        await expectEventually { !session.captureActive }
    }

    func testCapturePermissionDeniedRetainsAmountAndPhysicalPreferenceAndRetriesExplicitly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ScrollModelSession()
        var allowed = false
        var posts = 0
        let model = makeModel(root, session, ScrollSender(preflight: { allowed }, post: { _, _ in posts += 1 }))
        model.setWheelPreference(true)
        model.setWheelScrollAmount(1)
        model.connect()
        await expectEventually { session.lastRequest != nil }
        XCTAssertEqual(session.lastRequest?.inverted, true)
        XCTAssertEqual(session.lastRequest?.amount, 1)
        XCTAssertFalse(session.captureActive)
        session.emitScroll(vertical: 1)
        await Task.yield()
        XCTAssertEqual(posts, 0)
        allowed = true
        _ = model.refreshPermission(retryScrollCapture: true)
        await expectEventually { session.captureActive }
        session.emitScroll(vertical: 1)
        await expectEventually { posts == 1 }
        model.setWheelScrollAmount(nil)
        await expectEventually { session.lastRequest?.amount == nil && !session.captureActive }
    }

    private func makeModel(_ root: URL, _ session: ScrollModelSession, _ scrollSender: ScrollSender) -> AppModel {
        let url = root.appendingPathComponent("config.toml")
        let shortcut = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        return AppModel(configurationURL: url, store: ConfigurationStore(url: url), bolt: session,
                        sender: shortcut, scrollSender: scrollSender, loadImmediately: false, observeSleep: false,
                        frontmostApplication: { nil })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrollAmountModel-\(UUID().uuidString)")
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

private final class ScrollModelSession: BindingSession, @unchecked Sendable {
    struct Request {
        let inverted: Bool?
        let amount: Double?
        let allowed: Bool
    }
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var request: Request?
    private var active = false
    private var epoch: UInt64 = 0
    private var invalidationCount = 0
    private var pauseRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var lastRequest: Request? { lock.withLock { request } }
    var captureActive: Bool { lock.withLock { active } }
    var invalidations: Int { lock.withLock { invalidationCount } }
    var releasePending: Bool { lock.withLock { releaseContinuation != nil } }
    func pauseNextRelease() { lock.withLock { pauseRelease = true } }
    func resumeRelease() {
        let pending = lock.withLock { let pending = releaseContinuation; releaseContinuation = nil; return pending }
        pending?.resume()
    }

    func discover() async { publish(.ready) }
    func enable() async { publish(.enabled) }
    func disable() async { publish(.ready) }
    func stop() async {
        invalidateScrollAdmission()
        publish(.idle)
    }
    func stopForRestart() async -> Bool { await stop(); return true }
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }
    func suspendScrollAdmission() { lock.withLock { active = false } }
    func invalidateScrollAdmission() { lock.withLock { active = false; invalidationCount += 1 } }
    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock {
            guard active, generation == epoch else { return false }
            operation()
            return true
        }
    }
    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async {
        lock.withLock {
            request = Request(inverted: inverted, amount: amount, allowed: scrollPostingAllowed)
            active = amount != nil && scrollPostingAllowed
            epoch &+= 1
        }
        let shouldPause = lock.withLock {
            if amount != nil && !scrollPostingAllowed && pauseRelease { pauseRelease = false; return true }
            return false
        }
        if shouldPause { await withCheckedContinuation { pending in lock.withLock { releaseContinuation = pending } } }
        publish(.ready)
    }
    func emitScroll(vertical: Double, horizontal: Double = 0) {
        let generation = lock.withLock { epoch }
        continuation.yield(.scroll(vertical: vertical, horizontal: horizontal, generation: generation, observedAt: .now))
    }
    private func publish(_ phase: BoltPhase) {
        let capture = captureActive
        continuation.yield(.status(BoltStatus(phase: phase, message: "Fixture", availableControls: Set(MouseControl.allCases),
                                             generation: 1, cleanupUncertain: false,
                                             wheel: BoltWheelStatus(support: .supported, captureActive: capture))))
    }
}
