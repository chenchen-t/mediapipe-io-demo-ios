import CoreGraphics
import UIKit
import XCTest

final class StickerCutoutTests: XCTestCase {
    /// A camera photo held in a normal portrait orientation has a raw sensor buffer that's
    /// *landscape* (tagged `.right`) even though it displays as portrait — `UIImage.size` reflects
    /// the displayed (portrait) dimensions, but `UIImage.cgImage.width/height` reflect the raw
    /// (landscape) buffer. `StickerCutout` must build its working canvas from the display-oriented
    /// size, since that's the space the segmentation mask (via `MPImage`, which rotates for
    /// inference) and the user's stroke coordinates are both in. Regression test for a real bug:
    /// using `image.cgImage.width/height` directly produced a landscape-shaped result for a
    /// portrait photo.
    func testCutoutRespectsDisplayOrientationNotRawSensorOrientation() throws {
        // Raw sensor buffer: 60 wide x 40 tall (landscape).
        let rawWidth = 60
        let rawHeight = 40
        let rawCGImage = try XCTUnwrap(solidColorCGImage(width: rawWidth, height: rawHeight, color: (200, 120, 60)))

        // `.right`: the photo displays rotated 90° from the raw buffer — portrait, 40 wide x 60
        // tall — matching how a real camera photo taken in a normal portrait hold is tagged.
        let rotatedImage = UIImage(cgImage: rawCGImage, scale: 1, orientation: .right)
        XCTAssertEqual(rotatedImage.size, CGSize(width: rawHeight, height: rawWidth), "sanity check: UIImage.size should already reflect the display (portrait) dimensions")

        // A mask sized to the *displayed* (portrait) dimensions, matching what MPImage would
        // produce — entirely white (255), i.e. "everything is foreground".
        let mask = try XCTUnwrap(solidColorCGImage(width: rawHeight, height: rawWidth, color: (255, 255, 255), grayscale: true))

        let result = try XCTUnwrap(StickerCutout.cutout(
            image: rotatedImage, mask: mask,
            positivePoints: [StickerStrokePoint(x: 0.5, y: 0.5)], padding: 0
        ))

        // A "select everything" mask should crop to (approximately) the full canvas — if that
        // canvas were built from the raw buffer's dimensions (the bug), the result would be
        // landscape (width > height); built correctly from the display dimensions, it's portrait.
        XCTAssertLessThan(result.size.width, result.size.height, "cutout of a portrait photo should stay portrait, not flip to landscape")
    }

    private func solidColorCGImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8), grayscale: Bool = false) -> CGImage? {
        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerPixel = grayscale ? 1 : 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        if grayscale {
            context.setFillColor(gray: CGFloat(color.0) / 255, alpha: 1)
        } else {
            context.setFillColor(
                red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1
            )
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
