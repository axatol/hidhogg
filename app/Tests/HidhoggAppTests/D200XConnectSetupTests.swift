import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import MacOSActions
import UlanziD200X

@MainActor
final class D200XConnectSetupTests: XCTestCase {
    func testDisabledManagementBlocksManualConnectionAndActionsWhileKeepingConfiguration() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        model.synchronize(.empty, canEdit: true)
        model.setListening(true)
        model.setManagementEnabled(false)
        model.connect()
        model.suspendDelivery(false)
        model.sleep()
        model.wake()
        let count = await session.connectionCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(model.canRunConfiguredActions)
        XCTAssertFalse(model.isListening)
        XCTAssertEqual(model.configuration, .empty)
        await model.stop()
    }

    func testManualConnectCreatesConfigurationSynchronouslyAndConnects() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        var edited = [D200XConfiguration]()
        model.onEdit = { configuration in
            edited.append(configuration)
            model.synchronize(configuration, canEdit: true)
        }
        model.synchronize(nil, canEdit: true)

        model.connect()

        let connected = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 1 && model.isConnected
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(edited, [.empty])
        XCTAssertEqual(model.configuration, .empty)
        XCTAssertNil(model.errorMessage)
        await model.stop()
    }

    func testStartupConnectDoesNotCreateConfigurationOrQuerySession() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        var editCount = 0
        model.onEdit = { _ in editCount += 1 }
        model.synchronize(nil, canEdit: true)

        model.connect(configureIfNeeded: false)

        let connectionCount = await session.connectionCount()
        XCTAssertEqual(editCount, 0)
        XCTAssertNil(model.configuration)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.message, "Disconnected. Connect to discover D200X.")
        XCTAssertEqual(connectionCount, 0)
    }

    func testConfigurationBlockerIsVisibleAndPreventsCreationAndConnection() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        let blocker = "Configuration validation failed."
        var editCount = 0
        model.onEdit = { _ in editCount += 1 }
        model.synchronize(nil, canEdit: false, blocker: blocker)

        model.connect()

        let connectionCount = await session.connectionCount()
        XCTAssertNil(model.configuration)
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(model.configurationBlocker, blocker)
        XCTAssertEqual(model.errorMessage, blocker)
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(connectionCount, 0)
    }

    func testNonEditableManualConnectShowsFallbackBlocker() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        model.synchronize(nil, canEdit: false)

        model.connect()

        let connectionCount = await session.connectionCount()
        XCTAssertEqual(model.configurationBlocker, "D200X configuration cannot be edited right now.")
        XCTAssertEqual(model.errorMessage, model.configurationBlocker)
        XCTAssertEqual(connectionCount, 0)
    }

    func testConnectStopsWhenConfigurationEditIsNotAccepted() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        var edited = [D200XConfiguration]()
        model.onEdit = { edited.append($0) }
        model.synchronize(nil, canEdit: true)

        model.connect()

        let connectionCount = await session.connectionCount()
        XCTAssertEqual(edited, [.empty])
        XCTAssertNil(model.configuration)
        XCTAssertEqual(
            model.errorMessage,
            "D200X configuration is unavailable. Resolve the configuration issue before connecting."
        )
        XCTAssertEqual(connectionCount, 0)
    }

    func testExistingConfigurationConnectsWithoutEditingIt() async {
        let session = ConnectSetupSession()
        let model = makeModel(session: session)
        var editCount = 0
        model.onEdit = { _ in editCount += 1 }
        model.synchronize(.empty, canEdit: true)

        model.connect()

        let connected = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 1 && model.isConnected
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(model.configuration, .empty)
        XCTAssertEqual(editCount, 0)
        await model.stop()
    }

    private func makeModel(session: ConnectSetupSession) -> D200XModel {
        D200XModel(
            session: session,
            sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in })
        )
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor ConnectSetupSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private var connections = 0
    private var generation: UInt64 = 0

    init() {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        connections += 1
        generation &+= 1
        let identity = try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
        continuation.yield(.status(.connecting, generation: generation))
        continuation.yield(.status(.connected(identity), generation: generation))
    }

    func disconnect() async {
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws { }

    func connectionCount() -> Int { connections }
}
