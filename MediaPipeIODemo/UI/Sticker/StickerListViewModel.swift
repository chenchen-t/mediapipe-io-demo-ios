import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class StickerListViewModel {
    private let repository: StickerRepository

    var images: [String: UIImage] = [:]

    init(repository: StickerRepository) {
        self.repository = repository
    }

    /// Lazily loads and caches each grid cell's PNG from disk, matching the Archive grid's
    /// per-item lazy thumbnail loading.
    func loadImageIfNeeded(for sticker: Sticker) {
        guard images[sticker.id] == nil else { return }
        Task {
            if let image = repository.loadImage(for: sticker) {
                images[sticker.id] = image
            }
        }
    }

    func delete(_ sticker: Sticker) {
        repository.deleteSticker(sticker)
        images[sticker.id] = nil
    }

    func clearAll() {
        repository.deleteAllStickers()
        images.removeAll()
    }
}
