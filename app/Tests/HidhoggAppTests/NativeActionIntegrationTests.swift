import Foundation
import HidhoggAutomation
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class NativeActionIntegrationTests: XCTestCase {
    func testLocalAPIInvokesNativeActionWithMetadataOnlyHistory() async throws {
        let platform = RecordingNativeActionPlatform()
        let model = makeModel(platform: platform)
        let action = NativeAction(kind: .openFile, target: "/synthetic/private-document.txt")
        model.synchronize(D200XConfiguration(nativeActions: ["open-document": action]), canEdit: true)

        let response = await model.handleAutomation(invokeRequest(actionID: "open-document"))

        XCTAssertNil(response.error)
        XCTAssertNotNil(stringResult("execution_id", in: response).flatMap(UUID.init(uuidString:)))
        let actionCompleted = await eventuallyNativeAction { model.actionHistory.first?.status == .succeeded }
        XCTAssertTrue(actionCompleted)
        XCTAssertEqual(platform.actions, [action])
        XCTAssertEqual(model.actionHistory.first?.trigger, ConfiguredActionTrigger(kind: .localAPI))

        let encodedHistory = String(decoding: try JSONEncoder().encode(model.actionHistory), as: UTF8.self)
        XCTAssertFalse(encodedHistory.contains("private-document.txt"))
        XCTAssertFalse(encodedHistory.contains("target"))

        let unknown = await model.handleAutomation(invokeRequest(actionID: "missing-action"))
        XCTAssertEqual(unknown.error?.code, "unavailable")
        XCTAssertEqual(platform.actions, [action])
        await model.stop()
    }

    func testDeckNotificationNativeActionPublishesWithoutNativeQueueCycleOrTextHistory() async throws {
        let platform = RecordingNativeActionPlatform()
        let iconResolver = FixedD200XApplicationIconResolver(pngData: try D200XIconTestFixture.png())
        let model = makeModel(platform: platform, iconResolver: iconResolver)
        let action = NativeAction(
            kind: .deckNotification,
            topic: "build.finished",
            text: "private synthetic notification text",
            appID: "com.example.Builder",
            ttlSeconds: 60
        )
        model.synchronize(D200XConfiguration(nativeActions: ["notify-build": action]), canEdit: true)

        let response = await model.handleAutomation(invokeRequest(actionID: "notify-build"))

        XCTAssertNil(response.error)
        let actionAndNotificationCompleted = await eventuallyNativeAction {
            model.actionHistory.first?.status == .succeeded
                && model.notificationHistory.last?.topic == "build.finished"
        }
        XCTAssertTrue(actionAndNotificationCompleted, "The native action should finish after its nested deck notification publishes.")
        XCTAssertEqual(model.notificationHistory.last?.outcome, "unhandled")
        XCTAssertEqual(model.notificationHistory.last?.matchedCount, 0)
        XCTAssertTrue(platform.actions.isEmpty, "Deck notifications must use the model publisher, not native media/platform effects.")
        XCTAssertFalse(model.isListening)
        XCTAssertNil(model.automationMessage, "The local test must not start the automation endpoint.")

        XCTAssertTrue(model.liveNotifications.isEmpty, "Notification text must not be retained when listening is off.")
        XCTAssertEqual(model.notificationHistory.last?.topic, "build.finished")
        XCTAssertEqual(model.notificationHistory.last?.appID, "com.example.Builder")
        XCTAssertEqual(model.notificationHistory.last?.outcome, "unhandled")
        let trigger = model.actionHistory.first?.trigger
        XCTAssertEqual(trigger, ConfiguredActionTrigger(kind: .localAPI))
        let historyResponse = await model.handleAutomation(AutomationRequest(method: .notificationsHistory))
        guard case .array(let history)? = historyResponse.result,
              case .object(let first)? = history.last else {
            return XCTFail("Notification history should include the app bundle ID.")
        }
        XCTAssertEqual(first["app_id"], .string("com.example.Builder"))
        await model.stop()
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testNativeAndExecutableDefinitionsShareAnActionIDWithoutDuplicateEntries() async throws {
        let model = makeModel(platform: RecordingNativeActionPlatform())
        model.onEdit = { [weak model] in model?.synchronize($0, canEdit: true) }
        model.synchronize(D200XConfiguration(
            defaults: ["key0": .action("shared-build")],
            actions: ["shared-build": .init(executable: "/synthetic/build")]
        ), canEdit: true)

        try model.saveNativeAction(id: "shared-build", action: .init(kind: .bell))
        XCTAssertEqual(model.configuration?.actionIDs, ["shared-build"])
        XCTAssertEqual(model.configuration?.actionDefinition(id: "shared-build"), .native(.init(kind: .bell)))
        XCTAssertEqual(model.binding, .action("shared-build"))
        XCTAssertTrue(model.configuration?.actions.isEmpty == true)

        try model.saveAction(id: "shared-build", action: .init(executable: "/synthetic/replacement"))
        XCTAssertEqual(model.configuration?.actionIDs, ["shared-build"])
        XCTAssertEqual(model.configuration?.actionDefinition(id: "shared-build"), .executable(.init(executable: "/synthetic/replacement")))
        XCTAssertEqual(model.binding, .action("shared-build"))
        XCTAssertTrue(model.configuration?.nativeActions.isEmpty == true)
        await model.stop()
    }

    func testStaleDeviceProfileCancelsNativeNotificationWhileUnscopedAPITriggerRuns() async {
        var foreground: String? = "com.example.Editor"
        let platform = RecordingNativeActionPlatform()
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            frontmostApplication: { foreground },
            nativePlatform: platform
        )
        model.synchronize(D200XConfiguration(applications: [
            "com.example.Editor": [:],
            "com.example.Browser": [:]
        ]), canEdit: true)
        let runner = AppNativeActionRunner(platform: platform)
        runner.model = model
        let staleDeviceTrigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "com.example.Editor",
            control: "key0",
            sessionEpoch: model.actionSessionEpoch,
            applicationID: "com.example.Editor"
        )
        foreground = "com.example.Browser"
        model.refreshActiveApplication()
        XCTAssertEqual(model.activeProfileName, "com.example.Browser")

        let notification = await runner.run(
            .init(kind: .deckNotification, topic: "build.finished", text: "Stale notification"),
            trigger: staleDeviceTrigger
        )

        XCTAssertEqual(notification.status, .cancelled)
        XCTAssertTrue(model.notificationHistory.isEmpty)
        XCTAssertTrue(platform.actions.isEmpty)

        let apiAction = await runner.run(.init(kind: .bell), trigger: ConfiguredActionTrigger(kind: .localAPI))
        XCTAssertEqual(apiAction.status, .succeeded)
        XCTAssertEqual(platform.actions, [.init(kind: .bell)])
        await model.stop()
    }

    func testStaleDeviceSessionEpochCancelsNativeActionBeforePlatformEffect() async {
        let platform = RecordingNativeActionPlatform()
        let model = makeModel(platform: platform)
        model.synchronize(.empty, canEdit: true)
        let runner = AppNativeActionRunner(platform: platform)
        runner.model = model
        let capturedEpoch = model.actionSessionEpoch
        let trigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "Default",
            control: "key0",
            sessionEpoch: capturedEpoch
        )

        model.disconnect()
        XCTAssertNotEqual(model.actionSessionEpoch, capturedEpoch)

        let result = await runner.run(.init(kind: .bell), trigger: trigger)

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(platform.actions.isEmpty)
        await model.stop()
    }

    func testPhysicalNativeShortcutIsDroppedAfterForegroundApplicationChanges() async {
        var foreground: String? = "com.example.Editor"
        let platform = RecordingNativeActionPlatform()
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            frontmostApplication: { foreground },
            nativePlatform: platform
        )
        model.synchronize(D200XConfiguration(applications: [
            "com.example.Editor": [:],
            "com.example.Browser": [:]
        ]), canEdit: true)
        let runner = AppNativeActionRunner(platform: platform)
        runner.model = model
        let action = NativeAction(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 4, modifiers: [.command]))
        let staleTrigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "com.example.Editor",
            control: "key0",
            sessionEpoch: model.actionSessionEpoch,
            applicationID: "com.example.Editor"
        )

        foreground = "com.example.Browser"
        model.refreshActiveApplication()
        let staleResult = await runner.run(action, trigger: staleTrigger)

        XCTAssertEqual(staleResult.status, .cancelled)
        XCTAssertTrue(platform.actions.isEmpty)

        let currentTrigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "com.example.Browser",
            control: "key0",
            sessionEpoch: model.actionSessionEpoch,
            applicationID: "com.example.Browser"
        )
        let currentResult = await runner.run(action, trigger: currentTrigger)

        XCTAssertEqual(currentResult.status, .succeeded)
        XCTAssertEqual(platform.actions, [action])
        await model.stop()
    }

    private func makeModel(platform: RecordingNativeActionPlatform,
                           iconResolver: (any D200XApplicationIconResolving)? = nil) -> D200XModel {
        D200XModel(
            sender: ShortcutSender(preflight: { false }, request: {
                XCTFail("Native action integration tests must not request input permission.")
                return false
            }, postPair: { _ in
                XCTFail("Native action integration tests must not post keyboard events.")
            }),
            frontmostApplication: { nil },
            nativePlatform: platform,
            iconResolver: iconResolver ?? FixedD200XApplicationIconResolver()
        )
    }

    private func invokeRequest(actionID: String) -> AutomationRequest {
        AutomationRequest(method: .actionsInvoke, params: AutomationParameters(actionID: actionID))
    }

    private func stringResult(_ key: String, in response: AutomationResponse) -> String? {
        guard case .object(let values)? = response.result,
              case .string(let value)? = values[key] else { return nil }
        return value
    }

    private func eventuallyNativeAction(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

@MainActor
private final class RecordingNativeActionPlatform: NativeActionPerforming {
    private(set) var actions = [NativeAction]()
    private(set) var stopCount = 0

    func perform(_ action: NativeAction) throws {
        actions.append(action)
    }

    func stop() {
        stopCount += 1
    }
}
