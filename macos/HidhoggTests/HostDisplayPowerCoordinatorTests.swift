import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class HostDisplayPowerCoordinatorTests: XCTestCase {
    func testDelayedWriteIsFollowedByTheLatestDesiredStateSerially() async {
        let oldEndpoint = endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let client = DisplayHostStateClientStub(
            instanceID: oldEndpoint.instanceID,
            blockFirstCall: true
        )
        let coordinator = HostDisplayPowerCoordinator(
            observer: observer,
            clientFactory: DisplayHostStateClientFactory(clients: [
                oldEndpoint.instanceID: client
            ]),
            requestIDProvider: FixedRequestIDProvider()
        )

        coordinator.start()
        coordinator.setRuntimeEndpoint(oldEndpoint)
        let started = await waitForCall(client)
        XCTAssertTrue(started)

        observer.emit(false)
        client.firstCallReleased.signal()
        await coordinator.waitForIdle()

        XCTAssertEqual(client.displayAwakeValues, [true, false])
        XCTAssertEqual(client.maximumConcurrentCalls, 1)
        XCTAssertEqual(coordinator.desiredDisplayAwake, false)
        XCTAssertNil(coordinator.errorText)
        await coordinator.shutdown()
        XCTAssertEqual(observer.stopCount, 1)
    }

    func testEndpointReplacementUsesCurrentStateAfterAnOldReplyArrives() async {
        let oldEndpoint = endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let newEndpoint = endpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let oldClient = DisplayHostStateClientStub(
            instanceID: oldEndpoint.instanceID,
            blockFirstCall: true
        )
        let newClient = DisplayHostStateClientStub(instanceID: newEndpoint.instanceID)
        let coordinator = HostDisplayPowerCoordinator(
            observer: observer,
            clientFactory: DisplayHostStateClientFactory(clients: [
                oldEndpoint.instanceID: oldClient,
                newEndpoint.instanceID: newClient
            ]),
            requestIDProvider: FixedRequestIDProvider()
        )

        coordinator.start()
        coordinator.setRuntimeEndpoint(oldEndpoint)
        let started = await waitForCall(oldClient)
        XCTAssertTrue(started)

        observer.emit(false)
        coordinator.setRuntimeEndpoint(newEndpoint)
        oldClient.firstCallReleased.signal()
        await coordinator.waitForIdle()

        XCTAssertEqual(oldClient.displayAwakeValues, [true])
        XCTAssertEqual(newClient.displayAwakeValues, [false])
        XCTAssertEqual(coordinator.runtimeEndpoint, newEndpoint)
        XCTAssertEqual(coordinator.desiredDisplayAwake, false)
        await coordinator.shutdown()
    }

    func testUnknownInitialStateDoesNotSendSpeculativeDarkState() async {
        let activeEndpoint = endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let observer = FakeHostDisplayPowerObserver(
            initialState: nil,
            reconciliationState: nil,
            initialError: "display query failed"
        )
        let client = DisplayHostStateClientStub(instanceID: activeEndpoint.instanceID)
        let coordinator = HostDisplayPowerCoordinator(
            observer: observer,
            clientFactory: DisplayHostStateClientFactory(clients: [
                activeEndpoint.instanceID: client
            ]),
            requestIDProvider: FixedRequestIDProvider()
        )

        coordinator.start()
        coordinator.setRuntimeEndpoint(activeEndpoint)
        await coordinator.waitForIdle()

        XCTAssertNil(coordinator.desiredDisplayAwake)
        XCTAssertEqual(coordinator.errorText, "display query failed")
        XCTAssertEqual(observer.reconciliationCount, 1)
        XCTAssertEqual(client.callCount, 0)
        await coordinator.shutdown()
    }

    func testOutcomeUnknownWriteIsNotRetriedButReplacementGetsFreshApplication() async throws {
        let oldEndpoint = endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let newEndpoint = endpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let failingClient = DisplayHostStateClientStub(
            instanceID: oldEndpoint.instanceID,
            failsAllCalls: true
        )
        let replacementClient = DisplayHostStateClientStub(instanceID: newEndpoint.instanceID)
        let coordinator = HostDisplayPowerCoordinator(
            observer: observer,
            clientFactory: DisplayHostStateClientFactory(clients: [
                oldEndpoint.instanceID: failingClient,
                newEndpoint.instanceID: replacementClient
            ]),
            requestIDProvider: FixedRequestIDProvider()
        )

        coordinator.start()
        coordinator.setRuntimeEndpoint(oldEndpoint)
        await coordinator.waitForIdle()
        XCTAssertEqual(failingClient.callCount, 1)
        let failureText = try XCTUnwrap(coordinator.errorText)

        observer.emit(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(failingClient.callCount, 1)
        XCTAssertEqual(coordinator.errorText, failureText)

        coordinator.setRuntimeEndpoint(newEndpoint)
        await coordinator.waitForIdle()
        XCTAssertEqual(replacementClient.displayAwakeValues, [true])
        XCTAssertNil(coordinator.errorText)
        await coordinator.shutdown()
    }

    private func endpoint(instanceID: String) -> RuntimeSessionController.RuntimeEndpoint {
        RuntimeSessionController.RuntimeEndpoint(
            instanceID: instanceID,
            socketPath: "/private/tmp/\(instanceID).sock"
        )
    }

    private func waitForCall(_ client: DisplayHostStateClientStub) async -> Bool {
        for _ in 0..<300 {
            if client.callCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

@MainActor
private final class FakeHostDisplayPowerObserver: HostDisplayPowerObserving {
    private(set) var lastKnownDisplayAwake: Bool?
    private let initialState: Bool?
    private let reconciliationState: Bool?
    private let initialError: String?
    private var stateHandler: HostDisplayPowerStateHandler?
    private var errorHandler: HostDisplayPowerErrorHandler?
    private(set) var reconciliationCount = 0
    private(set) var stopCount = 0

    init(
        initialState: Bool?,
        reconciliationState: Bool? = nil,
        initialError: String? = nil
    ) {
        self.initialState = initialState
        self.reconciliationState = reconciliationState
        self.initialError = initialError
    }

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
        if let initialError {
            errorHandler(initialError)
        }
        if let initialState {
            emit(initialState)
        }
    }

    func reconcileIfUnknown() {
        reconciliationCount += 1
        guard lastKnownDisplayAwake == nil, let reconciliationState else { return }
        emit(reconciliationState)
    }

    func stop() {
        stopCount += 1
        stateHandler = nil
        errorHandler = nil
    }

    func emit(_ displayAwake: Bool) {
        guard lastKnownDisplayAwake != displayAwake else { return }
        lastKnownDisplayAwake = displayAwake
        errorHandler?(nil)
        stateHandler?(displayAwake)
    }
}

private struct FixedRequestIDProvider: RequestIDProviding {
    func makeRequestID() -> String {
        "11111111-1111-4111-8111-111111111111"
    }
}

private final class DisplayHostStateClientFactory: RuntimeDisplayHostStateClientCreating, @unchecked Sendable {
    private let clients: [String: DisplayHostStateClientStub]

    init(clients: [String: DisplayHostStateClientStub]) {
        self.clients = clients
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeDisplayHostStateChecking {
        guard let client = clients[instanceID] else {
            throw UnixSocketClientError.invalidRequest
        }
        return client
    }
}

private final class DisplayHostStateClientStub: RuntimeDisplayHostStateChecking, @unchecked Sendable {
    let firstCallReleased = DispatchSemaphore(value: 0)

    private let instanceID: String
    private let blockFirstCall: Bool
    private let failsAllCalls: Bool
    private let lock = NSLock()
    private var calls: [(Bool, String)] = []
    private var inFlightCount = 0
    private var maximumInFlightCount = 0

    init(instanceID: String, blockFirstCall: Bool = false, failsAllCalls: Bool = false) {
        self.instanceID = instanceID
        self.blockFirstCall = blockFirstCall
        self.failsAllCalls = failsAllCalls
    }

    var displayAwakeValues: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.0)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumInFlightCount
    }

    func setDisplayHostState(
        displayAwake: Bool,
        requestID: String
    ) throws -> DisplayHostStateResponse {
        lock.lock()
        let callIndex = calls.count
        calls.append((displayAwake, requestID))
        inFlightCount += 1
        maximumInFlightCount = max(maximumInFlightCount, inFlightCount)
        lock.unlock()

        if callIndex == 0 {
            if blockFirstCall {
                firstCallReleased.wait()
            }
        }

        lock.lock()
        inFlightCount -= 1
        lock.unlock()

        if failsAllCalls {
            throw UnixSocketClientError.connectionClosed
        }
        return DisplayHostStateResponse(
            requestID: requestID,
            instanceID: instanceID,
            displayAwake: displayAwake,
            changed: true
        )
    }
}
