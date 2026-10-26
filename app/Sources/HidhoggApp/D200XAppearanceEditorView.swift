import AppKit
import HidhoggDomain
import SwiftUI
import UniformTypeIdentifiers

struct D200XAppearanceEditorView: View {
    @ObservedObject var model: D200XModel
    @State private var labelDraft: String
    @State private var backgroundHexDraft: String
    @State private var titleColorHexDraft: String
    @State private var isImagePickerPresented = false
    @State private var isImportingImage = false
    @State private var imagePickerControl: D200XControl?
    @State private var importError: String?
    @State private var isApplyingToOthers = false
    @State private var copiedProperties: Set<D200XAppearanceProperty> = [.titleSize, .background]

    private var canEditAppearance: Bool {
        model.canEdit && model.isConfigured && model.selectedControl.isTile
    }

    private var hasValidBackgroundHex: Bool { Self.isValidHex(backgroundHexDraft) }
    private var hasValidTitleColorHex: Bool { Self.isValidHex(titleColorHexDraft) }
    private var usesCustomTitleColor: Bool { model.appearance.titleColorHex != nil }

    init(model: D200XModel) {
        self.model = model
        let appearance = model.appearance
        _labelDraft = State(initialValue: appearance.label)
        _backgroundHexDraft = State(initialValue: appearance.backgroundHex)
        _titleColorHexDraft = State(initialValue: appearance.titleColorHex ?? "FFFFFF")
    }

    var body: some View {
        GroupBox("Key appearance") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Label", text: $labelDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEditAppearance)
                    .onChange(of: labelDraft) { _, value in
                        guard value.count <= 64 else { return }
                        updateAppearance { $0.label = value }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    ColorPicker(
                        "Background",
                        selection: Binding(
                            get: { Self.color(forHex: backgroundHexDraft) },
                            set: { backgroundHexDraft = Self.hex(for: $0) }
                        ),
                        supportsOpacity: false
                    )
                    .disabled(!canEditAppearance)
                    TextField("Six-digit hex color", text: $backgroundHexDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Key background color as six hexadecimal digits")
                        .disabled(!canEditAppearance)
                        .onChange(of: backgroundHexDraft) { _, value in
                            guard Self.isValidHex(value) else { return }
                            updateAppearance { $0.backgroundHex = value.uppercased() }
                        }
                }

                if !hasValidBackgroundHex {
                    Text("Enter six hexadecimal digits without a # prefix.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Show title", isOn: appearanceBinding(\.showTitle))
                    .disabled(!canEditAppearance)

                Button("Apply Appearance to Other Tiles…", systemImage: "square.on.square") {
                    isApplyingToOthers = true
                }.disabled(!canEditAppearance)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Title size")
                        Spacer()
                        Text("\(Int(model.appearance.titleSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: appearanceBinding(\.titleSize), in: 8...48, step: 1)
                        .disabled(!canEditAppearance)
                        .accessibilityLabel("Title size")
                }

                Picker("Title placement", selection: appearanceBinding(\.titlePlacement)) {
                    Text("Top").tag(D200XTitlePlacement.top)
                    Text("Center").tag(D200XTitlePlacement.center)
                    Text("Bottom").tag(D200XTitlePlacement.bottom)
                }
                .disabled(!canEditAppearance)

                Picker("Title alignment", selection: appearanceBinding(\.titleAlignment)) {
                    Text("Left").tag(D200XTitleAlignment.left)
                    Text("Center").tag(D200XTitleAlignment.center)
                    Text("Right").tag(D200XTitleAlignment.right)
                }
                .disabled(!canEditAppearance)

                Toggle("Use custom title color", isOn: Binding(
                    get: { usesCustomTitleColor },
                    set: setCustomTitleColor
                ))
                .disabled(!canEditAppearance)

                if usesCustomTitleColor {
                    ColorPicker(
                        "Title color",
                        selection: Binding(
                            get: { Self.color(forHex: titleColorHexDraft) },
                            set: { titleColorHexDraft = Self.hex(for: $0) }
                        ),
                        supportsOpacity: false
                    )
                    .disabled(!canEditAppearance)
                    TextField("Six-digit hex color", text: $titleColorHexDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Title color as six hexadecimal digits")
                        .disabled(!canEditAppearance)
                        .onChange(of: titleColorHexDraft) { _, value in
                            guard Self.isValidHex(value) else { return }
                            updateAppearance { $0.titleColorHex = value.uppercased() }
                        }
                    if !hasValidTitleColorHex {
                        Text("Enter six hexadecimal digits without a # prefix.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.appearance.imageAsset == nil ? "No tile image" : "Tile image selected")
                        Text("PNG or JPEG, up to 16 MiB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Image…", systemImage: "photo") {
                        presentImagePicker()
                    }
                    .disabled(!canEditAppearance || isImportingImage)
                    .accessibilityHint("Choose a PNG or JPEG image for this key.")
                }

                if model.appearance.imageAsset != nil {
                    Button("Remove Image", systemImage: "trash") {
                        model.removeImage()
                    }
                    .disabled(!canEditAppearance || isImportingImage)
                }

                if labelDraft.count > 64 {
                    Text("Key labels can contain at most 64 characters.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Appearance changes save automatically on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $isApplyingToOthers) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply appearance to other tiles").font(.title2.bold())
                Text("Copy selected properties from \(model.selectedControl.title) to the other 13 tiles in \(model.applicationID ?? "All apps"). Labels, images and actions stay as they are.")
                ForEach(D200XAppearanceProperty.allCases, id: \.self) { property in
                    Toggle(property.title, isOn: Binding(
                        get: { copiedProperties.contains(property) },
                        set: { if $0 { copiedProperties.insert(property) } else { copiedProperties.remove(property) } }
                    ))
                }
                HStack {
                    Button("Cancel", role: .cancel) { isApplyingToOthers = false }
                    Button("Apply to Other Tiles") {
                        model.applyAppearanceToOtherTiles(properties: copiedProperties)
                        isApplyingToOthers = false
                    }.disabled(copiedProperties.isEmpty || !canEditAppearance)
                }
            }.padding(24).frame(width: 420)
        }
        .onChange(of: model.selectedControl) { _, _ in isApplyingToOthers = false }
        .onChange(of: model.applicationID) { _, _ in isApplyingToOthers = false }
        .onChange(of: model.selectedControl) { _, _ in syncDrafts() }
        .onChange(of: model.applicationID) { _, _ in syncDrafts() }
        .onChange(of: model.appearance) { _, _ in syncDrafts() }
        .fileImporter(
            isPresented: $isImagePickerPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false
        ) { handleImagePickerResult($0) }
        .alert("Could Not Import Image", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "The image could not be imported.")
        }
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<D200XTileAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { model.appearance[keyPath: keyPath] },
            set: { value in updateAppearance { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateAppearance(_ update: (inout D200XTileAppearance) -> Void) {
        guard canEditAppearance else { return }
        var appearance = model.appearance
        update(&appearance)
        model.setAppearance(appearance)
    }

    private func presentImagePicker() {
        guard canEditAppearance else { return }
        importError = nil
        imagePickerControl = model.selectedControl
        isImagePickerPresented = true
    }

    private func handleImagePickerResult(_ result: Result<[URL], Error>) {
        let targetControl = imagePickerControl
        imagePickerControl = nil

        switch result {
        case .success(let urls):
            guard let targetControl,
                  canImportImage(for: targetControl),
                  let url = urls.first else { return }
            importImage(from: url, for: targetControl)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            importError = error.localizedDescription
        }
    }

    private func importImage(from url: URL, for targetControl: D200XControl) {
        guard canImportImage(for: targetControl) else { return }
        Task { @MainActor in
            guard canImportImage(for: targetControl) else { return }
            isImportingImage = true
            defer { isImportingImage = false }
            do {
                try await model.importImage(from: url)
            } catch is CancellationError {
                return
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func canImportImage(for control: D200XControl) -> Bool {
        model.canEdit && model.isConfigured && control.isTile && model.selectedControl == control
    }

    private func setCustomTitleColor(_ enabled: Bool) {
        updateAppearance { appearance in
            if enabled {
                appearance.titleColorHex = appearance.titleColorHex ?? Self.contrastingHex(for: appearance.backgroundHex)
            } else {
                appearance.titleColorHex = nil
            }
        }
    }

    private func syncDrafts() {
        let appearance = model.appearance
        labelDraft = appearance.label
        backgroundHexDraft = appearance.backgroundHex
        titleColorHexDraft = appearance.titleColorHex ?? "FFFFFF"
    }

    private static func isValidHex(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func color(forHex value: String) -> Color {
        guard isValidHex(value), let rgb = UInt32(value, radix: 16) else { return .black }
        return Color(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
    }

    private static func hex(for color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    private static func contrastingHex(for hex: String) -> String {
        guard isValidHex(hex), let value = UInt32(hex, radix: 16) else { return "FFFFFF" }
        let red = Double((value >> 16) & 255) / 255
        let green = Double((value >> 8) & 255) / 255
        let blue = Double(value & 255) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.56 ? "000000" : "FFFFFF"
    }
}
