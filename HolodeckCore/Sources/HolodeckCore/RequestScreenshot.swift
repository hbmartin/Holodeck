import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum RequestScreenshot {
    static func encode(pixels: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0, width * height <= 16_777_216,
              pixels.count == bytesPerRow * height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShaderRequestError.unavailable("Unable to capture screenshot.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        guard let resized = context.makeImage() else { throw ShaderRequestError.invalidRequest }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ShaderRequestError.invalidRequest
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShaderRequestError.invalidRequest }
        return data as Data
    }
}
