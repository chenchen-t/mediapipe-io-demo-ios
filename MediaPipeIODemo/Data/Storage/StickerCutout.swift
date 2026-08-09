import CoreGraphics
import UIKit

enum StickerCutout {
    /// Produces a copy of `image` with everything the mask doesn't cover made transparent — a
    /// hard threshold, not a soft/feathered edge, matching the classic "die-cut sticker" look and
    /// sidestepping premultiplied-alpha bugs a partial-alpha blend would introduce (a pixel that's
    /// still opaque RGB but rendered at, say, 40% alpha shows dark fringing unless the RGB is
    /// re-premultiplied to match — thresholding avoids that whole class of bug by only ever using
    /// alpha 0 or 255).
    ///
    /// `mask` doesn't need to be the same pixel size as `image` — the model outputs it at its own
    /// internal working resolution; this resizes it to match `image` while compositing.
    ///
    /// Also trims the result down to the tight bounding box of what's left opaque (plus a small
    /// padding margin), rather than keeping the full source photo's canvas size — otherwise every
    /// sticker carries around however much empty transparent space surrounded the subject in the
    /// original photo.
    ///
    /// `positivePoints` (normalized 0...1, the same points the positive strokes were drawn at) are
    /// used to figure out which side of the mask's binary split is actually the foreground —
    /// confirmed empirically that this is NOT a fixed global convention: one stroke/photo
    /// combination rendered the selected subject as low mask values, a different stroke location
    /// on the very same photo rendered it as high values instead. Rather than guess a direction,
    /// sample the mask at a point we know for certain is meant to be foreground (because the user
    /// put a positive stroke there) and treat whichever side that lands on as foreground for this
    /// specific result.
    static func cutout(image: UIImage, mask: CGImage, positivePoints: [StickerStrokePoint], padding: Int = 12) -> UIImage? {
        // `image.cgImage`'s width/height are the raw, un-rotated sensor buffer — they ignore
        // `imageOrientation` entirely, unlike `image.size`, which IS orientation-corrected. Camera
        // photos are almost never `.up` (typically `.right` for a normal portrait hold: the raw
        // buffer is landscape even though the photo displays as portrait). The mask, in contrast,
        // comes from `MPImage(uiImage:)`, which DOES rotate for orientation before inference — so
        // it's sized/aligned to the *displayed* photo. Operating on `image.cgImage` directly would
        // stretch that display-oriented mask onto the wrong (rotated, wrong-aspect-ratio) raw
        // buffer. Redraw into a fresh, `.up`-oriented image first so every pixel operation below
        // happens in the same, orientation-correct space as the mask and the stroke coordinates.
        let uprightImage: UIImage
        if image.imageOrientation == .up {
            uprightImage = image
        } else {
            // `UIGraphicsImageRenderer(size:)` defaults to the *device's screen scale* (3x on
            // most current iPhones) unless told otherwise — confirmed on-device: without an
            // explicit format, this silently produced a ~109-megapixel (9072x12096, 3x the
            // expected 3024x4032) image for a real camera photo. Forcing `format.scale = 1` keeps
            // the redraw at `image.size`'s exact pixel dimensions, matching the raw sensor buffer
            // this is meant to replace, not blown up by an unrelated display-density factor.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            uprightImage = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        guard let sourceCGImage = uprightImage.cgImage else { return nil }
        let width = sourceCGImage.width
        let height = sourceCGImage.height
        guard width > 0, height > 0 else { return nil }

        guard let maskBytes = grayscaleBytes(from: mask, width: width, height: height) else { return nil }

        let midpoint = 128
        let foregroundIsLow = isForegroundLow(maskBytes: maskBytes, width: width, height: height, positivePoints: positivePoints, midpoint: midpoint)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Single pass: zero out background pixels' RGBA, and track the bounding box of whatever's
        // left opaque — both operate on this same buffer, so the crop below stays in exactly the
        // coordinate space the bounds were measured in (no separate top-down/bottom-up ambiguity
        // between "where I measured" and "what I crop").
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let isForeground = foregroundIsLow ? (maskBytes[i] < midpoint) : (maskBytes[i] >= midpoint)
                if !isForeground {
                    let base = i * 4
                    pixels[base] = 0
                    pixels[base + 1] = 0
                    pixels[base + 2] = 0
                    pixels[base + 3] = 0
                } else {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard let fullCGImage = context.makeImage() else { return nil }
        guard maxX >= minX, maxY >= minY else {
            // Nothing passed the mask threshold — return the (fully transparent) full image rather
            // than crash on an inverted crop rect. `fullCGImage` was drawn from `uprightImage`, so
            // it's already `.up`-oriented — tagging it with `.up` here (not `image.imageOrientation`)
            // avoids re-rotating already-correct pixels.
            return UIImage(cgImage: fullCGImage, scale: uprightImage.scale, orientation: .up)
        }

        let cropX = max(0, minX - padding)
        let cropY = max(0, minY - padding)
        let cropWidth = min(width - cropX, maxX - minX + 1 + padding * 2)
        let cropHeight = min(height - cropY, maxY - minY + 1 + padding * 2)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        guard let croppedCGImage = fullCGImage.cropping(to: cropRect) else {
            return UIImage(cgImage: fullCGImage, scale: uprightImage.scale, orientation: .up)
        }
        return UIImage(cgImage: croppedCGImage, scale: uprightImage.scale, orientation: .up)
    }

    /// Samples the mask at each positive-stroke point and averages them; if that average sits
    /// below the midpoint, the foreground is the low side of the mask, otherwise the high side.
    /// Falls back to "low = foreground" (this codebase's original, still-plausible guess) if there
    /// are no positive points to sample at all.
    private static func isForegroundLow(maskBytes: [UInt8], width: Int, height: Int, positivePoints: [StickerStrokePoint], midpoint: Int) -> Bool {
        guard !positivePoints.isEmpty else { return true }
        let samples = positivePoints.map { point -> Int in
            let x = min(max(0, Int(point.x * Double(width))), width - 1)
            let y = min(max(0, Int(point.y * Double(height))), height - 1)
            return Int(maskBytes[y * width + x])
        }
        let average = samples.reduce(0, +) / samples.count
        return average < midpoint
    }

    private static func grayscaleBytes(from cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = data.withUnsafeMutableBytes({ pointer in
            CGContext(
                data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
