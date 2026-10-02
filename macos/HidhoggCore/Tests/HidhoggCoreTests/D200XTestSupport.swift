import Foundation
import HidhoggCore

func decodeD200XProfile(positionFields: [String: String] = [:]) throws -> ConfiguredProfile {
    let positions = positionFields.keys.sorted().map { coordinate in
        "\(tomlQuoted(coordinate)) = { \(positionFields[coordinate]!) }"
    }.joined(separator: ", ")
    let positionsLine = positions.isEmpty ? "" : "positions = { \(positions) }"
    let source = """
    schema_version = 4
    adapter = "ulanzi.d200x"
    brightness = 80
    default_profile_id = "default"

    [profiles.default]
    label = "Default"
    \(positionsLine)
    """
    let configuration = try HidhoggConfigurationDecoder.decode(Data(source.utf8))
    guard let profile = configuration.profile(id: "default") else {
        throw D200XTestFailure.missingDefaultProfile
    }
    return profile
}

func tomlQuoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

enum D200XTestFailure: Error {
    case missingDefaultProfile
    case invalidArchive
    case decompressionFailed
    case pngDecodeFailed
}
