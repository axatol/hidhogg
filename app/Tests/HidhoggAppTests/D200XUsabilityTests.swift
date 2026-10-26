import CoreText
import Foundation
import HidhoggAutomation
import HidhoggDomain
import MacOSActions
import UlanziD200X
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XUsabilityTests: XCTestCase {
    func testDefaultBulkAppearanceCopyChangesSelectedPropertiesOnly() throws {
        let controls = D200XControl.allCases.filter(\.isTile)
        let source = D200XTileAppearance(
            label: "Default source",
            backgroundHex: "A1B2C3",
            imageAsset: imageReference,
            titleSize: 36,
            titleColorHex: "D4E5F6",
            titlePlacement: .bottom,
            showTitle: false,
            titleAlignment: .right
        )
        var originalTiles = Dictionary(uniqueKeysWithValues: controls.map { control in
            (control.rawValue, tileAppearance(for: control))
        })
        originalTiles[D200XControl.key0.rawValue] = source
        let actions = ["build": ConfiguredExecutable(executable: "/synthetic/build", arguments: ["literal"])]
        let configuration = D200XConfiguration(
            defaults: ["key0": .action("build"), "key1": .disabled],
            applications: ["com.example.Editor": ["key2": .action("build")]],
            tiles: originalTiles,
            actions: actions,
            notificationTopics: ["key0": ["build.*"]],
            applicationTiles: ["com.example.Editor": ["key1": tileAppearance(for: .key1)]],
            applicationNotificationTopics: ["com.example.Editor": ["key1": ["tests.*"]]]
        )
        let model = makeModel()
        var updated = configuration
        model.onEdit = { next in
            updated = next
            model.synchronize(next, canEdit: true)
        }
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .key0
        let copied: Set<D200XAppearanceProperty> = [.background, .titleAlignment]

        model.applyAppearanceToOtherTiles(properties: copied)

        XCTAssertEqual(updated.tiles["key0"], source)
        for control in controls where control != .key0 {
            let previous = try XCTUnwrap(originalTiles[control.rawValue])
            XCTAssertEqual(
                updated.tiles[control.rawValue],
                previous.copying(copied, from: source),
                "Default bulk appearance copy for \(control.rawValue)"
            )
        }
        XCTAssertEqual(updated.defaults, configuration.defaults)
        XCTAssertEqual(updated.applications, configuration.applications)
        XCTAssertEqual(updated.actions, configuration.actions)
        XCTAssertEqual(updated.applicationTiles, configuration.applicationTiles)
        XCTAssertEqual(updated.notificationTopics, configuration.notificationTopics)
        XCTAssertEqual(updated.applicationNotificationTopics, configuration.applicationNotificationTopics)
    }

    func testApplicationBulkAppearanceCopyStaysInEditingProfile() throws {
        let controls = D200XControl.allCases.filter(\.isTile)
        let source = D200XTileAppearance(
            label: "Editor source",
            backgroundHex: "A1B2C3",
            imageAsset: imageReference,
            titleSize: 40,
            titleColorHex: "D4E5F6",
            titlePlacement: .bottom,
            showTitle: false,
            titleAlignment: .right
        )
        let defaultTiles = Dictionary(uniqueKeysWithValues: controls.map { control in
            (control.rawValue, tileAppearance(for: control))
        })
        let editorTiles = ["key0": source, "key1": tileAppearance(for: .key1)]
        let browserTiles = ["key2": tileAppearance(for: .key2)]
        let configuration = D200XConfiguration(
            defaults: ["key1": .action("build")],
            applications: ["com.example.Editor": [:], "com.example.Browser": ["key2": .disabled]],
            tiles: defaultTiles,
            actions: ["build": ConfiguredExecutable(executable: "/synthetic/build")],
            notificationTopics: ["key0": ["build.*"]],
            applicationTiles: ["com.example.Editor": editorTiles, "com.example.Browser": browserTiles],
            applicationNotificationTopics: ["com.example.Editor": ["key0": ["tests.*"]]]
        )
        let model = makeModel()
        var updated = configuration
        model.onEdit = { next in
            updated = next
            model.synchronize(next, canEdit: true)
        }
        model.synchronize(configuration, canEdit: true)
        model.applicationID = "com.example.Editor"
        model.selectedControl = .key0
        let effectiveBefore = Dictionary(uniqueKeysWithValues: controls.map { control in
            (control.rawValue, configuration.appearance(for: control, application: "com.example.Editor"))
        })
        let copied: Set<D200XAppearanceProperty> = [.background, .titleSize, .titleAlignment]

        model.applyAppearanceToOtherTiles(properties: copied)

        XCTAssertEqual(updated.tiles, defaultTiles)
        XCTAssertEqual(updated.applicationTiles["com.example.Browser"], browserTiles)
        XCTAssertEqual(updated.applicationTiles["com.example.Editor"]?["key0"], source)
        XCTAssertEqual(updated.applications, configuration.applications)
        XCTAssertEqual(updated.defaults, configuration.defaults)
        XCTAssertEqual(updated.actions, configuration.actions)
        XCTAssertEqual(updated.notificationTopics, configuration.notificationTopics)
        XCTAssertEqual(updated.applicationNotificationTopics, configuration.applicationNotificationTopics)
        for control in controls where control != .key0 {
            let previous = try XCTUnwrap(effectiveBefore[control.rawValue])
            let expected = previous.copying(copied, from: source)
            XCTAssertEqual(
                updated.appearance(for: control, application: "com.example.Editor"),
                expected,
                "Editor bulk appearance copy for \(control.rawValue)"
            )
        }
        let updatedEditorTiles = try XCTUnwrap(updated.applicationTiles["com.example.Editor"])
        XCTAssertEqual(updatedEditorTiles["key1"]?.label, editorTiles["key1"]?.label)
        XCTAssertEqual(updatedEditorTiles["key1"]?.imageAsset, editorTiles["key1"]?.imageAsset)
    }

    func testNotificationTextLayoutPreservesWordsAndFitsSquareAndWideBounds() {
        let text = "Build finished after tests pass in production"
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let squareBounds = CGSize(width: 176, height: 78)
        let wideBounds = CGSize(width: 372, height: 176)
        let square = D200XNotificationTextLayout.fit(text, preferredSize: 48, bounds: squareBounds)
        let wide = D200XNotificationTextLayout.fit(text, preferredSize: 48, bounds: wideBounds)

        assertWordLayout(square, preserves: words, within: squareBounds)
        assertWordLayout(wide, preserves: words, within: wideBounds)
        XCTAssertGreaterThanOrEqual(wide.fontSize, square.fontSize)
    }

    func testNotificationTextLayoutEllipsizesAnOversizedWordWithinBounds() {
        let text = String(repeating: "W", count: 120)
        let bounds = CGSize(width: 64, height: 28)
        let layout = D200XNotificationTextLayout.fit(text, preferredSize: 36, bounds: bounds)
        let font = CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)

        XCTAssertEqual(layout.fontSize, 8)
        XCTAssertTrue(layout.text.hasSuffix("…"))
        XCTAssertLessThan(layout.text.count, text.count)
        XCTAssertLessThanOrEqual(D200XNotificationTextLayout.width(layout.text, font: font), bounds.width)
        XCTAssertLessThanOrEqual(notificationLineHeight(font) + 4, bounds.height)
    }

    func testClearActionHistoryKeepsRunningAndQueuedActionsWithoutReappearance() async throws {
        let processRunner = HeldUsabilityProcessRunner()
        let actionRunner = ConfiguredActionRunner(processRunner: processRunner)
        let model = makeModel(actionRunner: actionRunner)
        model.synchronize(
            D200XConfiguration(actions: [
                "first": ConfiguredExecutable(executable: "/synthetic/first"),
                "second": ConfiguredExecutable(executable: "/synthetic/second")
            ]),
            canEdit: true
        )

        let firstResponse = await model.handleAutomation(AutomationRequest(
            method: .actionsInvoke,
            params: AutomationParameters(actionID: "first")
        ))
        let secondResponse = await model.handleAutomation(AutomationRequest(
            method: .actionsInvoke,
            params: AutomationParameters(actionID: "second")
        ))
        XCTAssertNil(firstResponse.error)
        XCTAssertNil(secondResponse.error)
        let firstActionStarted = await eventually { await processRunner.startedCount == 1 }
        XCTAssertTrue(firstActionStarted)
        XCTAssertEqual(model.actionHistory.map(\.status), [.running, .queued])
        XCTAssertTrue(model.actionHistory.allSatisfy { $0.trigger?.kind == .localAPI })

        await model.clearActionHistory()

        XCTAssertTrue(model.actionHistory.isEmpty)
        let startedAfterClear = await processRunner.startedCount
        let queuedAfterClear = await actionRunner.queuedCount
        XCTAssertEqual(startedAfterClear, 1)
        XCTAssertEqual(queuedAfterClear, 1)
        await processRunner.finish(.init(status: .succeeded, exitCode: 0))
        let secondActionStarted = await eventually { await processRunner.startedCount == 2 }
        XCTAssertTrue(secondActionStarted)
        XCTAssertTrue(model.actionHistory.isEmpty)
        await processRunner.finish(.init(status: .succeeded, exitCode: 0))
        let bothActionsCompleted = await eventually { await processRunner.completedCount == 2 }
        XCTAssertTrue(bothActionsCompleted)
        await model.refreshAutomationHistory()
        XCTAssertTrue(model.actionHistory.isEmpty)
        let finalStartedCount = await processRunner.startedCount
        XCTAssertEqual(finalStartedCount, 2)
        XCTAssertNil(model.automationMessage)

        await model.stop()
    }

    func testClearOneAndAllNotificationsRestoreLabelsInSinglePageWriteAndKeepHistory() async throws {
        let session = UsabilityD200XSession()
        let processRunner = CountingUsabilityProcessRunner()
        let model = makeModel(
            session: session,
            actionRunner: ConfiguredActionRunner(processRunner: processRunner)
        )
        model.synchronize(
            D200XConfiguration(notificationTopics: [
                "key0": ["build.*"],
                "key1": ["tests.*"],
                "key2": ["build.*", "tests.*"]
            ]),
            canEdit: true
        )
        model.setListening(true)
        model.connect()
        guard await eventually({ model.isConnected }) else {
            XCTFail("Synthetic D200X session did not connect.")
            await model.stop()
            return
        }

        let firstResponse = await model.publishNotification(topic: "build.finished", text: "Build complete", ttlSeconds: 3_600)
        let secondResponse = await model.publishNotification(topic: "tests.finished", text: "Tests complete", ttlSeconds: 3_600)
        XCTAssertNil(firstResponse.error)
        XCTAssertNil(secondResponse.error)
        XCTAssertEqual(model.notificationLabels, ["key0": "Build complete", "key1": "Tests complete", "key2": "Tests complete"])
        let deliveredEntries = model.notificationHistory.filter { $0.outcome == "delivered" }
        XCTAssertEqual(deliveredEntries.count, 2)
        XCTAssertEqual(model.liveNotifications.count, 2)
        guard let firstID = deliveredEntries.first(where: { $0.topic == "build.finished" })?.notificationID,
              let secondID = deliveredEntries.first(where: { $0.topic == "tests.finished" })?.notificationID else {
            XCTFail("Expected both delivered notifications in metadata history.")
            await model.stop()
            return
        }

        let writesBeforeSingleClear = await session.pageWriteCount()
        await model.clearNotification(id: firstID)
        let writesAfterSingleClear = await session.pageWriteCount()
        XCTAssertEqual(writesAfterSingleClear - writesBeforeSingleClear, 1)
        XCTAssertEqual(model.notificationLabels, ["key1": "Tests complete", "key2": "Tests complete"])
        XCTAssertEqual(model.liveNotifications.first(where: { $0.notificationID == firstID })?.outcome, "cleared")
        XCTAssertEqual(model.liveNotifications.first(where: { $0.notificationID == secondID })?.outcome, "delivered")

        let writesBeforeClearAll = await session.pageWriteCount()
        await model.clearActiveNotifications()
        let writesAfterClearAll = await session.pageWriteCount()
        XCTAssertEqual(writesAfterClearAll - writesBeforeClearAll, 1)
        XCTAssertTrue(model.notificationLabels.isEmpty)
        XCTAssertEqual(
            Set(model.notificationHistory.filter { $0.outcome == "delivered" }.map(\.notificationID)),
            Set([firstID, secondID])
        )
        XCTAssertTrue(model.liveNotifications.allSatisfy { $0.outcome == "cleared" })
        let processInvocationCount = await processRunner.invocationCount
        XCTAssertEqual(processInvocationCount, 0)

        await model.stop()
    }

    private var imageReference: String { "\(String(repeating: "a", count: 64)).png" }

    private func makeModel(
        session: (any D200XSessionProtocol)? = nil,
        actionRunner: ConfiguredActionRunner? = nil
    ) -> D200XModel {
        D200XModel(
            session: session,
            sender: ShortcutSender(preflight: { false }, request: {
                XCTFail("Usability tests must not request Accessibility permission.")
                return false
            }, postPair: { _ in
                XCTFail("Usability tests must not post keyboard events.")
            }),
            frontmostApplication: { nil },
            actionRunner: actionRunner ?? ConfiguredActionRunner(processRunner: CountingUsabilityProcessRunner())
        )
    }

    private func tileAppearance(for control: D200XControl) -> D200XTileAppearance {
        let index = control.wireIndex
        let color = String(format: "%06X", 0x102030 + index * 0x010101)
        return D200XTileAppearance(
            label: "Tile \(index)",
            backgroundHex: color,
            imageAsset: index.isMultiple(of: 2) ? imageReference : nil,
            titleSize: Double(8 + index),
            titleColorHex: index.isMultiple(of: 2) ? "AABBCC" : nil,
            titlePlacement: index.isMultiple(of: 2) ? .top : .center,
            showTitle: index.isMultiple(of: 2),
            titleAlignment: .center
        )
    }

    private func assertWordLayout(
        _ layout: D200XNotificationTextLayout.Layout,
        preserves expectedWords: [String],
        within bounds: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualWords = layout.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let lines = layout.text.split(separator: "\n").map(String.init)
        let font = CTFontCreateWithName("Helvetica" as CFString, layout.fontSize, nil)
        XCTAssertEqual(actualWords, expectedWords, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.fontSize, 8, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.fontSize, 48, file: file, line: line)
        for textLine in lines {
            XCTAssertLessThanOrEqual(
                D200XNotificationTextLayout.width(textLine, font: font),
                bounds.width,
                "Line exceeds \(bounds.width)-point text bounds: \(textLine)",
                file: file,
                line: line
            )
        }
        XCTAssertLessThanOrEqual(
            CGFloat(lines.count) * notificationLineHeight(font) + 4,
            bounds.height,
            "Text exceeds \(bounds.height)-point text bounds",
            file: file,
            line: line
        )
    }

    private func notificationLineHeight(_ font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor CountingUsabilityProcessRunner: ConfiguredProcessRunning {
    private(set) var invocationCount = 0

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        invocationCount += 1
        return .init(status: .succeeded, exitCode: 0)
    }
}

private actor HeldUsabilityProcessRunner: ConfiguredProcessRunning {
    private var continuation: CheckedContinuation<ConfiguredProcessResult, Never>?
    private(set) var actions: [ConfiguredExecutable] = []
    private(set) var completedCount = 0
    var startedCount: Int { actions.count }

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        actions.append(action)
        let result: ConfiguredProcessResult = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfiguredProcessResult, Never>) in
                if Task.isCancelled { continuation.resume(returning: .init(status: .cancelled)) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.finish(.init(status: .cancelled)) }
        }
        completedCount += 1
        return result
    }

    func finish(_ result: ConfiguredProcessResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor UsabilityD200XSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private var generation: UInt64 = 0
    private var pageWrites = 0

    init() {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        generation &+= 1
        continuation.yield(.status(.connecting, generation: generation))
        continuation.yield(.status(.connected(try identity()), generation: generation))
    }

    func disconnect() async {
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {
        pageWrites += 1
    }

    func setBrightness(_ percent: Int) async throws {}

    func pageWriteCount() -> Int { pageWrites }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }
}
