import HidhoggDomain

enum DeviceEditorTarget: String, CaseIterable, Identifiable, Hashable {
    case back, forward, verticalWheel, thumbWheel

    var id: Self { self }

    var control: MouseControl? {
        switch self {
        case .back: .back
        case .forward: .forward
        case .verticalWheel, .thumbWheel: nil
        }
    }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .verticalWheel: "Vertical wheel"
        case .thumbWheel: "Thumb wheel"
        }
    }
}
