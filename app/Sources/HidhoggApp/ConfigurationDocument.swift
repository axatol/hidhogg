import HidhoggDomain

struct ConfigurationDraft: Equatable {
    private(set) var saved: AppConfiguration
    private(set) var draft: AppConfiguration

    var isDirty: Bool { draft != saved }

    init(configuration: AppConfiguration = .empty) {
        saved = configuration
        draft = configuration
    }

    mutating func updateDraft(_ configuration: AppConfiguration) {
        draft = configuration
    }

    mutating func acceptSaved(_ configuration: AppConfiguration) {
        saved = configuration
    }

    mutating func acceptReload(_ configuration: AppConfiguration) {
        saved = configuration
        draft = configuration
    }
}
