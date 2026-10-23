import AppKit
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

    private func assertInspectorWidthRange(_ width: CGFloat, route: String) {
        XCTAssertGreaterThanOrEqual(width, 318, "\(route) inspector must respect its 320-point minimum")
        XCTAssertLessThanOrEqual(width, 482, "\(route) inspector must respect its 480-point maximum")
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
    let restartCoordinator = RestartCoordinator(
        cleanup: { true },
        launch: {},
        terminate: {},
        reportError: { _ in }
    )
    let loginItemController = LoginItemController(service: NativeWindowNoopLoginItemService())
    let diagnostics: DiagnosticsStore

    init() {
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggNativeWindowRepro-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.toml")
        let model = AppModel(
            configurationURL: configurationURL,
            store: ConfigurationStore(url: configurationURL),
            bolt: NativeWindowNoopBindingSession(),
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("The native window reproduction must not post keyboard events.")
            }),
            lowBatteryNotifications: LowBatteryNotificationController(
                notificationCenter: NativeWindowNoopNotificationCenter(authorizationState: .notDetermined),
                latchStore: NativeWindowNoopAlertLatchStore()
            ),
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

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}

@MainActor
private final class NativeWindowNoopNotificationCenter: LowBatteryNotificationCenterAdapter {
    private let authorizationState: LowBatteryNotificationAuthorizationState

    init(authorizationState: LowBatteryNotificationAuthorizationState) {
        self.authorizationState = authorizationState
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState {
        authorizationState
    }

    func requestAlertAuthorization() async throws -> Bool {
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
