import AppKit
import HidhoggDomain
import SwiftUI
import UniformTypeIdentifiers

struct D200XPresetFieldsView: View {
    @ObservedObject var model: D200XModel
    @Binding var name: String
    @Binding var appearance: D200XTileAppearance
    @Binding var action: D200XPresetActionDraft
    let showsAppearance: Bool
    let previewIconSymbol: String?

    @State private var isAppearanceExpanded = false
    @State private var isImageImporterPresented = false
    @State private var isImportingImage = false
    @State private var importError: String?
    @State private var imageImportTask: Task<Void, Never>?
    @State private var activeImageImportID: UUID?
    @State private var previewIconData: Data?

    init(
        model: D200XModel,
        name: Binding<String>,
        appearance: Binding<D200XTileAppearance>,
        action: Binding<D200XPresetActionDraft>,
        showsAppearance: Bool,
        previewIconSymbol: String? = nil
    ) {
        self.model = model
        self._name = name
        self._appearance = appearance
        self._action = action
        self.showsAppearance = showsAppearance
        self.previewIconSymbol = previewIconSymbol
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Self.color(forHex: appearance.backgroundHex) },
            set: { appearance.backgroundHex = Self.hex(for: $0) }
        )
    }

    private var titleColor: Binding<Color> {
        Binding(
            get: { Self.color(forHex: appearance.titleColorHex ?? "FFFFFF") },
            set: { appearance.titleColorHex = Self.hex(for: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Preset") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canEdit)
                    .cardContentPadding()
            }

            if showsAppearance {
                previewPair
                DisclosureGroup("Customize Appearance", isExpanded: $isAppearanceExpanded) {
                    appearanceEditor
                }
            }

            D200XPresetActionEditorView(draft: $action, configuration: model.configuration)
                .disabled(!model.canEdit)

            if let importError {
                Text(importError)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false,
            onCompletion: handleImageImporterResult
        )
        .onDisappear {
            imageImportTask?.cancel()
        }
        .task(id: previewIconSymbol) {
            guard let previewIconSymbol else {
                previewIconData = nil
                return
            }
            previewIconData = try? D200XPresetIconRenderer.pngData(systemSymbol: previewIconSymbol)
        }
    }

    private var previewPair: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("Square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                D200XTilePreview(
                    appearance: appearance,
                    wide: false,
                    labelOverride: nil,
                    assetDirectory: model.assetDirectory,
                    presetIcon: previewIconData
                )
                .frame(width: 92, height: 92)
            }
            VStack(spacing: 4) {
                Text("Wide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                D200XTilePreview(
                    appearance: appearance,
                    wide: true,
                    labelOverride: nil,
                    assetDirectory: model.assetDirectory,
                    presetIcon: previewIconData
                )
                .frame(width: 164, height: 92)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Tile text", text: $appearance.label)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.canEdit)

            ColorPicker("Background color", selection: backgroundColor, supportsOpacity: false)
                .disabled(!model.canEdit)
            TextField("Background hex", text: $appearance.backgroundHex)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Background color as six hexadecimal digits")
                .disabled(!model.canEdit)

            Toggle("Show title", isOn: $appearance.showTitle)
                .disabled(!model.canEdit)
            HStack {
                Text("Title size")
                Spacer()
                Text("\(Int(appearance.titleSize)) pt")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $appearance.titleSize, in: 8...48, step: 1)
                .disabled(!model.canEdit)

            Picker("Title placement", selection: $appearance.titlePlacement) {
                Text("Top").tag(D200XTitlePlacement.top)
                Text("Center").tag(D200XTitlePlacement.center)
                Text("Bottom").tag(D200XTitlePlacement.bottom)
            }
            .disabled(!model.canEdit)

            Picker("Title alignment", selection: $appearance.titleAlignment) {
                Text("Left").tag(D200XTitleAlignment.left)
                Text("Center").tag(D200XTitleAlignment.center)
                Text("Right").tag(D200XTitleAlignment.right)
            }
            .disabled(!model.canEdit)

            Toggle("Use custom title color", isOn: Binding(
                get: { appearance.titleColorHex != nil },
                set: { appearance.titleColorHex = $0 ? (appearance.titleColorHex ?? "FFFFFF") : nil }
            ))
            .disabled(!model.canEdit)
            if appearance.titleColorHex != nil {
                ColorPicker("Title color", selection: titleColor, supportsOpacity: false)
                    .disabled(!model.canEdit)
                TextField("Title color hex", text: Binding(
                    get: { appearance.titleColorHex ?? "FFFFFF" },
                    set: { appearance.titleColorHex = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Title color as six hexadecimal digits")
                .disabled(!model.canEdit)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appearance.imageAsset == nil ? "No image" : "Image included")
                    Text("PNG or JPEG")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Image…", systemImage: "photo") {
                    isImageImporterPresented = true
                }
                .disabled(!model.canEdit || !model.isConfigured || isImportingImage)
            }

            if appearance.imageAsset != nil {
                Button("Remove Image", systemImage: "trash") {
                    appearance.imageAsset = nil
                }
                .disabled(!model.canEdit || isImportingImage)
            }
            if isImportingImage {
                ProgressView("Importing image…")
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func handleImageImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importImage(from: url)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            importError = error.localizedDescription
        }
    }

    private func importImage(from url: URL) {
        imageImportTask?.cancel()
        let importID = UUID()
        activeImageImportID = importID
        let originalName = name
        let originalAppearance = appearance
        isImportingImage = true
        importError = nil
        imageImportTask = Task { @MainActor in
            defer {
                if activeImageImportID == importID {
                    activeImageImportID = nil
                    imageImportTask = nil
                    isImportingImage = false
                }
            }
            do {
                let reference = try await model.importPresetImage(from: url)
                try Task.checkCancellation()
                guard name == originalName, appearance == originalAppearance else { return }
                appearance.imageAsset = reference
            } catch is CancellationError {
                return
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private static func color(forHex hex: String) -> Color {
        guard hex.utf8.count == 6, let value = UInt32(hex, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }

    private static func hex(for color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
