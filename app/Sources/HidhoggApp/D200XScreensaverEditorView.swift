import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct D200XScreensaverEditorView: View {
    @ObservedObject var model: D200XModel
    @State private var choosingImage = false
    @State private var confirmingOverwrite = false
    @State private var source: Data?
    @StateObject private var previewRenderer = D200XScreensaverPreview()
    @State private var zoom = 1.0
    @State private var horizontal = 0.0
    @State private var vertical = 0.0
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var revision = UUID()
    @State private var confirmedImage: Data?
    @State private var sourceIsConfirmed = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screensaver image").font(.headline)
            Text("Choose an image and review the crop. Confirmation replaces the saved screensaver and previews it on the deck for five seconds. Later crop changes update that saved image; the original cannot be restored here.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose PNG or JPEG…") { choosingImage = true }
                .disabled(loading || model.isApplyingScreensaver)
            D200XSavedScreensaverPreview(store: model.screensaverPreviewStore)
            if let preview = previewRenderer.image, let image = NSImage(data: preview) {
                if !sourceIsConfirmed {
                    D200XScreensaverLayoutGuide(image: image)
                        .accessibilityLabel("Screensaver crop preview")
                }
                Text("Adjust the crop to position the image across the deck. Gaps between the screens affect placement.")
                    .font(.caption).foregroundStyle(.secondary)
                cropSlider("Zoom", value: $zoom, range: 1...3)
                cropSlider("Horizontal crop", value: $horizontal, range: -1...1)
                cropSlider("Vertical crop", value: $vertical, range: -1...1)
                if sourceIsConfirmed {
                    Button("Preview on Deck") { sendToDeck(preview) }
                        .disabled(!model.canDeliverNotification || model.isApplyingScreensaver || loading || previewRenderer.isLoading)
                } else {
                    Button("Apply Screensaver Image…") {
                        confirmedImage = preview
                        confirmingOverwrite = true
                    }
                    .disabled(!model.canDeliverNotification || model.isApplyingScreensaver || loading || previewRenderer.isLoading)
                }
            }
            if loading || previewRenderer.isLoading { ProgressView("Preparing preview…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let error = previewRenderer.errorMessage { Text(error).foregroundStyle(.red) }
            if let message = model.screensaverMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.png, .jpeg]) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
        .confirmationDialog("Replace the saved screensaver image?", isPresented: $confirmingOverwrite, titleVisibility: .visible) {
            Button("Replace Saved Image", role: .destructive) {
                guard let confirmedImage else { return }
                sourceIsConfirmed = true
                sendToDeck(confirmedImage)
            }
            Button("Cancel", role: .cancel) { confirmedImage = nil }
        } message: {
            Text("This replaces the saved image. Hidhogg cannot restore the original.")
        }
        .onChange(of: zoom) { _, _ in updatePreview() }
        .onChange(of: horizontal) { _, _ in updatePreview() }
        .onChange(of: vertical) { _, _ in updatePreview() }
        .onChange(of: previewRenderer.renderedRevision) { _, _ in
            if sourceIsConfirmed, let image = previewRenderer.image { sendToDeck(image) }
        }
        .onChange(of: previewRenderer.errorMessage) { _, error in
            if sourceIsConfirmed, error != nil { model.finishScreensaverPreview() }
        }
        .onDisappear {
            revision = UUID()
            loadTask?.cancel()
            loading = false
            previewRenderer.cancel()
            model.finishScreensaverPreview()
        }
    }

    private func cropSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
        .disabled(loading || model.isApplyingScreensaver)
    }

    private func load(_ url: URL) {
        let token = UUID()
        revision = token
        sourceIsConfirmed = false
        confirmedImage = nil
        source = nil
        previewRenderer.clear()
        model.finishScreensaverPreview()
        loading = true
        errorMessage = nil
        loadTask?.cancel()
        loadTask = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let read = Task.detached(priority: .utility) { try D200XScreensaverImage.readSelectedImage(url) }
                let data = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: { read.cancel() }
                guard !Task.isCancelled, revision == token else { return }
                source = data
                zoom = 1
                horizontal = 0
                vertical = 0
                loading = false
                updatePreview()
            } catch {
                guard revision == token else { return }
                loading = false
                errorMessage = "Choose a valid PNG or JPEG up to 16 MiB and 16 million pixels."
            }
        }
    }

    private func sendToDeck(_ image: Data) {
        errorMessage = nil
        let token = revision
        Task {
            guard sourceIsConfirmed, revision == token else { return }
            do { try await model.applyScreensaver(image, confirmedPersistentOverwrite: true) }
            catch is CancellationError {}
            catch { errorMessage = "The screensaver image could not be applied. Connect the deck and try again." }
        }
    }

    private func updatePreview() {
        guard let source else { return }
        if sourceIsConfirmed { model.holdScreensaverPreview() }
        previewRenderer.update(D200XScreensaverCropRequest(source: source, zoom: zoom,
            horizontal: horizontal, vertical: vertical))
    }
}
