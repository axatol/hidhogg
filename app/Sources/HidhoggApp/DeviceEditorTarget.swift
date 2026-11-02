import HidhoggDomain

enum DeviceEditorTarget: String, CaseIterable, Identifiable, Hashable {
    case back, forward, middle, wheelMode, thumbRest, verticalWheel, thumbWheel

    var id: Self { self }

    var control: MouseControl? {
        switch self {
        case .back: .back
        case .forward: .forward
        case .middle: .middle
        case .wheelMode: .wheelMode
        case .thumbRest: .thumbRest
        case .verticalWheel, .thumbWheel: nil
        }
    }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .middle: "Middle click"
        case .wheelMode: "Wheel mode button"
        case .thumbRest: "Thumb-rest button"
        case .verticalWheel: "Scroll wheel"
        case .thumbWheel: "Thumb wheel"
        }
    }
}
