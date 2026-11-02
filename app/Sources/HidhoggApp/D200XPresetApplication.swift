import Foundation
import HidhoggDomain

enum D200XPresetApplication {
    enum Failure: LocalizedError {
        case invalidTarget

        var errorDescription: String? { "Choose a tile, front button or dial press for this preset, or a dial for rotation." }
    }

    static func applying(_ preset: D200XTilePreset, to configuration: D200XConfiguration,
                         control: D200XControl, applicationID: String?) throws -> D200XConfiguration {
        guard control.isTile || control == .side0 || control == .side1 || control.gesture == .press else {
            throw Failure.invalidTarget
        }
        _ = try preset.validated()
        var next = try configuration.validated()
        let bindings = copyActions([preset.binding ?? .disabled], actions: preset.actions,
                                   nativeActions: preset.nativeActions, into: &next)
        setBinding(bindings[0], control: control, applicationID: applicationID, in: &next)
        if control.isTile {
            if let applicationID { next.applicationTiles[applicationID, default: [:]][control.rawValue] = preset.appearance }
            else { next.tiles[control.rawValue] = preset.appearance }
        }
        return try next.validated()
    }

    static func applying(_ preset: D200XDialRotationPreset, to configuration: D200XConfiguration,
                         dialIndex: Int, applicationID: String?) throws -> D200XConfiguration {
        guard (0...2).contains(dialIndex),
              let left = D200XControl(rawValue: "dial\(dialIndex)Left"),
              let right = D200XControl(rawValue: "dial\(dialIndex)Right") else { throw Failure.invalidTarget }
        _ = try preset.validated()
        var next = try configuration.validated()
        let bindings = copyActions([preset.left, preset.right], actions: preset.actions,
                                   nativeActions: preset.nativeActions, into: &next)
        setBinding(bindings[0], control: left, applicationID: applicationID, in: &next)
        setBinding(bindings[1], control: right, applicationID: applicationID, in: &next)
        return try next.validated()
    }

    private static func setBinding(_ binding: D200XBinding, control: D200XControl,
                                   applicationID: String?, in configuration: inout D200XConfiguration) {
        if let applicationID { configuration.applications[applicationID, default: [:]][control.rawValue] = binding }
        else { configuration.defaults[control.rawValue] = binding }
    }

    private static func copyActions(_ bindings: [D200XBinding], actions: [String: ConfiguredExecutable],
                                    nativeActions: [String: NativeAction],
                                    into configuration: inout D200XConfiguration) -> [D200XBinding] {
        let sourceIDs = Set(actions.keys).union(nativeActions.keys)
        var occupied = Set(configuration.actionIDs).union(sourceIDs)
        var remapped: [String: String] = [:]
        for id in sourceIDs.sorted() {
            let definition = actions[id].map(ConfiguredActionDefinition.executable)
                ?? nativeActions[id].map(ConfiguredActionDefinition.native)
            let identicalID = configuration.actionDefinition(id: id) == definition ? id
                : configuration.actionIDs.first { configuration.actionDefinition(id: $0) == definition }
            if let identicalID {
                remapped[id] = identicalID
                continue
            }
            var destination = id
            if let existing = configuration.actionDefinition(id: id), existing != definition {
                var suffix = 1
                repeat {
                    let ending = "-preset-\(suffix)"
                    destination = String(id.prefix(64 - ending.utf8.count)) + ending
                    suffix += 1
                } while occupied.contains(destination)
                    && (sourceIDs.contains(destination) || configuration.actionDefinition(id: destination) != definition)
            }
            occupied.insert(destination)
            remapped[id] = destination
            if let action = actions[id] { configuration.actions[destination] = action }
            if let action = nativeActions[id] { configuration.nativeActions[destination] = action }
        }
        return bindings.map { binding in
            guard let id = binding.actionID, let destination = remapped[id] else { return binding }
            return .action(destination)
        }
    }
}
