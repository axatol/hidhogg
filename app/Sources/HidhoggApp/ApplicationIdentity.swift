import Foundation

struct ApplicationIdentity: Sendable {
    static let current = ApplicationIdentity(
        processID: ProcessInfo.processInfo.processIdentifier,
        buildID: Bundle.main.object(forInfoDictionaryKey: "HidhoggBuildID") as? String ?? "development",
        bundleURL: Bundle.main.bundleURL
    )

    let processID: Int32
    let buildID: String
    let bundleURL: URL
}
