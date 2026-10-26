import Foundation
import HidhoggDomain

@MainActor
public protocol NativeActionPerforming: AnyObject, Sendable {
    func perform(_ action: NativeAction) throws
    func stop()
}

public enum NativeActionFailure: Error, LocalizedError {
    case inputPermission, volumeUnavailable, volumePartiallyChanged, targetUnavailable, soundUnavailable, eventUnavailable, unsupported

    public var errorDescription: String? {
        switch self {
        case .inputPermission: "Input permission is required for this action."
        case .volumeUnavailable: "The current audio output does not provide writable volume control."
        case .volumePartiallyChanged: "Volume could only be changed partially; restoring the original channel levels also failed."
        case .targetUnavailable: "The selected application, file or URL could not be opened."
        case .soundUnavailable: "The selected sound could not be played."
        case .eventUnavailable: "The media key events could not be created."
        case .unsupported: "This native action is unavailable in this session."
        }
    }
}
