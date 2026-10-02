import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class ProfileSwitchCoordinatorTests: XCTestCase {
    func testInitialMatchingApplicationActivatesMappedProfile() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testUnmappedApplicationActivatesDefaultAfterMappedApplicationAndOnlyOnce() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        source.emit("com.example.unmapped")
        await coordinator.waitForIdle()
        source.emit("com.example.unmapped")
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile", "Default"])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testUnmappedApplicationAlreadyOnDefaultDoesNotActivate() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.unmapped")
        let coordinator = makeCoordinator(client: client)

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testNilAndEmptyEventsClearForegroundIdentityWithoutChangingProfile() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        let listCount = client.listCount

        source.emit(nil)
        source.emit("")
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
        XCTAssertEqual(client.listCount, listCount)
        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testClearedForegroundIdentityIsNotReusedByMappingEditOrEndpointReplacement() async throws {
        let oldClient = RecordingProfileClient(currentProfileID: "Default")
        let newClient = RecordingProfileClient(currentProfileID: "Work.Profile")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let factory = EndpointClientFactory(clients: [
            "old": oldClient,
            "new": newClient
        ])
        let coordinator = ProfileSwitchCoordinator(
            mappings: ProfileMappingPreferences(mappings: ["com.example.editor": "Work.Profile"]),
            clientFactory: factory
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "old"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        source.emit(nil)
        await coordinator.waitForIdle()
        source.emit("")
        await coordinator.waitForIdle()
        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        _ = try coordinator.setMapping(
            profileID: "Gaming.Profile",
            forBundleIdentifier: "com.example.editor"
        )
        await coordinator.waitForIdle()
        XCTAssertEqual(oldClient.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "new"))
        await coordinator.waitForIdle()
        XCTAssertEqual(newClient.listCount, 1)
        XCTAssertEqual(newClient.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))

        source.emit("com.example.editor")
        await coordinator.waitForIdle()
        XCTAssertEqual(newClient.activationIDs, ["Gaming.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Gaming.Profile")
    }

    func testNilEventDuringCatalogReadPreventsStaleActivation() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        client.blockNextList()
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        coordinator.startObserving(source)
        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        for _ in 0..<100 where !client.listHasStarted {
            await Task.yield()
        }
        XCTAssertTrue(client.listHasStarted)

        source.emit(nil)
        client.continueBlockedList.signal()
        await coordinator.waitForIdle()

        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(client.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testExplicitCatalogRefreshDoesNotActivateProfile() async {
        let client = RecordingProfileClient(currentProfileID: "Work.Profile")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Gaming.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.refreshCatalog()
        await coordinator.waitForIdle()

        XCTAssertEqual(client.listCount, 1)
        XCTAssertEqual(client.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testRepeatedSameEffectiveProfileDoesNotActivateAgain() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
        XCTAssertEqual(client.listCount, 2)
    }

    func testRapidAThenBEventsSerializeActivationInArrivalOrder() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        client.blockProfileID = "Work.Profile"
        let source = TestForegroundObserver(initialBundleIdentifier: nil)
        let coordinator = makeCoordinator(
            client: client,
            mappings: [
                "com.example.a": "Work.Profile",
                "com.example.b": "Gaming.Profile"
            ]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        source.emit("com.example.a")
        for _ in 0..<100 where coordinator.state != .switching(profileID: "Work.Profile") {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.state, .switching(profileID: "Work.Profile"))
        var activationStarted = false
        for _ in 0..<100 {
            if client.activationHasStarted {
                activationStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(activationStarted)
        source.emit("com.example.b")
        client.continueBlockedActivation.signal()
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile", "Gaming.Profile"])
    }

    func testMappingToMissingCatalogProfileIsRejectedWithoutActivation() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Missing.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, [])
        XCTAssertEqual(
            coordinator.state,
            .invalidMapping(bundleIdentifier: "com.example.editor", profileID: "Missing.Profile")
        )
    }

    func testUnavailableRuntimeDoesNotIssueActivationAndRecoversOnEndpoint() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .waitingForRuntime)
        XCTAssertEqual(client.listCount, 0)

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
    }

    func testOutcomeUnknownWaitsForNewEventBeforeRetrying() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        client.activationError = true
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .outcomeUnknown(profileID: "Work.Profile"))
        XCTAssertEqual(client.activationIDs, ["Work.Profile"])

        client.activationError = false
        await coordinator.waitForIdle()
        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile", "Work.Profile"])
    }

    func testMappingEditReevaluatesCurrentForegroundApplication() async throws {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(client: client)

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))

        _ = try coordinator.setMapping(
            profileID: "Work.Profile",
            forBundleIdentifier: "com.example.editor"
        )
        await coordinator.waitForIdle()

        XCTAssertEqual(client.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
    }

    func testEndpointReplacementDiscardsOldCatalogAndReevaluatesCurrentApplication() async {
        let oldClient = RecordingProfileClient(currentProfileID: "Default")
        let newClient = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let factory = EndpointClientFactory(clients: [
            "old": oldClient,
            "new": newClient
        ])
        let coordinator = ProfileSwitchCoordinator(
            mappings: ProfileMappingPreferences(mappings: ["com.example.editor": "Work.Profile"]),
            clientFactory: factory
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "old"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "new"))
        await coordinator.waitForIdle()

        XCTAssertEqual(oldClient.activationIDs, ["Work.Profile"])
        XCTAssertEqual(newClient.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.runtimeEndpoint?.instanceID, "new")
    }

    func testEndpointReplacementWaitsForBlockedActivationBeforeFinalizing() async {
        let oldClient = RecordingProfileClient(currentProfileID: "Default")
        oldClient.blockProfileID = "Work.Profile"
        let newClient = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let factory = EndpointClientFactory(clients: [
            "old": oldClient,
            "new": newClient
        ])
        let coordinator = ProfileSwitchCoordinator(
            mappings: ProfileMappingPreferences(mappings: ["com.example.editor": "Work.Profile"]),
            clientFactory: factory
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "old"))
        coordinator.startObserving(source)
        for _ in 0..<100 where !oldClient.activationHasStarted {
            await Task.yield()
        }
        XCTAssertTrue(oldClient.activationHasStarted)

        let replacement = Task { @MainActor in
            await coordinator.setRuntimeEndpoint(endpoint(instanceID: "new"))
        }
        for _ in 0..<100 {
            await Task.yield()
            if oldClient.inFlightCount > 0 { break }
        }

        XCTAssertEqual(coordinator.runtimeEndpoint?.instanceID, "old")
        XCTAssertEqual(newClient.listCount, 0)
        XCTAssertGreaterThan(oldClient.inFlightCount, 0)

        oldClient.continueBlockedActivation.signal()
        await replacement.value
        await coordinator.waitForIdle()

        XCTAssertEqual(oldClient.inFlightCount, 0)
        XCTAssertEqual(newClient.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.runtimeEndpoint?.instanceID, "new")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testShutdownStopsObservationAndAdmission() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: nil)
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        await coordinator.shutdown()
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertEqual(client.activationIDs, [])
        XCTAssertEqual(source.stopCount, 1)
    }

    func testShutdownWaitsForBlockedActivationBeforeFinalizing() async {
        let client = RecordingProfileClient(currentProfileID: "Default")
        client.blockProfileID = "Work.Profile"
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(
            client: client,
            mappings: ["com.example.editor": "Work.Profile"]
        )

        await coordinator.setRuntimeEndpoint(endpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        coordinator.startObserving(source)
        for _ in 0..<100 where !client.activationHasStarted {
            await Task.yield()
        }
        XCTAssertTrue(client.activationHasStarted)

        let shutdown = Task { @MainActor in
            await coordinator.shutdown()
        }
        for _ in 0..<100 {
            await Task.yield()
            if client.inFlightCount > 0 { break }
        }

        XCTAssertNotEqual(coordinator.state, .stopped)
        XCTAssertGreaterThan(client.inFlightCount, 0)

        source.emit("com.example.editor")
        XCTAssertEqual(client.activationIDs, ["Work.Profile"])

        client.continueBlockedActivation.signal()
        await shutdown.value

        XCTAssertEqual(client.inFlightCount, 0)
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertNil(coordinator.runtimeEndpoint)
    }

    private func makeCoordinator(
        client: RecordingProfileClient,
        mappings: [String: String] = [:]
    ) -> ProfileSwitchCoordinator {
        ProfileSwitchCoordinator(
            mappings: ProfileMappingPreferences(mappings: mappings),
            client: client
        )
    }

    private func endpoint(instanceID: String) -> RuntimeSessionController.RuntimeEndpoint {
        RuntimeSessionController.RuntimeEndpoint(instanceID: instanceID, socketPath: "/private/tmp/runtime.sock")
    }
}

private enum TestProfileClientError: Error {
    case activationFailed
}

private final class RecordingProfileClient: @unchecked Sendable, RuntimeProfileChecking {
    private let lock = NSLock()
    private var currentProfileIDStorage: String
    private var activationIDsStorage: [String] = []
    private var listCountStorage = 0
    private var blockNextListStorage = false
    private var listHasStartedStorage = false
    private var inFlightCountStorage = 0
    private var activationHasStartedStorage = false
    var activationError = false
    var blockProfileID: String?
    let continueBlockedActivation = DispatchSemaphore(value: 0)
    let continueBlockedList = DispatchSemaphore(value: 0)

    init(currentProfileID: String) {
        currentProfileIDStorage = currentProfileID
    }

    var activationIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return activationIDsStorage
    }

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listCountStorage
    }

    var listHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listHasStartedStorage
    }

    func blockNextList() {
        lock.lock()
        blockNextListStorage = true
        lock.unlock()
    }

    var activationHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activationHasStartedStorage
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightCountStorage
    }

    func listProfiles(requestID: String) throws -> ProfileListResponse {
        lock.lock()
        listCountStorage += 1
        inFlightCountStorage += 1
        let currentProfileID = currentProfileIDStorage
        let shouldBlock = blockNextListStorage
        blockNextListStorage = false
        listHasStartedStorage = true
        lock.unlock()
        defer {
            lock.lock()
            inFlightCountStorage -= 1
            lock.unlock()
        }
        if shouldBlock {
            continueBlockedList.wait()
        }
        return ProfileListResponse(
            requestID: requestID,
            instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            profiles: [
                ProfileSummary(id: "Default", label: "Default", isDefault: true, isCurrent: currentProfileID == "Default"),
                ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: currentProfileID == "Work.Profile"),
                ProfileSummary(id: "Gaming.Profile", label: "Gaming", isDefault: false, isCurrent: currentProfileID == "Gaming.Profile")
            ]
        )
    }

    func activateProfile(profileID: String, requestID: String) throws -> ProfileActivationResponse {
        lock.lock()
        activationIDsStorage.append(profileID)
        inFlightCountStorage += 1
        let shouldFail = activationError
        let shouldBlock = blockProfileID == profileID
        lock.unlock()
        defer {
            lock.lock()
            inFlightCountStorage -= 1
            lock.unlock()
        }
        if shouldBlock {
            lock.lock()
            activationHasStartedStorage = true
            lock.unlock()
            continueBlockedActivation.wait()
        }
        if shouldFail {
            throw TestProfileClientError.activationFailed
        }
        lock.lock()
        currentProfileIDStorage = profileID
        lock.unlock()
        return ProfileActivationResponse(requestID: requestID, profileID: profileID, changed: true)
    }
}

private final class EndpointClientFactory: RuntimeProfileClientCreating, @unchecked Sendable {
    private let clients: [String: RecordingProfileClient]

    init(clients: [String: RecordingProfileClient]) {
        self.clients = clients
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeProfileChecking {
        guard let client = clients[instanceID] else {
            throw TestProfileClientError.activationFailed
        }
        return client
    }
}

@MainActor
private final class TestForegroundObserver: ForegroundApplicationObserving {
    private let initialBundleIdentifier: String?
    private var handler: ForegroundApplicationHandler?
    private(set) var stopCount = 0

    init(initialBundleIdentifier: String?) {
        self.initialBundleIdentifier = initialBundleIdentifier
    }

    func start(handler: @escaping ForegroundApplicationHandler) {
        self.handler = handler
        handler(initialBundleIdentifier)
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ bundleIdentifier: String?) {
        handler?(bundleIdentifier)
    }
}
