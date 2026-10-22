import HidhoggDomain

extension AppModel {
    func applyNavigationPreset(_ preset: NavigationPreset) {
        guard canEditConfiguration else { return }
        guard let index = document.draft.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else {
            return
        }

        cancelRecording()

        var configuration = document.draft
        let binding = ControlBinding.key(preset.shortcut)
        if let applicationID = selectedApplicationID {
            var overrides = configuration.devices[index].applications[applicationID] ?? [:]
            overrides[selectedControl.rawValue] = binding
            configuration.devices[index].applications[applicationID] = overrides
        } else {
            configuration.devices[index].defaults[selectedControl.rawValue] = binding
        }
        updateDraft(configuration)
    }
}
