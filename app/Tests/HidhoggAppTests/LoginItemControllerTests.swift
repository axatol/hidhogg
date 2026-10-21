import ServiceManagement
import XCTest
@testable import HidhoggApp

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testSystemStatusMappingCoversKnownStatuses() {
        XCTAssertEqual(LoginItemStatus(systemStatus: .enabled), .enabled)
        XCTAssertEqual(LoginItemStatus(systemStatus: .notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemStatus(systemStatus: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(systemStatus: .notFound), .notFound)
    }

    func testInitializationAndRefreshDoNotRegisterNotFoundStatus() {
        let service = FakeLoginItemService(status: .notFound)

        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.status, .notFound)
        XCTAssertTrue(controller.statusDetail.contains("does not identify the cause"))
        XCTAssertEqual(service.statusReadCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)

        controller.refreshStatus()

        XCTAssertEqual(controller.status, .notFound)
        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testNotFoundAllowsExplicitRegistration() async {
        let service = FakeLoginItemService(status: .notFound)
        let controller = LoginItemController(service: service)
        service.registrationStatusAfterCall = .enabled

        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isLaunchAtLoginRequested)
        XCTAssertNil(controller.errorMessage)
    }

    func testNotFoundRegistrationCanRequireApproval() async {
        let service = FakeLoginItemService(status: .notFound)
        let controller = LoginItemController(service: service)
        service.registrationStatusAfterCall = .requiresApproval

        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isLaunchAtLoginRequested)
        XCTAssertNil(controller.errorMessage)
    }

    func testNotFoundRegistrationFailureIncludesSystemErrorAndSurvivesRefresh() async {
        let service = FakeLoginItemService(status: .notFound)
        service.registrationError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Registration failed."]
        )
        let controller = LoginItemController(service: service)

        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(controller.status, .notFound)
        XCTAssertEqual(controller.errorMessage, "Could not enable Launch at login: Registration failed. (SMAppServiceErrorDomain, code 42)")

        controller.refreshStatus()

        XCTAssertEqual(service.statusReadCount, 3)
        XCTAssertEqual(controller.errorMessage, "Could not enable Launch at login: Registration failed. (SMAppServiceErrorDomain, code 42)")
    }

    func testRegistrationUsesAuthoritativeApprovalStatus() async {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registrationStatusAfterCall = .requiresApproval
        let controller = LoginItemController(service: service)

        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isLaunchAtLoginRequested)
        XCTAssertEqual(controller.statusTitle, "Approval required")
        XCTAssertTrue(controller.statusDetail.contains("requires approval"))
        XCTAssertNil(controller.errorMessage)
    }

    func testUnregistrationUsesAuthoritativeStatus() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        await controller.setLaunchAtLogin(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isLaunchAtLoginRequested)
        XCTAssertNil(controller.errorMessage)
    }

    func testFailedRegistrationRequeriesStatusAndShowsError() async {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registrationError = RegistrationFailure()
        let controller = LoginItemController(service: service)

        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isLaunchAtLoginRequested)
        XCTAssertTrue(controller.errorMessage?.hasPrefix("Could not enable Launch at login: Registration failed.") == true)
        XCTAssertTrue(controller.errorMessage?.contains(", code ") == true)
    }

    func testRefreshRetainsOperationErrorUntilStatusChanges() async {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registrationError = RegistrationFailure()
        let controller = LoginItemController(service: service)

        await controller.setLaunchAtLogin(true)
        controller.refreshStatus()

        let operationError = controller.errorMessage
        XCTAssertTrue(operationError?.hasPrefix("Could not enable Launch at login: Registration failed.") == true)
        XCTAssertTrue(operationError?.contains(", code ") == true)
        XCTAssertEqual(controller.errorMessage, operationError)
        service.setStatus(.requiresApproval)
        controller.refreshStatus()

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertNil(controller.errorMessage)
    }

    func testRefreshObservesExternalStatusChangeWithoutRegistration() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)
        service.setStatus(.enabled)

        controller.refreshStatus()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.statusReadCount, 2)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testUnknownStatusBlocksRegistration() async {
        let service = FakeLoginItemService(status: .unknown)
        let controller = LoginItemController(service: service)

        XCTAssertFalse(controller.canChangeRegistration)
        XCTAssertTrue(controller.statusRequiresAttention)
        await controller.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testDuplicateRequestDuringNotFoundRegistrationIsIgnored() async {
        let service = FakeLoginItemService(status: .notFound)
        service.holdRegistration = true
        let controller = LoginItemController(service: service)
        let operation = Task { @MainActor in
            await controller.setLaunchAtLogin(true)
        }

        let started = await eventually { service.registerCallCount == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(controller.isUpdating)
        await controller.setLaunchAtLogin(true)
        XCTAssertEqual(service.registerCallCount, 1)

        service.resumeRegistration()
        await operation.value

        XCTAssertFalse(controller.isUpdating)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testOpeningSettingsRequiresExplicitControllerAction() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        XCTAssertEqual(service.openSettingsCallCount, 0)
        controller.openLoginItemsSettings()

        XCTAssertEqual(service.openSettingsCallCount, 1)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServiceAdapter {
    private(set) var currentStatus: LoginItemStatus
    private(set) var statusReadCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    var registrationStatusAfterCall: LoginItemStatus?
    var registrationError: Error?
    var holdRegistration = false

    private var registrationContinuation: CheckedContinuation<Void, Error>?

    init(status: LoginItemStatus) {
        currentStatus = status
    }

    var status: LoginItemStatus {
        statusReadCount += 1
        return currentStatus
    }

    func register() async throws {
        registerCallCount += 1

        if holdRegistration {
            try await withCheckedThrowingContinuation { continuation in
                registrationContinuation = continuation
            }
        }

        if let registrationError {
            if let registrationStatusAfterCall { currentStatus = registrationStatusAfterCall }
            throw registrationError
        }
        currentStatus = registrationStatusAfterCall ?? .enabled
    }

    func unregister() async throws {
        unregisterCallCount += 1
        currentStatus = .notRegistered
    }

    func openLoginItemsSettings() {
        openSettingsCallCount += 1
    }

    func setStatus(_ status: LoginItemStatus) {
        currentStatus = status
    }

    func resumeRegistration() {
        let continuation = registrationContinuation
        registrationContinuation = nil
        continuation?.resume(returning: ())
    }
}

private struct RegistrationFailure: LocalizedError {
    var errorDescription: String? { "Registration failed." }
}
