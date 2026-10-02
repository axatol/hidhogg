@preconcurrency import AppKit
import Foundation

public typealias ForegroundApplicationHandler = @MainActor @Sendable (String?) -> Void

@MainActor
public protocol ForegroundApplicationObserving: AnyObject {
    func start(handler: @escaping ForegroundApplicationHandler)
    func stop()
}

@MainActor
public protocol ForegroundApplicationObservation: AnyObject {
    func cancel()
}

@MainActor
public protocol ForegroundApplicationEventSource: AnyObject {
    func frontmostBundleIdentifier() -> String?
    func observeActivations(_ handler: @escaping ForegroundApplicationHandler) -> any ForegroundApplicationObservation
}

@MainActor
public final class WorkspaceForegroundApplicationEventSource: ForegroundApplicationEventSource {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func frontmostBundleIdentifier() -> String? {
        workspace.frontmostApplication?.bundleIdentifier
    }

    public func observeActivations(
        _ handler: @escaping ForegroundApplicationHandler
    ) -> any ForegroundApplicationObservation {
        let notificationCenter = workspace.notificationCenter
        let token = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            Task { @MainActor in
                handler(bundleIdentifier)
            }
        }
        return WorkspaceForegroundApplicationObservation(
            notificationCenter: notificationCenter,
            token: token
        )
    }
}

@MainActor
private final class WorkspaceForegroundApplicationObservation: ForegroundApplicationObservation {
    private let notificationCenter: NotificationCenter
    private let token: NSObjectProtocol
    private var isCancelled = false

    init(notificationCenter: NotificationCenter, token: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        notificationCenter.removeObserver(token)
    }

}

@MainActor
public final class ForegroundApplicationObserver: ForegroundApplicationObserving {
    private let source: any ForegroundApplicationEventSource
    private var observation: (any ForegroundApplicationObservation)?
    private var handler: ForegroundApplicationHandler?
    private var deliveryGeneration = 0

    public init(
        source: any ForegroundApplicationEventSource = WorkspaceForegroundApplicationEventSource()
    ) {
        self.source = source
    }

    public func start(handler: @escaping ForegroundApplicationHandler) {
        stop()
        deliveryGeneration += 1
        let deliveryGeneration = self.deliveryGeneration
        self.handler = handler
        observation = source.observeActivations { [weak self] bundleIdentifier in
            guard let self, self.deliveryGeneration == deliveryGeneration else { return }
            self.receive(bundleIdentifier)
        }
        receive(source.frontmostBundleIdentifier())
    }

    public func stop() {
        deliveryGeneration += 1
        observation?.cancel()
        observation = nil
        handler = nil
    }

    private func receive(_ bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        handler?(bundleIdentifier)
    }

}
