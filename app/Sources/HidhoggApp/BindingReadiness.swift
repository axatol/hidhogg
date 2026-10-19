struct BindingReadiness: Equatable {
    let configurationIsSaved: Bool
    let permissionIsGranted: Bool
    let deviceIsReady: Bool
    let supportsRequiredControls: Bool

    var canEnable: Bool {
        configurationIsSaved
            && permissionIsGranted
            && deviceIsReady
            && supportsRequiredControls
    }
}
