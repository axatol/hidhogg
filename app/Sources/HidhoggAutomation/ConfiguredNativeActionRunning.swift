import HidhoggDomain

public protocol ConfiguredNativeActionRunning: Sendable {
    func run(_ action: NativeAction) async -> ConfiguredProcessResult
    func run(_ action: NativeAction, trigger: ConfiguredActionTrigger?) async -> ConfiguredProcessResult
}

extension ConfiguredNativeActionRunning {
    public func run(_ action: NativeAction, trigger: ConfiguredActionTrigger?) async -> ConfiguredProcessResult {
        await run(action)
    }
}

public struct UnavailableNativeActionRunner: ConfiguredNativeActionRunning {
    public init() {}
    public func run(_ action: NativeAction) async -> ConfiguredProcessResult {
        .init(status: .failed, failureMessage: "Native actions are unavailable in this session.")
    }
}
