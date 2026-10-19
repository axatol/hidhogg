import HidhoggDomain
import XCTest
@testable import HidhoggApp

final class EditorStateTests: XCTestCase {
    func testNavigationHistoryIgnoresCurrentRouteAndBranchesAfterBack() {
        var history = NavigationHistory(initialRoute: "devices")

        history.navigate(to: "devices")
        XCTAssertFalse(history.canGoBack)

        history.navigate(to: "settings")
        XCTAssertTrue(history.goBack())
        XCTAssertEqual(history.current, "devices")
        history.navigate(to: "settings")

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backRoutes, ["devices"])
    }

    func testNavigationHistoryIsBoundedTo64Routes() {
        var history = NavigationHistory(initialRoute: 0)

        for route in 1...100 { history.navigate(to: route) }

        XCTAssertEqual(history.backRoutes.count, NavigationHistory<Int>.capacity)
        for _ in 0..<NavigationHistory<Int>.capacity { XCTAssertTrue(history.goBack()) }
        XCTAssertEqual(history.current, 36)
        XCTAssertFalse(history.canGoBack)
        for _ in 0..<NavigationHistory<Int>.capacity { XCTAssertTrue(history.goForward()) }
        XCTAssertEqual(history.current, 100)
    }

    func testNavigationHistoryRestoresApplicationAndControlContext() {
        var history = NavigationHistory(initialRoute: WorkspaceLocation())
        let settings = WorkspaceLocation(route: .settings, applicationID: nil, control: .back)
        let application = WorkspaceLocation(route: .devices, applicationID: "com.example.browser", control: .forward)

        history.navigate(to: settings)
        history.navigate(to: application)

        XCTAssertTrue(history.goBack())
        XCTAssertEqual(history.current, settings)
        XCTAssertTrue(history.goBack())
        XCTAssertEqual(history.current, WorkspaceLocation())
        XCTAssertTrue(history.goForward())
        XCTAssertEqual(history.current, settings)
        XCTAssertTrue(history.goForward())
        XCTAssertEqual(history.current, application)
    }

    func testConfigurationDocumentTracksDraftSaveAndReload() {
        var document = ConfigurationDraft(configuration: .empty)
        var edited = document.draft
        edited.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 0x7B, modifiers: [.command]))

        document.updateDraft(edited)
        XCTAssertTrue(document.isDirty)

        document.acceptSaved(edited)
        XCTAssertFalse(document.isDirty)

        edited.devices[0].defaults[MouseControl.forward.rawValue] = .key(KeyboardShortcut(keyCode: 0x7C))
        document.updateDraft(edited)
        document.acceptReload(.empty)

        XCTAssertEqual(document.draft, .empty)
        XCTAssertFalse(document.isDirty)
    }

    func testAcceptingSaveKeepsEditsMadeAfterSaveStarted() {
        var document = ConfigurationDraft(configuration: .empty)
        var submitted = document.draft
        submitted.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 0x7B))
        document.updateDraft(submitted)

        var editedDuringSave = submitted
        editedDuringSave.devices[0].defaults[MouseControl.forward.rawValue] = .key(KeyboardShortcut(keyCode: 0x7C))
        document.updateDraft(editedDuringSave)
        document.acceptSaved(submitted)

        XCTAssertEqual(document.saved, submitted)
        XCTAssertEqual(document.draft, editedDuringSave)
        XCTAssertTrue(document.isDirty)
    }

    func testBindingsRequireSavedConfigPermissionAndBothControls() {
        let readiness = BindingReadiness(
            configurationIsSaved: true,
            permissionIsGranted: true,
            deviceIsReady: true,
            supportsRequiredControls: true
        )
        XCTAssertTrue(readiness.canEnable)

        XCTAssertFalse(BindingReadiness(
            configurationIsSaved: false,
            permissionIsGranted: true,
            deviceIsReady: true,
            supportsRequiredControls: true
        ).canEnable)
        XCTAssertFalse(BindingReadiness(
            configurationIsSaved: true,
            permissionIsGranted: false,
            deviceIsReady: true,
            supportsRequiredControls: true
        ).canEnable)
        XCTAssertFalse(BindingReadiness(
            configurationIsSaved: true,
            permissionIsGranted: true,
            deviceIsReady: false,
            supportsRequiredControls: true
        ).canEnable)
        XCTAssertFalse(BindingReadiness(
            configurationIsSaved: true,
            permissionIsGranted: true,
            deviceIsReady: true,
            supportsRequiredControls: false
        ).canEnable)
    }
}
