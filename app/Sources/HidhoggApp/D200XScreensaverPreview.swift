import Combine
import Foundation

struct D200XScreensaverCropRequest: Sendable {
    let source: Data
    let zoom: Double
    let horizontal: Double
    let vertical: Double
}

@MainActor
final class D200XScreensaverPreview: ObservableObject {
    @Published private(set) var image: Data?
    @Published private(set) var renderedRevision: UInt64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var revision: UInt64 = 0
    private var pending: D200XScreensaverCropRequest?
    private var loop: Task<Void, Never>?
    private var worker: Task<Data, Error>?
    private let delay: @Sendable (Duration) async throws -> Void
    private let render: @Sendable (D200XScreensaverCropRequest) throws -> Data

    init(delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         render: @escaping @Sendable (D200XScreensaverCropRequest) throws -> Data = {
             try D200XScreensaverImage.crop($0.source, zoom: $0.zoom, horizontal: $0.horizontal, vertical: $0.vertical)
         }) {
        self.delay = delay
        self.render = render
    }

    isolated deinit { loop?.cancel(); worker?.cancel() }

    func update(_ request: D200XScreensaverCropRequest) {
        revision &+= 1
        pending = request
        worker?.cancel()
        isLoading = true
        errorMessage = nil
        startLoop()
    }

    func clear() {
        cancel()
        image = nil
        errorMessage = nil
    }

    func cancel() {
        revision &+= 1
        pending = nil
        loop?.cancel()
        worker?.cancel()
        isLoading = false
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.renderPending()
        }
    }

    private func renderPending() async {
        defer {
            worker = nil
            loop = nil
            if pending != nil { startLoop() }
        }
        while !Task.isCancelled, let request = pending {
            let token = revision
            do { try await delay(.milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            if token != revision { continue }
            pending = nil
            let render = render
            let current = Task.detached(priority: .utility) { try render(request) }
            worker = current
            do {
                let data = try await withTaskCancellationHandler {
                    try await current.value
                } onCancel: { current.cancel() }
                guard !Task.isCancelled else { return }
                if token == revision {
                    image = data
                    renderedRevision &+= 1
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                if token == revision {
                    errorMessage = "The image crop could not be prepared."
                    isLoading = false
                }
            }
            worker = nil
        }
    }
}
