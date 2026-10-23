import UlanziD200X

extension D200XFailure {
    var userMessage: String {
        switch self {
        case .unavailable: "No D200X found. Check its USB connection and close Ulanzi Studio."
        case .ambiguous: "More than one matching deck was found. Connect one D200X for this profile."
        case .disconnected: "D200X was disconnected."
        case .busy: "A D200X connection operation is already running."
        case .cancelled: "D200X operation cancelled."
        case .timeout: "D200X did not respond before the request timed out."
        case .transport: "D200X USB communication failed. Check the cable and close Ulanzi Studio."
        case .overflow: "D200X events exceeded the bounded queue. The connection was stopped."
        case .invalidFrame: "D200X returned an unsupported or malformed report."
        case .invalidChecksum: "A D200X response failed its checksum check."
        case .invalidIdentity: "The connected deck returned an invalid identity."
        case .unsupportedDevice: "The connected deck is not a supported solution-02 D200X."
        case .invalidPage: "The D200X page contains invalid images or coordinates."
        case .oversized: "The D200X page exceeds the transfer size limit."
        }
    }
}
