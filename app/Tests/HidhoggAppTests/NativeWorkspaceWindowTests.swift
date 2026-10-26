import AppKit
import HidhoggAutomation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class NativeWorkspaceWindowTests: XCTestCase {
    func testWorkspaceWindowRendersAllInspectorsAtMinimumSizeAndReopens() throws {
        try requireExplicitSelection()
        try exerciseWorkspace(contentSize: NSSize(width: 820, height: 560))
    }

    func testWorkspaceWindowRendersAllInspectorsAtDefaultSizeAndReopens() throws {
        try requireExplicitSelection()
        try exerciseWorkspace(contentSize: NSSize(width: 1280, height: 800))
    }

    func testD200XTileGeometryStaysStableAcrossPreviewLoadingAndTitleEdits() throws {
        try requireExplicitSelection()

        for width: CGFloat in [320, 600] {
            for control in [D200XControl.key0, .key13] {
                try exerciseTileGeometry(width: width, editedControl: control)
            }
        }
    }

    func testNativeActionEditorRendersEveryKindAtMinimumWidth() throws {
        try requireExplicitSelection()

        let actions: [(String, NativeAction)] = [
            ("media", .init(kind: .media, media: .playPause)),
            ("volume", .init(kind: .volume, volume: .set, percent: 50)),
            ("bell", .init(kind: .bell)),
            ("sound", .init(kind: .playSound, target: "/synthetic/chime.aiff")),
            ("application", .init(kind: .openApplication, target: "/Applications/Synthetic.app")),
            ("file", .init(kind: .openFile, target: "/synthetic/document.txt")),
            ("url", .init(kind: .openURL, target: "https://example.test/")),
            ("notification", .init(kind: .deckNotification, topic: "build.finished", text: "Synthetic notification", ttlSeconds: 60)),
            ("shortcut", .init(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 4, modifiers: [.command])))
        ]
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("Rendering an action editor must not post keyboard events.")
            }),
            frontmostApplication: { nil }
        )
        model.synchronize(.empty, canEdit: true)

        for (name, action) in actions {
            _ = try action.validated()
            let editor = ScrollView {
                NativeActionEditorView(
                    model: model,
                    selectedActionID: .constant(nil),
                    initialAction: action,
                    onSaved: { _ in XCTFail("Rendering an action editor must not save an action.") },
                    onRemoved: { _ in XCTFail("Rendering an action editor must not remove an action.") }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .frame(width: 320, height: 560)

            let harness = NativeWindowHarness(rootView: editor, contentSize: NSSize(width: 320, height: 560))
            harness.window.orderBack(nil)
            harness.driveLayout(seconds: 0.15)

            XCTAssertTrue(harness.window.isVisible, "The " + name + " editor window should remain visible.")
            XCTAssertFalse(harness.window.isKeyWindow, "The " + name + " editor should render without becoming key.")
            XCTAssertEqual(harness.hostingView.bounds.width, 320, accuracy: 1, "The " + name + " editor should retain minimum width.")
            XCTAssertEqual(harness.hostingView.bounds.height, 560, accuracy: 1, "The " + name + " editor should retain minimum height.")
            XCTAssertTrue(model.actionHistory.isEmpty, "Rendering the " + name + " editor must not invoke an action.")

            if name == "media" || name == "notification" {
                let preview = try harness.captureWorkspace(named: "hidhogg-native-action-editor-\(name)-320x560.png")
                print("Synthetic native action editor snapshot: \(preview.path)")
            }

            harness.close()
        }
    }

    func testConfiguredExecutableArgumentRowsRenderAtMinimumWidthWithoutRunningAction() throws {
        try requireExplicitSelection()
        let actionID = "synthetic-argv"
        let action = ConfiguredExecutable(
            executable: "/synthetic/argv",
            arguments: ["", "two\nlines", "spaces quotes"]
        )
        let processRunner = NativeWindowNoopConfiguredProcessRunner()
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("Rendering executable arguments must not post keyboard events.")
            }),
            frontmostApplication: { nil },
            actionRunner: ConfiguredActionRunner(processRunner: processRunner)
        )
        model.synchronize(D200XConfiguration(actions: [actionID: action]), canEdit: true)

        let editor = ScrollView {
            D200XAutomationEditorView(model: model, selectedActionID: .constant(actionID))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(width: 320, height: 560)
        let harness = NativeWindowHarness(
            rootView: editor,
            contentSize: NSSize(width: 320, height: 560)
        )
        defer { harness.close() }

        harness.window.orderBack(nil)
        harness.driveLayout(seconds: 0.3)

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)
        XCTAssertEqual(harness.hostingView.bounds.width, 320, accuracy: 1)
        XCTAssertEqual(harness.hostingView.bounds.height, 560, accuracy: 1)
        XCTAssertEqual(model.configuration?.actions[actionID], action)
        XCTAssertTrue(model.actionHistory.isEmpty)
        XCTAssertEqual(processRunner.invocationCount, 0)

        let snapshot = try harness.captureWorkspace(named: "hidhogg-configured-argument-rows-320x560.png")
        print("Synthetic configured executable argument editor snapshot: \(snapshot.path)")
    }

    private func exerciseTileGeometry(width: CGFloat, editedControl: D200XControl) throws {
        let controls = D200XControl.allCases.filter(\.isTile)
        let configuration = { (titleSize: Double) in
            D200XConfiguration(tiles: Dictionary(uniqueKeysWithValues: controls.map { control in
                (
                    control.rawValue,
                    D200XTileAppearance(
                        label: "Resize probe",
                        backgroundHex: "10E040",
                        titleSize: control == editedControl ? titleSize : 15
                    )
                )
            }))
        }
        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("The layout regression must not post keyboard events.")
            })
        )
        model.synchronize(configuration(15), canEdit: true)

        let deck = D200XDeckView(model: model)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        let harness = NativeWindowHarness(
            rootView: deck,
            contentSize: NSSize(width: width, height: width + 320)
        )
        defer { harness.close() }

        harness.window.orderBack(nil)
        harness.hostingView.layoutSubtreeIfNeeded()
        harness.hostingView.displayIfNeeded()
        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)

        let initialAt15 = try harness.tilePixelBounds(backgroundHex: "10E040")
        assertTileCountAndShape(
            initialAt15,
            width: width,
            state: "initial loading, \(editedControl), title size 15"
        )
        harness.driveLayout(seconds: 0.2)
        let loadedAt15 = try harness.tilePixelBounds(backgroundHex: "10E040")
        assertSameTileGeometry(
            initialAt15,
            loadedAt15,
            width: width,
            state: "initial preview loading to settled, \(editedControl), title size 15"
        )
        assertTileCountAndShape(
            loadedAt15,
            width: width,
            state: "settled, \(editedControl), title size 15"
        )

        var baseline = loadedAt15
        for titleSize: Double in [24, 20] {
            model.synchronize(configuration(titleSize), canEdit: true)
            harness.hostingView.layoutSubtreeIfNeeded()
            harness.hostingView.displayIfNeeded()

            let updating = try harness.tilePixelBounds(backgroundHex: "10E040")
            assertSameTileGeometry(
                baseline,
                updating,
                width: width,
                state: "preview update to title size \(Int(titleSize)), \(editedControl)"
            )

            harness.driveLayout(seconds: 0.2)
            let settled = try harness.tilePixelBounds(backgroundHex: "10E040")
            assertSameTileGeometry(
                baseline,
                settled,
                width: width,
                state: "settled at title size \(Int(titleSize)), \(editedControl)"
            )
            baseline = settled
        }
    }

    private func exerciseWorkspace(contentSize: NSSize) throws {
        let environment = NativeWorkspaceEnvironment()
        environment.configureMouseBackShortcut()
        environment.model.selectTarget(.back)
        let rootView = environment.injectingEnvironmentObjects(
            WorkspaceView(presentationCoordinator: environment.presentationCoordinator)
        )
        .frame(minWidth: 820, minHeight: 560)
        let harness = NativeWindowHarness(rootView: rootView, contentSize: contentSize)
        defer { harness.close() }

        harness.open()

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)
        XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.width, contentSize.width)
        XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.height, contentSize.height)
        XCTAssertEqual(environment.model.bindingMode(for: .back), .shortcut)

        let mouseBackInspector = try harness.inspectorPane()
        XCTAssertTrue(harness.hasInspectorPane(), "The devices route should expose the identified workspace inspector")
        assertInspectorWidthRange(mouseBackInspector.width, route: "mouse back")
        if contentSize.width == 1280, contentSize.height == 800 {
            XCTAssertEqual(
                mouseBackInspector.width,
                320,
                accuracy: 3,
                "mouse back inspector should start at its 320-point width before divider changes"
            )
        }
        print(
            "Native mouse-back inspector at window width \(harness.hostingView.bounds.width): " +
                "frame=\(mouseBackInspector.frameInWindow)"
        )

        if contentSize.width == 1280, contentSize.height == 800 {
            environment.model.openPermissions()
            harness.driveLayout(seconds: 0.25)
            XCTAssertEqual(environment.model.navigation.current.route, .settings)
            XCTAssertEqual(environment.model.selectedSettingsCategory, .permissions)
            XCTAssertTrue(harness.window.isVisible)

            let permissionSettingsPreview = try harness.captureWorkspace(
                named: "hidhogg-permissions-settings-1280x800.png"
            )
            print("Synthetic native Permissions settings snapshot: \(permissionSettingsPreview.path)")
            XCTAssertEqual(environment.notificationCenter.authorizationRequestCount, 0)

            environment.model.navigate(to: .devices)
            harness.driveLayout(seconds: 0.25)
            XCTAssertEqual(environment.model.navigation.current.route, .devices)
        }

        try exercisePassiveWorkspaceRoutes(environment: environment, harness: harness, contentSize: contentSize)

        if contentSize.width == 820, contentSize.height == 560 {
            let requestedWideInspector = try harness.resizeInspector(to: 480)
            assertInspectorWidthRange(requestedWideInspector.width, route: "mouse back at 820")
            print(
                "Native mouse-back inspector at 820-point window width: requested=480, " +
                    "actual=\(requestedWideInspector.width), frame=\(requestedWideInspector.frameInWindow)"
            )
        }

        if contentSize.width == 1280, contentSize.height == 800 {
            try assertInspectorWidthProbes([320, 360, 480], harness: harness, route: "mouse back")

            for width: CGFloat in [320, 480] {
                _ = try harness.resizeInspector(to: width)
                let preview = try harness.captureWorkspace(
                    named: "hidhogg-inspector-mouse-back-1280w-\(Int(width))i.png"
                )
                print("Synthetic mouse back inspector snapshot at \(width) points: \(preview.path)")
            }
            _ = try harness.resizeInspector(to: 320)
        }

        for target in DeviceEditorTarget.allCases {
            environment.model.selectTarget(target)
            harness.driveLayout(seconds: 0.2)
            XCTAssertEqual(environment.model.selectedTarget, target)
            if let control = target.control {
                XCTAssertEqual(environment.model.selectedControl, control)
            }
            XCTAssertTrue(harness.window.isVisible)
            XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.width, contentSize.width)
            XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.height, contentSize.height)
        }

        for canvasWidth: CGFloat in [240, 600] {
            let screenshotURL = try harness.captureCanvas(
                model: environment.model,
                width: canvasWidth,
                named: "hidhogg-device-control-canvas-synthetic-\(Int(canvasWidth))w.png"
            )
            print("Synthetic native canvas snapshot at \(canvasWidth) points: \(screenshotURL.path)")
        }

        if contentSize.width == 1280, contentSize.height == 800 {
            XCTAssertFalse(harness.window.isKeyWindow)
            let mouseWorkspacePreview = try harness.captureWorkspace(named: "hidhogg-mouse-workspace-1280w.png")
            print("Synthetic mouse workspace snapshot: \(mouseWorkspacePreview.path)")
            XCTAssertFalse(harness.window.isKeyWindow)
        }

        environment.model.d200x.enableConfiguration()
        environment.model.navigate(to: .d200x)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .d200x)
        XCTAssertTrue(environment.model.d200x.isConfigured)
        for target: D200XControl in [.key0, .key13, .side0, .dial0HeldLeft, .dial2Right] {
            environment.model.d200x.selectedControl = target
            harness.driveLayout(seconds: 0.1)
            XCTAssertTrue(harness.window.isVisible)
            XCTAssertFalse(harness.window.isKeyWindow)

            let inspector = try harness.inspectorPane()
            assertInspectorWidthRange(inspector.width, route: "D200X \(target)")
            if contentSize.width == 1280, target == .key0 {
                XCTAssertEqual(
                    inspector.width,
                    320,
                    accuracy: 3,
                    "first D200X inspector should retain the 320-point width"
                )
            }
            print("Native D200X \(target) inspector frame: \(inspector.frameInWindow)")

            if contentSize.width == 1280, [.key0, .dial0HeldLeft].contains(target) {
                try assertInspectorWidthProbes(
                    [320, 360, 480],
                    harness: harness,
                    route: "D200X \(target)"
                )
                _ = try harness.resizeInspector(to: 360)
            }
        }
        let deckPreview = try harness.captureWorkspace(named: "hidhogg-d200x-workspace-\(Int(contentSize.width))w.png")
        print("Synthetic D200X workspace snapshot: \(deckPreview.path)")
        for width: CGFloat in [320, 600] {
            let preview = try harness.captureDeck(model: environment.model.d200x, width: width)
            print("Synthetic D200X deck snapshot: \(preview.path)")
        }

        let initialFrame = harness.window.frame
        harness.window.setFrame(
            NSRect(
                x: initialFrame.origin.x,
                y: initialFrame.origin.y,
                width: initialFrame.width + 120,
                height: initialFrame.height + 80
            ),
            display: true,
            animate: false
        )
        harness.driveLayout(seconds: 0.5)

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
        XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)
        let inspectorAfterWindowResize = try harness.inspectorPane()
        assertInspectorWidthRange(inspectorAfterWindowResize.width, route: "D200X after window resize")
        print("Native D200X inspector after window resize: \(inspectorAfterWindowResize.frameInWindow)")

        environment.model.selectedSettingsCategory = .diagnostics
        environment.model.navigate(to: .settings)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .diagnostics)
        XCTAssertTrue(harness.window.isVisible)

        for category in SettingsCategory.allCases {
            environment.model.selectedSettingsCategory = category
            harness.driveLayout(seconds: 0.1)
            XCTAssertEqual(environment.model.selectedSettingsCategory, category)
            XCTAssertTrue(harness.window.isVisible)
            XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
            XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)
        }

        environment.model.navigate(to: .devices)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .devices)
        XCTAssertEqual(environment.model.selectedTarget, .thumbWheel)

        environment.model.openPermissions()
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .settings)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .permissions)
        XCTAssertTrue(harness.window.isVisible)

        harness.window.close()
        XCTAssertFalse(harness.window.isVisible)
        harness.window.orderBack(nil)
        harness.driveLayout(seconds: 0.75)

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)
        XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
        XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)
        XCTAssertEqual(environment.model.navigation.current.route, .settings)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .permissions)
    }

    private func requireExplicitSelection() throws {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.contains("NativeWorkspaceWindowTests") }) else {
            throw XCTSkip("Select this test class explicitly to open a native workspace window.")
        }
    }

    private func exercisePassiveWorkspaceRoutes<RootView: View>(
        environment: NativeWorkspaceEnvironment,
        harness: NativeWindowHarness<RootView>,
        contentSize: NSSize
    ) throws {
        environment.model.d200x.synchronize(.empty, canEdit: true)
        let bindingCounts = environment.bindingSession.activity.snapshot()
        let actionRunCount = environment.processRunner.invocationCount
        let permissionRequestCount = environment.notificationCenter.authorizationRequestCount

        for route in [WorkspaceRoute.actions, .notifications, .tilePresets] {
            environment.model.navigate(to: route)
            harness.driveLayout(seconds: 0.25)

            XCTAssertEqual(environment.model.navigation.current.route, route)
            XCTAssertFalse(harness.window.isKeyWindow, "Opening \(route) must not activate the test window")
            XCTAssertFalse(harness.hasInspectorPane(), "\(route) must not show a device inspector")
            XCTAssertFalse(environment.model.d200x.isListening, "Opening \(route) must not start notification listening")
            XCTAssertTrue(environment.model.d200x.actionHistory.isEmpty, "Opening \(route) must not run an action")
            XCTAssertNil(environment.model.d200x.automationMessage, "Opening \(route) must not start the automation endpoint")
            XCTAssertEqual(environment.processRunner.invocationCount, actionRunCount)
            XCTAssertEqual(environment.notificationCenter.authorizationRequestCount, permissionRequestCount)
            XCTAssertEqual(environment.bindingSession.activity.snapshot(), bindingCounts)

            if contentSize == NSSize(width: 1280, height: 800), route == .notifications {
                let snapshot = try harness.captureWorkspace(named: "hidhogg-notifications-workspace-1280x800.png")
                print("Synthetic native Notifications snapshot with Test popover closed: \(snapshot.path)")
            }
            if contentSize == NSSize(width: 1280, height: 800), route == .tilePresets {
                let snapshot = try harness.captureWorkspace(named: "hidhogg-tile-presets-workspace-1280x800.png")
                print("Synthetic native independent Tile Presets editor snapshot: \(snapshot.path)")
            }
        }

        environment.model.navigate(to: .devices)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .devices)
    }

    private func assertInspectorWidthRange(_ width: CGFloat, route: String) {
        XCTAssertGreaterThanOrEqual(width, 318, "\(route) inspector must respect its 320-point minimum")
        XCTAssertLessThanOrEqual(width, 482, "\(route) inspector must respect its 480-point maximum")
    }

    private func assertTileCountAndShape(_ bounds: [CGRect], width: CGFloat, state: String) {
        XCTAssertEqual(bounds.count, 14, "\(state), container \(Int(width)) points: \(bounds)")
        guard bounds.count == 14 else { return }
        let sorted = bounds.sorted { $0.width < $1.width }
        let wide = sorted[sorted.count - 1]
        let squareTiles = sorted.dropLast()
        guard let square = squareTiles.first else { return }
        for tile in squareTiles {
            XCTAssertEqual(tile.width, tile.height, accuracy: 4, "\(state), square tile: \(tile)")
        }
        XCTAssertGreaterThan(wide.width, square.width * 1.8, "\(state), wide tile: \(wide)")
        let gridBounds = bounds.reduce(CGRect.null) { $0.union($1) }
        print(
            "D200X tile geometry \(state), container=\(Int(width)): " +
                "square=\(square), wide=\(wide), grid=\(gridBounds)"
        )
    }

    private func assertSameTileGeometry(
        _ expected: [CGRect],
        _ actual: [CGRect],
        width: CGFloat,
        state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(state), container \(Int(width)) points", file: file, line: line)
        guard actual.count == expected.count else { return }
        let expectedTiles = expected.sorted(by: tilePositionOrder)
        let actualTiles = actual.sorted(by: tilePositionOrder)
        let expectedGrid = expected.reduce(CGRect.null) { $0.union($1) }
        let actualGrid = actual.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(actualGrid.width, expectedGrid.width, accuracy: 1, "\(state), grid width", file: file, line: line)
        XCTAssertEqual(actualGrid.height, expectedGrid.height, accuracy: 1, "\(state), grid height", file: file, line: line)
        for index in expectedTiles.indices {
            let before = expectedTiles[index]
            let after = actualTiles[index]
            XCTAssertEqual(
                after.minX - actualGrid.minX,
                before.minX - expectedGrid.minX,
                accuracy: 1,
                "\(state), tile \(index) x within grid",
                file: file,
                line: line
            )
            XCTAssertEqual(
                after.minY - actualGrid.minY,
                before.minY - expectedGrid.minY,
                accuracy: 1,
                "\(state), tile \(index) y within grid",
                file: file,
                line: line
            )
            XCTAssertEqual(after.width, before.width, accuracy: 1, "\(state), tile \(index) width", file: file, line: line)
            XCTAssertEqual(after.height, before.height, accuracy: 1, "\(state), tile \(index) height", file: file, line: line)
        }
        print("D200X tile geometry \(state), container=\(Int(width)): grid=\(actualGrid), tiles=\(actual)")
    }

    private func tilePositionOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if abs(lhs.midY - rhs.midY) > 3 { return lhs.midY < rhs.midY }
        return lhs.minX < rhs.minX
    }

    private func assertInspectorWidthProbes<RootView: View>(
        _ requestedWidths: [CGFloat],
        harness: NativeWindowHarness<RootView>,
        route: String
    ) throws {
        var measuredWidths: [CGFloat] = []

        for requestedWidth in requestedWidths {
            let inspector = try harness.resizeInspector(to: requestedWidth)
            measuredWidths.append(inspector.width)
            print(
                "Native \(route) inspector resize: requested=\(requestedWidth), " +
                    "actual=\(inspector.width), frame=\(inspector.frameInWindow)"
            )
            XCTAssertEqual(inspector.width, requestedWidth, accuracy: 8, "\(route) inspector resize")
            assertInspectorWidthRange(inspector.width, route: route)
        }

        guard let narrowest = measuredWidths.first, let widest = measuredWidths.last else {
            XCTFail("Inspector width probes require at least one requested width.")
            return
        }

        XCTAssertGreaterThan(widest - narrowest, 100, "\(route) inspector frame must change with its divider")
    }
}

@MainActor
private final class NativeWorkspaceEnvironment {
    let model: AppModel
    let presentationCoordinator = WorkspacePresentationCoordinator()
    let notificationCenter: NativeWindowNoopNotificationCenter
    let bindingSession: NativeWindowNoopBindingSession
    let processRunner: NativeWindowNoopConfiguredProcessRunner
    let restartCoordinator = RestartCoordinator(
        cleanup: { true },
        launch: {},
        terminate: {},
        reportError: { _ in }
    )
    let loginItemController = LoginItemController(service: NativeWindowNoopLoginItemService())
    let diagnostics: DiagnosticsStore

    init() {
        let notificationCenter = NativeWindowNoopNotificationCenter(authorizationState: .notDetermined)
        self.notificationCenter = notificationCenter
        let bindingSession = NativeWindowNoopBindingSession()
        self.bindingSession = bindingSession
        let processRunner = NativeWindowNoopConfiguredProcessRunner()
        self.processRunner = processRunner
        let sender = ShortcutSender(preflight: { false }, request: {
            XCTFail("Native workspace routes must not request Accessibility permission.")
            return false
        }, postPair: { _ in
            XCTFail("The native window reproduction must not post keyboard events.")
        })
        let d200x = D200XModel(
            sender: sender,
            frontmostApplication: { nil },
            actionRunner: ConfiguredActionRunner(processRunner: processRunner)
        )
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggNativeWindowRepro-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.toml")
        let model = AppModel(
            configurationURL: configurationURL,
            store: ConfigurationStore(url: configurationURL),
            bolt: bindingSession,
            sender: sender,
            lowBatteryNotifications: LowBatteryNotificationController(
                notificationCenter: notificationCenter,
                latchStore: NativeWindowNoopAlertLatchStore()
            ),
            d200x: d200x,
            loadImmediately: false,
            observeSleep: false
        )
        self.model = model
        diagnostics = DiagnosticsStore(model: model, persist: { _, _ in })
    }

    func injectingEnvironmentObjects<Content: View>(_ content: Content) -> some View {
        content
            .environmentObject(model)
            .environmentObject(diagnostics)
            .environmentObject(loginItemController)
            .environmentObject(restartCoordinator)
    }

    func configureMouseBackShortcut() {
        var configuration = model.document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else {
            XCTFail("The in-memory test configuration must contain the Logitech profile.")
            return
        }

        configuration.devices[index].defaults[MouseControl.back.rawValue] =
            .key(NavigationPreset.pageBack.shortcut)
        model.updateDraft(configuration)
    }
}

@MainActor
private final class NativeWindowHarness<RootView: View> {
    let application: NSApplication
    let hostingView: NSHostingView<RootView>
    let window: NSWindow

    init(rootView: RootView, contentSize: NSSize = NSSize(width: 980, height: 680)) {
        application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        hostingView = NSHostingView(rootView: rootView)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hidhogg Workspace Regression"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
    }

    func open() {
        window.orderBack(nil)
        driveLayout(seconds: 0.75)
    }

    func close() {
        window.close()
        application.setActivationPolicy(.accessory)
    }

    func driveLayout(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func inspectorPane() throws -> NativeInspectorPane {
        let splitViews = allSubviews(in: hostingView).compactMap { $0 as? NSSplitView }
        let candidates = splitViews.compactMap { splitView -> NativeInspectorPane? in
            guard splitView.isVertical else { return nil }

            let contentPanes = splitView.subviews.indices.filter { index in
                let frame = splitView.subviews[index].frame
                return frame.width > 200 && frame.height > 1
            }
            guard contentPanes.count >= 2,
                  let paneIndex = contentPanes.max(by: {
                      splitView.subviews[$0].frame.maxX < splitView.subviews[$1].frame.maxX
                  }),
                  paneIndex > 0,
                  (318...482).contains(splitView.subviews[paneIndex].frame.width) else { return nil }

            return NativeInspectorPane(
                splitView: splitView,
                pane: splitView.subviews[paneIndex],
                paneIndex: paneIndex
            )
        }
        let inventory = splitViews.map { splitView in
            let panes = splitView.subviews.enumerated().map { index, pane in
                "\(index):\(type(of: pane)) \(pane.frame)"
            }.joined(separator: "; ")
            return "vertical=\(splitView.isVertical) panes={\(panes)}"
        }.joined(separator: "; ")

        XCTAssertEqual(candidates.count, 1, "Expected one rightmost split pane between 320 and 480 points. \(inventory)")
        return try XCTUnwrap(candidates.first)
    }

    func hasInspectorPane() -> Bool {
        allSubviews(in: hostingView).contains { $0 is WorkspaceInspectorInitialWidthView }
    }

    func resizeInspector(to requestedWidth: CGFloat) throws -> NativeInspectorPane {
        let inspector = try inspectorPane()
        let dividerIndex = inspector.paneIndex - 1
        XCTAssertGreaterThanOrEqual(dividerIndex, 0, "Inspector pane must have a preceding divider")
        guard dividerIndex >= 0 else {
            throw NSError(domain: "NativeWorkspaceWindowTests", code: 1)
        }

        inspector.splitView.setPosition(
            inspector.splitView.bounds.maxX - requestedWidth,
            ofDividerAt: dividerIndex
        )
        inspector.splitView.adjustSubviews()
        driveLayout(seconds: 0.25)
        return try inspectorPane()
    }

    func tilePixelBounds(backgroundHex: String) throws -> [CGRect] {
        let bounds = hostingView.bounds
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: bounds))
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var matches = [Bool](repeating: false, count: width * height)
        let value = UInt32(backgroundHex, radix: 16) ?? 0
        let targetRed = CGFloat((value >> 16) & 255) / 255
        let targetGreen = CGFloat((value >> 8) & 255) / 255
        let targetBlue = CGFloat(value & 255) / 255

        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                matches[y * width + x] = alpha > 0.75
                    && abs(red - targetRed) < 0.1
                    && abs(green - targetGreen) < 0.1
                    && abs(blue - targetBlue) < 0.1
            }
        }

        var visited = [Bool](repeating: false, count: matches.count)
        var components = [CGRect]()
        for start in matches.indices where matches[start] && !visited[start] {
            var pending = [start]
            visited[start] = true
            var cursor = 0
            var minimumX = width
            var minimumY = height
            var maximumX = 0
            var maximumY = 0
            var area = 0

            while cursor < pending.count {
                let index = pending[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
                area += 1

                for neighbor in [x > 0 ? index - 1 : nil, x + 1 < width ? index + 1 : nil,
                                 y > 0 ? index - width : nil, y + 1 < height ? index + width : nil].compactMap({ $0 })
                    where matches[neighbor] && !visited[neighbor] {
                    visited[neighbor] = true
                    pending.append(neighbor)
                }
            }

            if area >= 1_000 {
                components.append(CGRect(
                    x: minimumX,
                    y: minimumY,
                    width: maximumX - minimumX + 1,
                    height: maximumY - minimumY + 1
                ))
            }
        }
        return components
    }

    func captureCanvas(model: AppModel, width: CGFloat, named filename: String) throws -> URL {
        let rootView = DeviceControlCanvas(isInspectorPresented: .constant(true))
            .environmentObject(model)
            .frame(width: width, height: 1_200)
        let canvasHostingView = NSHostingView(rootView: rootView)
        canvasHostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1_200))
        canvasHostingView.appearance = hostingView.appearance
        canvasHostingView.layoutSubtreeIfNeeded()
        canvasHostingView.displayIfNeeded()

        let bounds = canvasHostingView.bounds
        let bitmap = try XCTUnwrap(canvasHostingView.bitmapImageRepForCachingDisplay(in: bounds))
        canvasHostingView.cacheDisplay(in: bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/Volumes/Data/tmp", isDirectory: true).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func captureWorkspace(named filename: String) throws -> URL {
        let bounds = hostingView.bounds
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: bounds))
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/Volumes/Data/tmp").appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func captureDeck(model: D200XModel, width: CGFloat) throws -> URL {
        let content = D200XDeckView(model: model)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: width, height: width + 300)
        view.appearance = hostingView.appearance
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-d200x-front-deck-\(Int(width))w.png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private struct NativeInspectorPane {
    let splitView: NSSplitView
    let pane: NSView
    let paneIndex: Int

    var width: CGFloat { pane.frame.width }

    var frameInWindow: NSRect {
        guard let contentView = splitView.window?.contentView else { return pane.frame }
        return pane.convert(pane.bounds, to: contentView)
    }
}

@MainActor
private func allSubviews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { allSubviews(in: $0) }
}

private struct NativeWindowNoopBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }
    let activity = NativeWindowBindingActivity()

    func discover() async { activity.discover.record() }
    func enable() async { activity.enable.record() }
    func disable() async { activity.disable.record() }
    func stop() async { activity.stop.record() }

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}

private struct NativeWindowBindingActivityCounts: Equatable, Sendable {
    let discover: Int
    let enable: Int
    let disable: Int
    let stop: Int
}

private struct NativeWindowBindingActivity: Sendable {
    let discover = NativeWindowOperationCounter()
    let enable = NativeWindowOperationCounter()
    let disable = NativeWindowOperationCounter()
    let stop = NativeWindowOperationCounter()

    func snapshot() -> NativeWindowBindingActivityCounts {
        NativeWindowBindingActivityCounts(
            discover: discover.value,
            enable: enable.value,
            disable: disable.value,
            stop: stop.value
        )
    }
}

private final class NativeWindowOperationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private final class NativeWindowNoopConfiguredProcessRunner: ConfiguredProcessRunning, @unchecked Sendable {
    private let activity = NativeWindowOperationCounter()

    var invocationCount: Int { activity.value }

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        activity.record()
        return ConfiguredProcessResult(status: .succeeded)
    }
}

@MainActor
private final class NativeWindowNoopNotificationCenter: LowBatteryNotificationCenterAdapter {
    private let authorizationState: LowBatteryNotificationAuthorizationState
    private(set) var authorizationRequestCount = 0

    init(authorizationState: LowBatteryNotificationAuthorizationState) {
        self.authorizationState = authorizationState
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState {
        authorizationState
    }

    func requestAlertAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        XCTFail("The native workspace test must not request notification permission.")
        return false
    }

    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        XCTFail("The native workspace test must not enqueue notifications.")
    }

    func removePendingRequest(identifier: String) {}
}

@MainActor
private final class NativeWindowNoopAlertLatchStore: LowBatteryAlertLatchStore {
    var isLatched: Bool { false }

    func setLatched(_ value: Bool) {}
}

@MainActor
private final class NativeWindowNoopLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus { .notRegistered }

    func register() async throws {}
    func unregister() async throws {}
    func openLoginItemsSettings() {}
}
