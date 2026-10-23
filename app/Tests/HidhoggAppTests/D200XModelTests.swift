import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import LogitechBolt
import MacOSActions
import UlanziD200X

@MainActor
final class D200XModelTests: XCTestCase {
    func testConfigurationCanBeEnabledAndConnectionRequiresExplicitRequest() async throws {
        let session = FixtureD200XSession()
        let model = D200XModel(session: session, sender: makeSender())
        var edited: D200XConfiguration?
        model.onEdit = { edited = $0 }
        model.synchronize(nil, canEdit: true)

        model.enableConfiguration()

        XCTAssertEqual(edited, .empty)
        XCTAssertFalse(model.isConnected)
        let initialConnectionCount = await session.connectionCount()
        XCTAssertEqual(initialConnectionCount, 0)

        model.synchronize(try XCTUnwrap(edited), canEdit: true)
        model.connect()

        let connected = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 1 && model.isConnected
        }
        XCTAssertTrue(connected)
    }

    func testApplicationOverrideUsesRuntimeForegroundAndReleaseClearsHeldKey() async throws {
        let session = FixtureD200XSession()
        let defaultShortcut = KeyboardShortcut(keyCode: 12)
        let editingApplicationShortcut = KeyboardShortcut(keyCode: 13)
        let foregroundApplicationShortcut = KeyboardShortcut(keyCode: 14)
        let configuration = D200XConfiguration(
            defaults: [D200XControl.key0.rawValue: .key(defaultShortcut)],
            applications: [
                "com.example.editor": [D200XControl.key0.rawValue: .key(editingApplicationShortcut)],
                "com.example.browser": [D200XControl.key0.rawValue: .key(foregroundApplicationShortcut)]
            ]
        )
        let foregroundApplication = "com.example.browser"
        var posted = [KeyboardShortcut]()
        let model = D200XModel(
            session: session,
            sender: makeSender { posted.append($0) },
            frontmostApplication: { foregroundApplication }
        )
        model.synchronize(configuration, canEdit: true)
        model.applicationID = "com.example.editor"
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        try await session.emit(input(index: 0, family: 1, state: 1), generation: 1)
        let firstPressDelivered = await eventually { posted == [foregroundApplicationShortcut] }
        XCTAssertTrue(firstPressDelivered)

        try await session.emit(input(index: 0, family: 1, state: 1), generation: 1)
        try await session.emit(input(index: 0, family: 1, state: 0), generation: 1)
        let releaseDidNotDeliver = await eventually { posted.count == 1 }
        XCTAssertTrue(releaseDidNotDeliver)

        try await session.emit(input(index: 0, family: 1, state: 1), generation: 1)
        let pressAfterReleaseDelivered = await eventually { posted.count == 2 }
        XCTAssertTrue(pressAfterReleaseDelivered)
        XCTAssertEqual(posted, [foregroundApplicationShortcut, foregroundApplicationShortcut])
        XCTAssertNotEqual(posted.first, editingApplicationShortcut)
    }

    func testDialRotationGesturesUseTheirExplicitBindings() async throws {
        let session = FixtureD200XSession()
        let left = KeyboardShortcut(keyCode: 12)
        let right = KeyboardShortcut(keyCode: 13)
        let heldLeft = KeyboardShortcut(keyCode: 14)
        let heldRight = KeyboardShortcut(keyCode: 15)
        let configuration = D200XConfiguration(defaults: [
            D200XControl.dial0Left.rawValue: .key(left),
            D200XControl.dial0Right.rawValue: .key(right),
            D200XControl.dial0HeldLeft.rawValue: .key(heldLeft),
            D200XControl.dial0HeldRight.rawValue: .key(heldRight)
        ])
        var posted = [KeyboardShortcut]()
        let model = D200XModel(session: session, sender: makeSender { posted.append($0) })
        model.synchronize(configuration, canEdit: true)
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        for state in [UInt8(2), 3, 4, 5] {
            try await session.emit(input(index: 17, family: 2, state: state), generation: 1)
        }

        let allGesturesDelivered = await eventually { posted.count == 4 }
        XCTAssertTrue(allGesturesDelivered)
        XCTAssertEqual(posted, [left, right, heldLeft, heldRight])
    }

    func testStaleDisconnectedAndSuspendedInputDoesNotDeliver() async throws {
        let session = FixtureD200XSession()
        let shortcut = KeyboardShortcut(keyCode: 12)
        var posted = [KeyboardShortcut]()
        let model = D200XModel(
            session: session,
            sender: makeSender { posted.append($0) }
        )
        model.synchronize(
            D200XConfiguration(defaults: [D200XControl.key0.rawValue: .key(shortcut)]),
            canEdit: true
        )
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        try await session.emit(input(index: 0, family: 1, state: 1), generation: 0)
        await session.emit(.status(.disconnected, generation: 1))
        let staleInputProcessed = await eventually { model.status == .disconnected }
        XCTAssertTrue(staleInputProcessed)
        XCTAssertTrue(posted.isEmpty)

        try await session.emit(input(index: 0, family: 1, state: 1), generation: 1)
        await session.emit(.status(.connecting, generation: 1))
        let disconnectedInputProcessed = await eventually { model.status == .connecting }
        XCTAssertTrue(disconnectedInputProcessed)
        XCTAssertTrue(posted.isEmpty)

        await session.emit(.status(.connected(try identity()), generation: 1))
        let reconnected = await eventually { model.isConnected }
        XCTAssertTrue(reconnected)
        model.suspendDelivery(true)
        try await session.emit(input(index: 0, family: 1, state: 1), generation: 1)
        await session.emit(.status(.disconnected, generation: 1))
        let suspendedInputProcessed = await eventually { model.status == .disconnected }
        XCTAssertTrue(suspendedInputProcessed)
        XCTAssertTrue(posted.isEmpty)
    }

    func testAppearanceChangeSendsOnlyChangedSlotsAsIncrementalPage() async throws {
        let session = FixtureD200XSession()
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(.empty, canEdit: true)
        model.connect()

        let initialPageSent = await eventually { await session.pageApplications().count == 1 }
        XCTAssertTrue(initialPageSent)
        let initialApplications = await session.pageApplications()
        let initial = initialApplications[0]
        guard case .replace = initial.update else {
            XCTFail("The first page must replace the device page.")
            return
        }
        XCTAssertEqual(initial.page.slots.count, 14)

        var updated = D200XConfiguration.empty
        updated.tiles[D200XControl.key0.rawValue] = D200XTileAppearance(
            label: "Updated",
            backgroundHex: "112233"
        )
        model.synchronize(updated, canEdit: true)

        let incrementalPageSent = await eventually { await session.pageApplications().count == 2 }
        XCTAssertTrue(incrementalPageSent)
        let incrementalApplications = await session.pageApplications()
        let incremental = incrementalApplications[1]
        guard case .incremental = incremental.update else {
            XCTFail("A tile appearance change must use an incremental page update.")
            return
        }
        XCTAssertEqual(incremental.page.slots.keys.sorted(), ["0_0"])
    }

    func testAppearanceEditsDuringPageUploadCoalesceToLatestIncrementalPage() async throws {
        let session = FixtureD200XSession(holdFirstApply: true)
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(.empty, canEdit: true)
        model.connect()

        let firstUploadStarted = await eventually { await session.pageApplications().count == 1 }
        XCTAssertTrue(firstUploadStarted)

        var sameTileEdit = D200XConfiguration.empty
        sameTileEdit.tiles[D200XControl.key0.rawValue] = D200XTileAppearance(
            label: "Temporary",
            backgroundHex: "112233"
        )
        model.synchronize(sameTileEdit, canEdit: true)
        model.synchronize(.empty, canEdit: true)
        var latestConfiguration = D200XConfiguration.empty
        latestConfiguration.tiles[D200XControl.key1.rawValue] = D200XTileAppearance(
            label: "Latest",
            backgroundHex: "445566"
        )
        model.synchronize(latestConfiguration, canEdit: true)
        try await Task.sleep(for: .milliseconds(200))

        let applicationsWhileHeld = await session.pageApplications()
        let connectionsWhileHeld = await session.connectionCount()
        let disconnectsWhileHeld = await session.disconnectCount()
        let activeWritesWhileHeld = await session.activeWriteCount()
        let maximumConcurrentWritesWhileHeld = await session.maximumConcurrentWrites()
        XCTAssertEqual(applicationsWhileHeld.count, 1)
        XCTAssertEqual(connectionsWhileHeld, 1)
        XCTAssertEqual(disconnectsWhileHeld, 0)
        XCTAssertEqual(activeWritesWhileHeld, 1)
        XCTAssertEqual(maximumConcurrentWritesWhileHeld, 1)

        await session.releaseFirstPage()

        let latestPageStarted = await eventually { await session.pageApplications().count == 2 }
        XCTAssertTrue(latestPageStarted)
        try await Task.sleep(for: .milliseconds(200))
        let applications = await session.pageApplications()
        guard case .replace = applications[0].update else {
            XCTFail("The first page must replace the device page.")
            return
        }
        guard case .incremental = applications[1].update else {
            XCTFail("Changes during an upload must follow with an incremental page.")
            return
        }
        XCTAssertEqual(applications[1].page.slots.keys.sorted(), ["1_0"])
        XCTAssertEqual(applications[1].page.slots.count, 1)
        let finalApplicationCount = await session.pageApplications().count
        let finalConnectionCount = await session.connectionCount()
        let finalDisconnectCount = await session.disconnectCount()
        let maximumConcurrentWrites = await session.maximumConcurrentWrites()
        let writeCancellationStates = await session.writeCancellationStates()
        XCTAssertEqual(finalApplicationCount, 2)
        XCTAssertEqual(finalConnectionCount, 1)
        XCTAssertEqual(finalDisconnectCount, 0)
        XCTAssertEqual(maximumConcurrentWrites, 1)
        XCTAssertEqual(writeCancellationStates, [false, false])
    }

    func testStopCancelsPendingRenderAndRetry() async throws {
        let renderSession = FixtureD200XSession()
        let renderModel = D200XModel(session: renderSession, sender: makeSender())
        renderModel.synchronize(.empty, canEdit: true)
        renderModel.connect()
        let connected = await eventually { renderModel.isConnected }
        XCTAssertTrue(connected)

        await renderModel.stop()
        try await Task.sleep(for: .milliseconds(200))
        let renderedAfterStop = await renderSession.pageApplications().count
        XCTAssertEqual(renderedAfterStop, 0)

        let retrySession = FixtureD200XSession(connectFailures: 1)
        let retryWait = RetryWaitSignal()
        let retryModel = D200XModel(
            session: retrySession,
            sender: makeSender(),
            delay: { duration in
                await retryWait.signal()
                try await Task.sleep(for: duration)
            }
        )
        retryModel.synchronize(.empty, canEdit: true)
        retryModel.connect()
        let retryStarted = await eventually { await retryWait.didSignal }
        XCTAssertTrue(retryStarted)

        await retryModel.stop()

        let retryConnectionCount = await retrySession.connectionCount()
        let retryDisconnectCount = await retrySession.disconnectCount()
        XCTAssertEqual(retryConnectionCount, 1)
        XCTAssertEqual(retryDisconnectCount, 1)
    }

    func testPersistentPageFailureStopsAfterThreeRetries() async throws {
        let session = FixtureD200XSession(pageFailures: 4)
        let retryWait = RetryWaitSignal()
        let model = D200XModel(
            session: session,
            sender: makeSender(),
            delay: { _ in await retryWait.signal() }
        )
        model.synchronize(.empty, canEdit: true)
        model.connect()

        let retryBudgetExhausted = await eventually {
            let pageAttempts = await session.pageApplications().count
            let retries = await retryWait.signalCount()
            return pageAttempts == 4 && retries == 3 && model.status == .failed(.transport)
        }
        XCTAssertTrue(retryBudgetExhausted)
        try await Task.sleep(for: .milliseconds(200))

        let pageAttempts = await session.pageApplications().count
        let connectionAttempts = await session.connectionCount()
        let retryDelays = await retryWait.signalCount()
        XCTAssertEqual(pageAttempts, 4)
        XCTAssertEqual(connectionAttempts, 4)
        XCTAssertEqual(retryDelays, 3)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFailureEventBeforePageThrowAllowsReplacementRenderAfterReconnect() async throws {
        let session = FixtureD200XSession(pageFailures: 1, holdFirstFailureBeforeThrow: true)
        let model = D200XModel(
            session: session,
            sender: makeSender(),
            delay: { _ in }
        )
        model.synchronize(.empty, canEdit: true)
        model.connect()

        let replacementConnectionReady = await eventually {
            let connections = await session.connectionCount()
            return connections == 2 && model.isConnected
        }
        XCTAssertTrue(replacementConnectionReady)
        await session.releaseFirstFailure()

        let replacementPageSent = await eventually {
            let results = await session.pageResults()
            return results == [false, true] && model.message == "Page sent to D200X."
        }
        XCTAssertTrue(replacementPageSent)

        let applications = await session.pageApplications()
        let connectionAttempts = await session.connectionCount()
        let pageResults = await session.pageResults()
        XCTAssertEqual(connectionAttempts, 2)
        XCTAssertEqual(pageResults, [false, true])
        XCTAssertEqual(applications.count, 2)
        for application in applications {
            guard case .replace = application.update else {
                XCTFail("A replacement connection must receive a complete page after a failed transfer.")
                return
            }
        }
        XCTAssertTrue(model.isConnected)
        XCTAssertNil(model.errorMessage)
    }

    func testAggregateMenuBarStatusPreservesMouseAndDeckOutcomes() throws {
        let permissions = PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: true)
        let connectedMouse = MenuBarStatus(
            phase: .enabled,
            cleanupUncertain: false,
            permissionChecks: permissions
        )
        let disconnectedMouse = MenuBarStatus(
            phase: .idle,
            cleanupUncertain: false,
            permissionChecks: permissions
        )
        let connectedDeck = D200XStatus.connected(try identity())
        let cases: [(MenuBarStatus, D200XStatus?, MenuBarStatus)] = [
            (connectedMouse, nil, .connected),
            (connectedMouse, .disconnected, .partiallyConnected),
            (disconnectedMouse, connectedDeck, .partiallyConnected),
            (connectedMouse, connectedDeck, .connected),
            (.failed, connectedDeck, .failed),
            (connectedMouse, .failed(.transport), .failed),
            (.connecting, connectedDeck, .connecting),
            (connectedMouse, .connecting, .connecting)
        ]

        for (mouse, deck, expected) in cases {
            XCTAssertEqual(MenuBarStatus(mouse: mouse, deck: deck), expected)
        }
        XCTAssertEqual(
            MenuBarStatus(mouse: connectedMouse, deck: .disconnected).iconColor,
            .permissionIncomplete
        )
    }

    private func makeSender(postPair: @escaping (KeyboardShortcut) -> Void = { _ in }) -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { false }, postPair: postPair)
    }

    private func input(index: UInt8, family: UInt8, state: UInt8) throws -> D200XInput {
        try D200XInput(payload: Data([1, index, family, state]))
    }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private struct D200XPageApplication: Sendable {
    let page: D200XPage
    let update: D200XPageUpdate
}

private actor FixtureD200XSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private var connects = 0
    private var disconnects = 0
    private var generation: UInt64 = 0
    private var failuresRemaining: Int
    private var pageFailuresRemaining: Int
    private var applications = [D200XPageApplication]()
    private var results = [Bool]()
    private var activeWrites = 0
    private var maximumWrites = 0
    private var cancelledWrites = [Bool]()
    private let holdFirstApply: Bool
    private let holdFirstFailureBeforeThrow: Bool
    private let firstApplyGate = AsyncGate()
    private let firstFailureGate = AsyncGate()

    init(connectFailures: Int = 0, holdFirstApply: Bool = false,
         pageFailures: Int = 0, holdFirstFailureBeforeThrow: Bool = false) {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        failuresRemaining = connectFailures
        pageFailuresRemaining = pageFailures
        self.holdFirstApply = holdFirstApply
        self.holdFirstFailureBeforeThrow = holdFirstFailureBeforeThrow
    }

    func connect() async throws {
        connects += 1
        generation += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw D200XFailure.transport
        }
        continuation.yield(.status(.connecting, generation: generation))
        continuation.yield(.status(.connected(try identity()), generation: generation))
    }

    func disconnect() async {
        disconnects += 1
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {
        let isFirstPage = applications.isEmpty
        applications.append(D200XPageApplication(page: page, update: update))
        activeWrites += 1
        maximumWrites = max(maximumWrites, activeWrites)
        if holdFirstApply, isFirstPage {
            await firstApplyGate.wait()
        }
        if pageFailuresRemaining > 0 {
            pageFailuresRemaining -= 1
            results.append(false)
            continuation.yield(.status(.failed(.transport), generation: generation))
            if holdFirstFailureBeforeThrow, isFirstPage {
                await firstFailureGate.wait()
            }
            cancelledWrites.append(Task.isCancelled)
            activeWrites -= 1
            throw D200XFailure.transport
        }
        results.append(true)
        cancelledWrites.append(Task.isCancelled)
        activeWrites -= 1
    }

    func emit(_ event: D200XSessionEvent) {
        continuation.yield(event)
    }

    func emit(_ input: D200XInput, generation: UInt64) {
        continuation.yield(.input(input, generation: generation))
    }

    func connectionCount() -> Int { connects }
    func disconnectCount() -> Int { disconnects }
    func pageApplications() -> [D200XPageApplication] { applications }
    func pageResults() -> [Bool] { results }
    func activeWriteCount() -> Int { activeWrites }
    func maximumConcurrentWrites() -> Int { maximumWrites }
    func writeCancellationStates() -> [Bool] { cancelledWrites }
    func releaseFirstPage() async { await firstApplyGate.open() }
    func releaseFirstFailure() async { await firstFailureGate.open() }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RetryWaitSignal {
    private var signals = 0

    var didSignal: Bool { signals > 0 }

    func signal() {
        signals += 1
    }

    func signalCount() -> Int { signals }
}
