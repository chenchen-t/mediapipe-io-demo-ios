import Foundation
import SwiftData
import UIKit

@MainActor
final class StickerRepository {
    private let modelContext: ModelContext
    private let segmenterEngine: InteractiveSegmenterEngine

    init(modelContext: ModelContext, segmenterEngine: InteractiveSegmenterEngine) {
        self.modelContext = modelContext
        self.segmenterEngine = segmenterEngine
    }

    func allStickers() -> [Sticker] {
        let descriptor = FetchDescriptor<Sticker>(sortBy: [SortDescriptor(\.createdAtMillis, order: .reverse)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func loadImage(for sticker: Sticker) -> UIImage? {
        UIImage(contentsOfFile: StickerLocator.url(for: sticker).path)
    }

    func deleteSticker(_ sticker: Sticker) {
        try? FileManager.default.removeItem(at: StickerLocator.url(for: sticker))
        modelContext.delete(sticker)
        try? modelContext.save()
    }

    /// Backs the gallery's "Clear All" action — deletes every saved sticker's PNG and metadata.
    func deleteAllStickers() {
        for sticker in allStickers() {
            try? FileManager.default.removeItem(at: StickerLocator.url(for: sticker))
            modelContext.delete(sticker)
        }
        try? modelContext.save()
    }

    /// Runs the segmenter's encoder pass on a newly captured/picked photo — must be called before
    /// `segment`, and again whenever the source image changes.
    func setImage(_ image: UIImage) async throws {
        try await segmenterEngine.setImage(image)
    }

    /// Runs the segmenter's decoder pass for the current strokes, returning the raw mask (not yet
    /// resized to the source image — see `StickerCutout`).
    func segment(strokes: [StickerStroke]) async throws -> CGImage? {
        try await segmenterEngine.segment(strokes: strokes)
    }

    /// Recovers from a segmenter failure — see `TextSummarizerEngine.reset`.
    func resetSegmenterEngine() async {
        await segmenterEngine.reset()
    }

    /// Cuts the foreground out of `image` using `mask` and saves it as a new sticker.
    /// `positivePoints` are the current positive strokes' points — see `StickerCutout.cutout` for
    /// why they're needed (the mask's foreground/background value convention isn't fixed).
    @discardableResult
    func saveSticker(image: UIImage, mask: CGImage, positivePoints: [StickerStrokePoint]) throws -> Sticker {
        guard let cutout = StickerCutout.cutout(image: image, mask: mask, positivePoints: positivePoints) else {
            throw RepositoryError.stickerCutoutFailed
        }
        guard let pngData = cutout.pngData() else {
            throw RepositoryError.stickerCutoutFailed
        }
        let id = UUID().uuidString
        let fileName = "\(id).png"
        try pngData.write(to: StickerLocator.stickersDirectory.appendingPathComponent(fileName))

        let sticker = Sticker(id: id, fileName: fileName, createdAtMillis: Int64(Date().timeIntervalSince1970 * 1000))
        modelContext.insert(sticker)
        try? modelContext.save()
        return sticker
    }
}
