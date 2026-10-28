import Combine
import Foundation

@MainActor
final class D200XScreensaverPreviewStore: ObservableObject {
    @Published private(set) var image: Data?
    @Published private(set) var message: String?
    private var directory: URL?
    private var revision: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    func configure(directory: URL?) {
        revision &+= 1
        let token = revision
        self.directory = directory
        image = nil
        message = nil
        loadTask?.cancel()
        guard let directory else { return }
        let pendingWrite = writeTask
        loadTask = Task { [weak self] in
            if let pendingWrite { await pendingWrite.value }
            let data = await Task.detached(priority: .utility) {
                try? D200XAssetStore(directory: directory).screensaverImage()
            }.value
            guard let self, !Task.isCancelled, self.revision == token else { return }
            self.image = data
        }
    }

    func recordSent(_ jpeg: Data) {
        revision &+= 1
        let token = revision
        image = jpeg
        message = nil
        loadTask?.cancel()
        guard let directory else { return }
        let previous = writeTask
        writeTask = Task { [weak self] in
            if let previous { await previous.value }
            let saved = await Task.detached(priority: .utility) {
                do {
                    try D200XAssetStore(directory: directory).saveScreensaverImage(jpeg)
                    return true
                } catch { return false }
            }.value
            guard let self, self.revision == token, !saved else { return }
            self.message = "Image sent, but the local preview could not be saved."
        }
    }
}
