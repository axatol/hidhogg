import Combine
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown

    init(systemStatus: SMAppService.Status) {
        switch systemStatus {
        case .enabled:
            self = .enabled
        case .notRegistered:
            self = .notRegistered
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }

    var isLaunchAtLoginRequested: Bool {
        self == .enabled || self == .requiresApproval
    }

    var canChangeRegistration: Bool {
        self == .enabled || self == .notRegistered || self == .requiresApproval || self == .notFound
    }

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .notRegistered: "Not enabled"
        case .requiresApproval: "Approval required"
        case .notFound: "Login item not found"
        case .unknown: "Unknown login item status"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            "macOS reports that Hidhogg is eligible to launch at login."
        case .notRegistered:
            "macOS does not have Hidhogg registered to launch at login."
        case .requiresApproval:
            "Hidhogg is registered, but macOS requires approval in Login Items before it can launch at login."
        case .notFound:
            "macOS could not resolve Hidhogg's main app login item. This status does not identify the cause. You can retry registration or inspect Login Items Settings."
        case .unknown:
            "macOS returned an unrecognized login item status. Open Login Items Settings to inspect it."
        }
    }
}

@MainActor
protocol LoginItemServiceAdapter {
    var status: LoginItemStatus { get }

    func register() async throws
    func unregister() async throws
    func openLoginItemsSettings()
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemServiceAdapter
    private var errorStatus: LoginItemStatus?
    private var failedRequest: Bool?

    init(service: any LoginItemServiceAdapter = SystemLoginItemServiceAdapter()) {
        self.service = service
        status = service.status
    }

    var isLaunchAtLoginRequested: Bool { status.isLaunchAtLoginRequested }
    var canChangeRegistration: Bool { status.canChangeRegistration && !isUpdating }
    var statusRequiresAttention: Bool { status == .notFound || status == .unknown }

    var statusTitle: String { status.title }
    var statusDetail: String { status.detail }

    func refreshStatus() {
        guard !isUpdating else { return }
        let refreshedStatus = service.status
        status = refreshedStatus

        guard errorMessage != nil, let failedRequest else { return }
        if refreshedStatus != errorStatus || refreshedStatus.matchesRequest(failedRequest) {
            clearOperationError()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard canChangeRegistration, enabled != isLaunchAtLoginRequested else { return }

        isUpdating = true
        clearOperationError()

        do {
            if enabled {
                try await service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            errorMessage = operationErrorMessage(error, enabled: enabled)
        }

        status = service.status
        if errorMessage == nil, !status.matchesRequest(enabled) {
            errorMessage = status.operationFailureDescription
        }
        if errorMessage != nil {
            errorStatus = status
            failedRequest = enabled
        }

        isUpdating = false
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }

    private func clearOperationError() {
        errorMessage = nil
        errorStatus = nil
        failedRequest = nil
    }

    private func operationErrorMessage(_ error: Error, enabled: Bool) -> String {
        let systemError = error as NSError
        let operation = enabled ? "enable" : "disable"
        return "Could not \(operation) Launch at login: \(error.localizedDescription) (\(systemError.domain), code \(systemError.code))"
    }
}

private extension LoginItemStatus {
    func matchesRequest(_ enabled: Bool) -> Bool {
        if enabled {
            return self == .enabled || self == .requiresApproval
        }
        return self == .notRegistered
    }

    var operationFailureDescription: String {
        switch self {
        case .notRegistered:
            "macOS did not register Hidhogg to launch at login."
        case .enabled, .requiresApproval:
            "macOS still reports Hidhogg as registered to launch at login."
        case .notFound, .unknown:
            detail
        }
    }
}

@MainActor
private final class SystemLoginItemServiceAdapter: LoginItemServiceAdapter {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus { LoginItemStatus(systemStatus: service.status) }

    func register() async throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
