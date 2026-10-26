public enum D200XAppearanceProperty: String, CaseIterable, Hashable, Sendable {
    case titleSize, background, titleColor, titlePlacement, titleAlignment, showTitle

    public var title: String {
        switch self {
        case .titleSize: "Font size"
        case .background: "Background color"
        case .titleColor: "Title color"
        case .titlePlacement: "Vertical placement"
        case .titleAlignment: "Horizontal alignment"
        case .showTitle: "Title visibility"
        }
    }
}

extension D200XTileAppearance {
    public func copying(_ properties: Set<D200XAppearanceProperty>, from source: Self) -> Self {
        var result = self
        for property in properties {
            switch property {
            case .titleSize: result.titleSize = source.titleSize
            case .background: result.backgroundHex = source.backgroundHex
            case .titleColor: result.titleColorHex = source.titleColorHex
            case .titlePlacement: result.titlePlacement = source.titlePlacement
            case .titleAlignment: result.titleAlignment = source.titleAlignment
            case .showTitle: result.showTitle = source.showTitle
            }
        }
        return result
    }
}
