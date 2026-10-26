import HidhoggAutomation
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp
import UlanziD200X

@MainActor
final class D200XParityIntegrationTests: XCTestCase {
    func testInactiveProfileEditPreservesActiveNotificationAndDoesNotWriteDeck() async throws {
        var foreground: String? = nil
        let session = D200XParitySession()
        let model = D200XModel(session: session, sender: makeSender(), frontmostApplication: { foreground })
        let configuration = D200XConfiguration(applications: ["com.example.Editor": [:]],
            notificationTopics: ["key0": ["build.*"]])
        model.synchronize(configuration, canEdit: true)
        model.onEdit = { [weak model] in model?.synchronize($0, canEdit: true) }
        model.connect()
        let baseline = await eventually { await session.pageApplications().count == 1 }
        XCTAssertTrue(baseline)
        let result = await model.publishNotification(topic: "build.finished", text: "Active overlay", ttlSeconds: nil)
        XCTAssertNil(result.error)
        let writesBefore = await session.pageApplications().count
        model.applicationID = "com.example.Editor"
        model.setAppearance(.init(label: "Inactive edit"))
        foreground = "com.example.Unmapped"
        model.refreshActiveApplication()
        try await Task.sleep(for: .milliseconds(250))
        let writesAfter = await session.pageApplications().count
        XCTAssertEqual(writesAfter, writesBefore)
        XCTAssertEqual(model.notificationLabels["key0"], "Active overlay")
        XCTAssertEqual(model.appearance.label, "Inactive edit")
        await model.stop()
    }

    func testProfileSwitchSerializesAfterStartedNotificationWrite() async throws {
        var foreground: String? = "com.example.Editor"
        let session = D200XParitySession(heldApplyIndex: 2)
        let model = D200XModel(session: session, sender: makeSender(), frontmostApplication: { foreground })
        let configuration = D200XConfiguration(
            applications: ["com.example.Editor": [:]],
            tiles: ["key0": .init(label: "Default")],
            applicationTiles: ["com.example.Editor": ["key0": .init(label: "Editor")]],
            applicationNotificationTopics: ["com.example.Editor": ["key0": ["build.*"]]])
        model.synchronize(configuration, canEdit: true)
        model.setListening(true)
        model.connect()
        let baseline = await eventually { await session.pageApplications().count == 1 }
        XCTAssertTrue(baseline)
        let notification = Task { await model.publishNotification(topic: "build.finished", text: "Complete", ttlSeconds: 5) }
        let started = await eventually { await session.pageApplications().count == 2 }
        XCTAssertTrue(started)
        foreground = "com.example.Unmapped"
        model.refreshActiveApplication()
        try await Task.sleep(for: .milliseconds(300))
        let whileHeld = await session.pageApplications()
        XCTAssertEqual(whileHeld.count, 2, "Profile transfer must wait for an already-started notification write")
        await session.resumeFirstApply()
        let response = await notification.value
        XCTAssertNotNil(response.error, "The old profile receipt must not commit in a new profile")
        let restored = await eventually { await session.pageApplications().count == 3 }
        XCTAssertTrue(restored)
        let applications = await session.pageApplications()
        let expected = try D200XPageRenderer.page(configuration: configuration.resolved(application: foreground))
        XCTAssertEqual(applications.last?.page.slots["0_0"], expected.slots["0_0"])
        XCTAssertEqual(model.liveNotifications.last?.profile, "com.example.Editor")
        XCTAssertEqual(model.liveNotifications.last?.outcome, "failed")
        await model.stop()
    }

    func testNotificationRefreshesForegroundBeforeMatchingProfile() async throws {
        var foreground: String? = nil
        let model = D200XModel(sender: makeSender(), frontmostApplication: { foreground })
        model.synchronize(D200XConfiguration(applications: ["com.example.Editor": [:]],
            applicationNotificationTopics: ["com.example.Editor": ["key0": ["build.*"]]]), canEdit: true)
        model.setListening(true)
        foreground = "com.example.Editor"
        let result = await model.publishNotification(topic: "build.finished", text: "Build", ttlSeconds: nil)
        XCTAssertNotNil(result.error, "Matched receipt on a disconnected device must fail rather than be unhandled")
        XCTAssertEqual(model.activeApplicationID, foreground)
        XCTAssertEqual(model.liveNotifications.last?.profile, foreground)
        XCTAssertEqual(model.liveNotifications.last?.controls, ["key0"])
        XCTAssertEqual(model.notificationHistory.last?.profile, foreground)
        await model.stop()
    }

    func testDisabledApplicationOverrideMasksDefaultActionAndInheritanceRestoresIt() throws {
        let actionID = "build-project"
        let action = ConfiguredExecutable(executable: "/usr/bin/true", arguments: ["--build"])
        let configuration = D200XConfiguration(
            defaults: ["key0": .action(actionID)],
            applications: ["com.example.Editor": ["key0": .disabled]],
            actions: [actionID: action]
        )
        let model = D200XModel(sender: makeSender())
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .key0
        model.applicationID = "com.example.Editor"

        XCTAssertEqual(model.binding, .disabled)
        XCTAssertFalse(model.isInherited)

        var editedConfiguration: D200XConfiguration?
        model.onEdit = { editedConfiguration = $0 }
        model.setBinding(nil)

        let updatedConfiguration = try XCTUnwrap(editedConfiguration)
        XCTAssertNil(updatedConfiguration.applications["com.example.Editor"]?["key0"])

        model.synchronize(updatedConfiguration, canEdit: true)

        XCTAssertTrue(model.isInherited)
        XCTAssertEqual(model.binding, .action(actionID))
        XCTAssertEqual(model.configuration?.actions[actionID], action)
    }

    func testConfiguredNotificationSourceRoutesToTileAndClearRestoresBaseline() async throws {
        let session = D200XParitySession()
        let configuration = notificationConfiguration(topic: "build")
        let model = makeModel(configuration: configuration, session: session)
        model.connect()

        let baselineRendered = await eventually {
            guard model.isConnected else { return false }
            return await session.pageApplications().count == 1
        }
        XCTAssertTrue(baselineRendered)
        let baselinePage = try D200XPageRenderer.page(configuration: configuration)
        let initialApplications = await session.pageApplications()
        XCTAssertEqual(initialApplications.first?.page, baselinePage)

        let emitted = await model.handleAutomation(notificationEmit(topic: "build"))

        XCTAssertNil(emitted.error)
        XCTAssertEqual(integerResult("matched_count", in: emitted), 1)
        XCTAssertEqual(integerResult("cleared_count", in: emitted), 0)
        let notificationIDValue = try XCTUnwrap(stringResult("notification_id", in: emitted))
        let unwrappedNotificationID = try XCTUnwrap(UUID(uuidString: notificationIDValue))
        let expectedNotificationPage = try D200XPageRenderer.page(
            configuration: configuration,
            labelOverrides: ["key0": "Battery low"]
        )
        let applicationsAfterEmit = await session.pageApplications()
        XCTAssertEqual(applicationsAfterEmit.count, 2)
        XCTAssertEqual(applicationsAfterEmit[1].page.slots.keys.sorted(), ["0_0"])
        XCTAssertEqual(applicationsAfterEmit[1].page.slots["0_0"], expectedNotificationPage.slots["0_0"])
        guard case .incremental = applicationsAfterEmit[1].update else {
            XCTFail("A notification should update the existing tile page incrementally.")
            await model.stop()
            return
        }
        XCTAssertEqual(model.notificationHistory.last?.notificationID, unwrappedNotificationID)
        XCTAssertEqual(model.notificationHistory.last?.outcome, "delivered")
        XCTAssertEqual(model.notificationHistory.last?.controls, ["key0"])

        let cleared = await model.handleAutomation(AutomationRequest(
            method: .notificationsClear,
            params: AutomationParameters(notificationID: unwrappedNotificationID)
        ))

        XCTAssertNil(cleared.error)
        XCTAssertEqual(integerResult("cleared_count", in: cleared), 1)
        let applicationsAfterClear = await session.pageApplications()
        XCTAssertEqual(applicationsAfterClear.count, 3)
        XCTAssertEqual(applicationsAfterClear[2].page.slots["0_0"], baselinePage.slots["0_0"])
        XCTAssertEqual(model.notificationHistory.last?.outcome, "cleared")
        XCTAssertEqual(model.notificationHistory.last?.controls, ["key0"])
        await model.stop()
    }

    func testDisconnectedMatchedNotificationFailsWithoutWritingOrRecordingDelivery() async throws {
        let session = D200XParitySession()
        let model = makeModel(configuration: notificationConfiguration(topic: "build"), session: session)
        model.connect()

        let baselineRendered = await eventually {
            guard model.isConnected else { return false }
            return await session.pageApplications().count == 1
        }
        XCTAssertTrue(baselineRendered)
        let initialApplicationCount = await session.pageApplications().count
        model.disconnect()
        let disconnected = await eventually { !model.isConnected }
        XCTAssertTrue(disconnected)

        let response = await model.handleAutomation(notificationEmit(topic: "build"))

        XCTAssertEqual(response.error?.code, "not_delivered")
        let pageApplicationCount = await session.pageApplications().count
        XCTAssertEqual(pageApplicationCount, initialApplicationCount)
        XCTAssertEqual(model.notificationHistory.last?.topic, "build")
        XCTAssertEqual(model.notificationHistory.last?.outcome, "failed")
        XCTAssertEqual(model.notificationHistory.last?.matchedCount, 0)
        XCTAssertTrue(model.notificationHistory.last?.controls.isEmpty == true)
        await model.stop()
    }

    func testUnmatchedNotificationIsRecordedAsUnhandledWithoutDeviceWrite() async {
        let session = D200XParitySession()
        let model = makeModel(configuration: .empty, session: session)
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        let response = await model.handleAutomation(notificationEmit(topic: "unobserved"))

        XCTAssertNil(response.error)
        XCTAssertEqual(integerResult("matched_count", in: response), 0)
        XCTAssertEqual(model.notificationHistory.last?.topic, "unobserved")
        XCTAssertEqual(model.notificationHistory.last?.outcome, "unhandled")
        XCTAssertEqual(model.notificationHistory.last?.matchedCount, 0)
        XCTAssertTrue(model.notificationHistory.last?.controls.isEmpty == true)
        let pageApplications = await session.pageApplications()
        XCTAssertTrue(pageApplications.isEmpty)
        await model.stop()
    }

    func testNotificationWaitsForStartedBaselineWriteWithoutCancellingIt() async throws {
        let session = D200XParitySession(holdFirstApply: true)
        let configuration = notificationConfiguration(topic: "build")
        let model = makeModel(configuration: configuration, session: session)
        model.connect()

        let firstWriteStarted = await eventually { await session.pageApplications().count == 1 }
        XCTAssertTrue(firstWriteStarted)
        let emit = Task { @MainActor in
            await model.handleAutomation(notificationEmit(topic: "build"))
        }
        for _ in 0..<32 { await Task.yield() }

        await session.resumeFirstApply()
        let response = await emit.value
        let overlayApplied = await eventually { await session.pageApplications().count == 2 }
        XCTAssertTrue(overlayApplied)
        XCTAssertNil(response.error)
        XCTAssertEqual(integerResult("matched_count", in: response), 1)
        let writeCancellationStates = await session.writeCancellationStates()
        let connectionCount = await session.connectionCount()
        let disconnectCount = await session.disconnectCount()
        XCTAssertEqual(writeCancellationStates, [false, false])
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertTrue(model.isConnected)
        await model.stop()
    }

    func testActionRequestRunsConfiguredDefinitionThroughFakeRunnerAndRejectsUnknownID() async {
        let fakeRunner = D200XParityProcessRunner()
        let actionRunner = ConfiguredActionRunner(processRunner: fakeRunner)
        let action = ConfiguredExecutable(
            executable: "/synthetic/build-task",
            arguments: ["literal;no-shell", "$(never-run)"]
        )
        let model = D200XModel(sender: makeSender(), actionRunner: actionRunner)
        model.synchronize(D200XConfiguration(actions: ["build-project": action]), canEdit: true)

        let invoked = await model.handleAutomation(AutomationRequest(
            method: .actionsInvoke,
            params: AutomationParameters(actionID: "build-project")
        ))
        let executionID = stringResult("execution_id", in: invoked)
        XCTAssertNil(invoked.error)
        XCTAssertNotNil(executionID.flatMap(UUID.init(uuidString:)))
        let invokedActions = await fakeRunner.actions()
        XCTAssertEqual(invokedActions, [action])

        let unknown = await model.handleAutomation(AutomationRequest(
            method: .actionsInvoke,
            params: AutomationParameters(actionID: "missing-action")
        ))

        XCTAssertEqual(unknown.error?.code, "unavailable")
        let actionsAfterUnknown = await fakeRunner.actions()
        XCTAssertEqual(actionsAfterUnknown, [action])
        await model.stop()
    }

    private func makeSender() -> ShortcutSender {
        ShortcutSender(
            preflight: { false },
            request: { false },
            postPair: { _ in }
        )
    }

    private func makeModel(
        configuration: D200XConfiguration,
        session: D200XParitySession
    ) -> D200XModel {
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(configuration, canEdit: true)
        return model
    }

    private func notificationConfiguration(topic: String) -> D200XConfiguration {
        D200XConfiguration(
            tiles: ["key0": D200XTileAppearance(label: "Baseline")],
            notificationTopics: ["key0": [topic]]
        )
    }

    private func notificationEmit(topic: String) -> AutomationRequest {
        AutomationRequest(
            method: .notificationsEmit,
            params: AutomationParameters(topic: topic, text: "Battery low")
        )
    }

    private func integerResult(_ key: String, in response: AutomationResponse) -> Int? {
        guard case .object(let result)? = response.result,
              case .integer(let value)? = result[key] else { return nil }
        return value
    }

    private func stringResult(_ key: String, in response: AutomationResponse) -> String? {
        guard case .object(let result)? = response.result,
              case .string(let value)? = result[key] else { return nil }
        return value
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private struct D200XParityPageApplication: Sendable {
    let page: D200XPage
    let update: D200XPageUpdate
}

private actor D200XParitySession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let eventContinuation: AsyncStream<D200XSessionEvent>.Continuation
    private let holdFirstApply: Bool
    private let heldApplyIndex: Int?
    private var generation: UInt64 = 0
    private var connects = 0
    private var disconnects = 0
    private var applications = [D200XParityPageApplication]()
    private var writeCancellations = [Bool]()
    private var firstApplyContinuation: CheckedContinuation<Void, Never>?

    init(holdFirstApply: Bool = false, heldApplyIndex: Int? = nil) {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        eventContinuation = stream.continuation
        self.holdFirstApply = holdFirstApply
        self.heldApplyIndex = heldApplyIndex
    }

    func connect() async throws {
        connects += 1
        generation += 1
        eventContinuation.yield(.status(.connecting, generation: generation))
        eventContinuation.yield(.status(.connected(try identity()), generation: generation))
    }

    func disconnect() async {
        disconnects += 1
        eventContinuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {
        let isFirstApply = applications.isEmpty
        applications.append(D200XParityPageApplication(page: page, update: update))
        if (holdFirstApply && isFirstApply) || applications.count == heldApplyIndex {
            await withCheckedContinuation { firstApplyContinuation = $0 }
        }
        writeCancellations.append(Task.isCancelled)
    }

    func pageApplications() -> [D200XParityPageApplication] { applications }
    func writeCancellationStates() -> [Bool] { writeCancellations }
    func connectionCount() -> Int { connects }
    func disconnectCount() -> Int { disconnects }

    func resumeFirstApply() {
        let continuation = firstApplyContinuation
        firstApplyContinuation = nil
        continuation?.resume()
    }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }
}

private actor D200XParityProcessRunner: ConfiguredProcessRunning {
    private var recordedActions = [ConfiguredExecutable]()

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        recordedActions.append(action)
        return ConfiguredProcessResult(status: .succeeded, exitCode: 0)
    }

    func actions() -> [ConfiguredExecutable] { recordedActions }
}
