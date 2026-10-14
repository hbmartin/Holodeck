#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ShaderPNG {
    public static func encode(pixels: Data, bytesPerRow: Int, width: Int, height: Int) throws -> Data {
        try validateRenderDimensions(width: width, height: height)
        guard bytesPerRow == width * 4, pixels.count == bytesPerRow * height,
              let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ShaderToolError("Unable to encode PNG")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ShaderToolError("Unable to encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShaderToolError("PNG encoding failed") }
        return data as Data
    }

    static func isValid(_ png: Data) -> Bool {
        guard png.count <= CatalogLimits.previewBytes, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width == 1280 && image.height == 720
    }

    static func gradient(colors: [[Float]]) throws -> Data {
        guard colors.count == 2, colors.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
            throw ShaderToolError("Invalid gradient colors")
        }
        let width = 1280, height = 720
        var row = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let t = Float(x) / Float(width - 1)
            for channel in 0..<3 {
                row[x * 4 + 2 - channel] = UInt8((255 * (colors[0][channel] * (1 - t) + colors[1][channel] * t)).rounded())
            }
        }
        var pixels = Data(capacity: width * height * 4)
        for _ in 0..<height { pixels.append(contentsOf: row) }
        return try encode(pixels: pixels, bytesPerRow: width * 4, width: width, height: height)
    }
}
#endif
