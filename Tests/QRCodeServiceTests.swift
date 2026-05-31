import AppKit
import Foundation

@main
struct QRCodeServiceTests {
    static func main() throws {
        let text = "https://example.com/easysign?q=二维码"
        let image = try QRCodeService.makeQRCodeImage(text: text, size: CGSize(width: 300, height: 300))

        assert(image.size.width == 300, "image width")
        assert(image.size.height == 300, "image height")

        guard let pngData = QRCodeService.pngData(from: image) else {
            fail("png data")
        }
        assert(!pngData.isEmpty, "png data not empty")

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail("cg image")
        }
        assert(cgImage.width > 0, "cg image width")
        assert(QRCodeService.scanQRCode(in: blankImage()).isEmpty, "blank image scan")
    }

    static func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Assertion failed: \(message)\n".utf8))
        exit(1)
    }

    static func blankImage() -> CGImage {
        let width = 80
        let height = 80
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
