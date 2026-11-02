import HidhoggDomain

struct D200XPresetActionDraft: Equatable {
    enum Kind: Equatable {
        case none
        case native
        case executable
    }

    var kind: Kind
    var nativeAction: NativeAction
    var executable: ConfiguredExecutable

    init() {
        kind = .none
        nativeAction = NativeAction(kind: .bell)
        executable = ConfiguredExecutable(executable: "")
    }

    init(template: D200XActionTemplate) {
        if template == .customExecutable {
            kind = .executable
            nativeAction = NativeAction(kind: .bell)
            executable = ConfiguredExecutable(executable: "")
        } else {
            kind = .native
            nativeAction = template.defaultNativeAction ?? NativeAction(kind: .bell)
            executable = ConfiguredExecutable(executable: "")
        }
    }

    init(binding: D200XBinding?, actions: [String: ConfiguredExecutable], nativeActions: [String: NativeAction]) {
        self.init()
        switch binding?.kind ?? .disabled {
        case .disabled:
            return
        case .shortcut:
            kind = .native
            nativeAction = NativeAction(kind: .shortcut, shortcut: binding?.shortcut)
            executable = ConfiguredExecutable(executable: "")
        case .action:
            let actionID = binding?.actionID
            if let actionID, let action = nativeActions[actionID] {
                kind = .native
                nativeAction = action
                executable = ConfiguredExecutable(executable: "")
            } else if let actionID, let action = actions[actionID] {
                kind = .executable
                nativeAction = NativeAction(kind: .bell)
                executable = action
            }
        }
    }

    var validationMessage: String? {
        switch kind {
        case .none:
            return nil
        case .native:
            guard (try? nativeAction.validated()) == nil else { return nil }
            switch nativeAction.kind {
            case .media:
                return "Choose a playback operation."
            case .volume:
                return nativeAction.volume == .set
                    ? "Choose a volume from 0 to 100%."
                    : "Choose a volume operation."
            case .bell:
                return "Check the action fields."
            case .playSound:
                return "Choose an absolute path to an audio file."
            case .openApplication:
                return "Choose an absolute path to an application."
            case .openFile:
                return "Choose an absolute file path."
            case .openURL:
                return "Enter an HTTP or HTTPS URL with a host and no credentials."
            case .deckNotification:
                return "Use a concrete topic and provide valid one-line text or an application bundle ID."
            case .shortcut:
                return "Choose a valid keyboard shortcut."
            case .lockScreen:
                return "Lock Screen does not accept parameters."
            }
        case .executable:
            if executable.executable.isEmpty {
                return "Enter an absolute executable path."
            } else if (try? executable.validated()) == nil {
                return "Check the executable path, arguments, working directory and timeout."
            }
            return nil
        }
    }

    var summary: String {
        switch kind {
        case .none:
            "None"
        case .executable:
            "Custom Executable"
        case .native:
            switch nativeAction.kind {
            case .media:
                switch nativeAction.media {
                case .some(.playPause): "Play/Pause"
                case .some(.nextTrack): "Next Track"
                case .some(.previousTrack): "Previous Track"
                case .none: "Playback"
                }
            case .volume:
                switch nativeAction.volume {
                case .some(.up): "Volume Up"
                case .some(.down): "Volume Down"
                case .some(.mute): "Mute"
                case .some(.set): "Set Volume to \(nativeAction.percent ?? 0)%"
                case .none: "Volume"
                }
            case .bell: "Bell"
            case .playSound: "Play Sound"
            case .openApplication: "Open Application"
            case .openFile: "Open File"
            case .openURL: "Open URL"
            case .deckNotification: "Deck Notification"
            case .shortcut: "Keyboard Shortcut"
            case .lockScreen: "Lock Screen"
            }
        }
    }

    var systemSymbol: String {
        if kind == .none { return "minus.circle" }
        if kind == .native, nativeAction.kind == .volume, nativeAction.volume == .set {
            return D200XActionTemplate.volumeSet.systemSymbol
        }
        return template?.systemSymbol ?? "questionmark.circle"
    }

    var template: D200XActionTemplate? {
        switch kind {
        case .none: nil
        case .executable: .customExecutable
        case .native:
            switch nativeAction.kind {
            case .media:
                switch nativeAction.media {
                case .some(.playPause): .playPause
                case .some(.nextTrack): .nextTrack
                case .some(.previousTrack): .previousTrack
                case .none: nil
                }
            case .volume:
                switch nativeAction.volume {
                case .some(.up): .volumeUp
                case .some(.down): .volumeDown
                case .some(.mute): .volumeMute
                case .some(.set): .volumeSet
                case .none: nil
                }
            case .bell: .bell
            case .playSound: .playSound
            case .openApplication: .openApplication
            case .openFile: .openFile
            case .openURL: .openURL
            case .deckNotification: .deckNotification
            case .shortcut: .shortcut
            case .lockScreen: .lockScreen
            }
        }
    }

    func snapshot(actionID: String) throws -> D200XPresetActionSnapshot {
        switch kind {
        case .none:
            return D200XPresetActionSnapshot(binding: nil, actions: [:], nativeActions: [:])
        case .native:
            let action = try nativeAction.validated()
            if action.kind == .shortcut {
                guard let shortcut = action.shortcut else { throw ConfigurationValidationError.invalidD200XAction }
                return D200XPresetActionSnapshot(binding: .key(shortcut), actions: [:], nativeActions: [:])
            }
            guard ConfiguredExecutable.isValidIdentifier(actionID) else {
                throw ConfigurationValidationError.invalidD200XAction
            }
            return D200XPresetActionSnapshot(binding: .action(actionID), actions: [:], nativeActions: [actionID: action])
        case .executable:
            let action = try executable.validated()
            guard ConfiguredExecutable.isValidIdentifier(actionID) else {
                throw ConfigurationValidationError.invalidD200XAction
            }
            return D200XPresetActionSnapshot(binding: .action(actionID), actions: [actionID: action], nativeActions: [:])
        }
    }
}

struct D200XPresetActionSnapshot: Equatable {
    let binding: D200XBinding?
    let actions: [String: ConfiguredExecutable]
    let nativeActions: [String: NativeAction]
}
