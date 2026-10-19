import Foundation
import HidhoggDomain

enum ConfigurationFixtures {
    static let toml = """
        schema_version = 1

        [[devices]]
        id = "logitech.mx-master-3s"

        [devices.defaults.back]
        kind = "shortcut"

        [devices.defaults.back.shortcut]
        key_code = 4
        modifiers = ["command", "shift"]

        [devices.defaults.forward]
        kind = "disabled"

        [devices.applications."com.example.Editor_ID".back]
        kind = "disabled"
        """

    static var configuration: AppConfiguration {
        AppConfiguration(devices: [
            DeviceBindings(
                id: AppConfiguration.logitechProfileID,
                defaults: [
                    "back": .key(KeyboardShortcut(keyCode: 4, modifiers: [.command, .shift])),
                    "forward": .disabled
                ],
                applications: [
                    "com.example.Editor_ID": ["back": .disabled]
                ]
            )
        ])
    }

    static func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
