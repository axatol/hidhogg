@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

public typealias HostDisplayPowerStateHandler = @MainActor @Sendable (Bool) -> Void
public typealias HostDisplayPowerErrorHandler = @MainActor @Sendable (String?) -> Void
public typealias HostDisplayPowerTransitionHandler = @MainActor @Sendable () -> Void

@MainActor
public protocol HostDisplayPowerObserving: AnyObject {
    var lastKnownDisplayAwake: Bool? { get }
    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    )
    func reconcileIfUnknown()
    func stop()
}

@MainActor
public protocol HostDisplayPowerEventObservation: AnyObject {
    func cancel()
}

@MainActor
public protocol HostDisplayPowerStateQuerying {
    func currentDisplayAwake() throws -> Bool
}

@MainActor
public protocol HostDisplayPowerEventSource: HostDisplayPowerStateQuerying {
    func observePowerChanges(
        onSleep: @escaping HostDisplayPowerTransitionHandler,
        onWake: @escaping HostDisplayPowerTransitionHandler
    ) -> any HostDisplayPowerEventObservation
}

public enum HostDisplayPowerQueryError: Error, Equatable, Sendable, LocalizedError {
    case activeDisplayCount(code: Int32)
    case activeDisplayList(code: Int32)

    public var errorDescription: String? {
        let code: Int32
        switch self {
        case .activeDisplayCount(let value), .activeDisplayList(let value):
            code = value
        }
        return "Could not query macOS display power state (Core Graphics error \(code))."
    }
}

@MainActor
public struct CoreGraphicsHostDisplayPowerQuery: HostDisplayPowerStateQuerying {
    public init() {}

    public func currentDisplayAwake() throws -> Bool {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success else {
            throw HostDisplayPowerQueryError.activeDisplayCount(code: countResult.rawValue)
        }
        guard displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var activeCount = displayCount
        let listResult = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &activeCount)
        }
        guard listResult == .success else {
            throw HostDisplayPowerQueryError.activeDisplayList(code: listResult.rawValue)
        }

        return Self.displayAwake(
            displaySleepStates: displays.prefix(Int(activeCount)).map { CGDisplayIsAsleep($0) != 0 }
        )
    }

    static func displayAwake(displaySleepStates: [Bool]) -> Bool {
        displaySleepStates.contains(false)
    }
}

@MainActor
public final class WorkspaceHostDisplayPowerEventSource: HostDisplayPowerEventSource {
    private let workspace: NSWorkspace
    private let query: any HostDisplayPowerStateQuerying

    public init(
        workspace: NSWorkspace = .shared,
        query: any HostDisplayPowerStateQuerying = CoreGraphicsHostDisplayPowerQuery()
    ) {
        self.workspace = workspace
        self.query = query
    }

    public func currentDisplayAwake() throws -> Bool {
        try query.currentDisplayAwake()
    }

    public func observePowerChanges(
        onSleep: @escaping HostDisplayPowerTransitionHandler,
        onWake: @escaping HostDisplayPowerTransitionHandler
    ) -> any HostDisplayPowerEventObservation {
        let center = workspace.notificationCenter
        let sleepToken = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: workspace,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onSleep() }
        }
        let wakeToken = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: workspace,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        }
        return WorkspaceHostDisplayPowerEventObservation(center: center, tokens: [sleepToken, wakeToken])
    }
}

@MainActor
private final class WorkspaceHostDisplayPowerEventObservation: HostDisplayPowerEventObservation {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]
    private var isCancelled = false

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        tokens.forEach { center.removeObserver($0) }
    }
}

@MainActor
public final class HostDisplayPowerObserver: HostDisplayPowerObserving {
    public private(set) var lastKnownDisplayAwake: Bool?

    private let source: any HostDisplayPowerEventSource
    private var observation: (any HostDisplayPowerEventObservation)?
    private var stateHandler: HostDisplayPowerStateHandler?
    private var errorHandler: HostDisplayPowerErrorHandler?
    private var deliveryGeneration = 0

    public init(source: any HostDisplayPowerEventSource = WorkspaceHostDisplayPowerEventSource()) {
        self.source = source
    }

    public func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {
        stop()
        deliveryGeneration += 1
        let generation = deliveryGeneration
        lastKnownDisplayAwake = nil
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
        observation = source.observePowerChanges(
            onSleep: { [weak self] in
                guard let self, self.deliveryGeneration == generation else { return }
                self.receive(false)
            },
            onWake: { [weak self] in
                guard let self, self.deliveryGeneration == generation else { return }
                self.receive(true)
            }
        )
        reconcileIfUnknown()
    }

    public func reconcileIfUnknown() {
        guard observation != nil, lastKnownDisplayAwake == nil else { return }
        do {
            receive(try source.currentDisplayAwake())
        } catch {
            errorHandler?(error.localizedDescription)
        }
    }

    public func stop() {
        deliveryGeneration += 1
        observation?.cancel()
        observation = nil
        stateHandler = nil
        errorHandler = nil
    }

    private func receive(_ displayAwake: Bool) {
        guard lastKnownDisplayAwake != displayAwake else { return }
        lastKnownDisplayAwake = displayAwake
        errorHandler?(nil)
        stateHandler?(displayAwake)
    }
}
