import HidhoggAutomation
import HidhoggDomain
import MacOSActions

@MainActor
final class AppNativeActionRunner: ConfiguredNativeActionRunning {
    weak var model: D200XModel?
    private let platform: (any NativeActionPerforming)?

    init(platform: (any NativeActionPerforming)?) { self.platform = platform }

    func run(_ action: NativeAction) async -> ConfiguredProcessResult {
        await run(action, trigger: nil)
    }

    func run(_ action: NativeAction, trigger: ConfiguredActionTrigger?) async -> ConfiguredProcessResult {
        guard !Task.isCancelled, model?.canRunConfiguredActions == true else { return .init(status: .cancelled) }
        do {
            _ = try action.validated()
            if trigger?.kind == .device, let model {
                model.refreshActiveApplication()
                if let epoch = trigger?.sessionEpoch, epoch != model.actionSessionEpoch {
                    return .init(status: .cancelled, failureMessage: "The triggering device session changed.")
                }
                if action.kind == .deckNotification, trigger?.profile != model.activeProfileName {
                    return .init(status: .cancelled, failureMessage: "The triggering profile is no longer active.")
                }
                if action.kind == .shortcut, trigger?.sessionEpoch != nil, trigger?.applicationID != model.activeApplicationID {
                    return .init(status: .cancelled, failureMessage: "The triggering application is no longer active.")
                }
            }
            if action.kind == .deckNotification {
                guard let model, let topic = action.topic else { throw NativeActionFailure.unsupported }
                let response = await model.publishNotification(
                    topic: topic,
                    text: action.text ?? "",
                    ttlSeconds: action.ttlSeconds,
                    appID: action.appID
                )
                try Task.checkCancellation()
                guard response.error == nil else {
                    return .init(status: .failed, failureMessage: "The deck notification could not be delivered.")
                }
            } else {
                guard let platform else { throw NativeActionFailure.unsupported }
                try platform.perform(action)
            }
            return .init(status: .succeeded)
        } catch is CancellationError {
            return .init(status: .cancelled)
        } catch {
            let message = (error as? NativeActionFailure)?.errorDescription
                ?? (error as? ShortcutDeliveryError)?.errorDescription ?? "The native action failed."
            return .init(status: .failed, failureMessage: message)
        }
    }

    func stop() { platform?.stop() }
}
