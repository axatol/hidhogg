enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, permissions, configuration, diagnostics

    var id: Self { self }
}
