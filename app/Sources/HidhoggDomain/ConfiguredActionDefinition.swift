public enum ConfiguredActionDefinition: Equatable, Sendable {
    case executable(ConfiguredExecutable)
    case native(NativeAction)
}
