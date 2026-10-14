#if os(macOS)
import Foundation

public struct GeneratedShaderPreview: Sendable {
    public let png: Data
    public let cacheKey: String
    public let diagnostic: String?
}

/// GPU work runs away from the directory actor, which can continue serving its current publication.
public actor ShaderPreviewGenerator {
    typealias Render = @Sendable (String) async throws -> Data
    private let directory: URL
    private let rendererVersion: String
    private let render: Render

    public init(directory: URL, rendererVersion: String = "1") {
        self.directory = directory; self.rendererVersion = rendererVersion
        render = Self.renderPNG
    }

    init(directory: URL, rendererVersion: String = "1", render: @escaping Render) {
        self.directory = directory; self.rendererVersion = rendererVersion; self.render = render
    }

    nonisolated static func renderPNG(_ source: String) async throws -> Data {
        let context = try MetalContext(source: source)
        let renderer = try OffscreenRenderer(context: context, width: 1280, height: 720, pixelFormat: .bgra8Unorm_srgb)
        let frame = try renderer.render(time: 3)
        return try ShaderPNG.encode(pixels: frame.pixels, bytesPerRow: frame.bytesPerRow, width: 1280, height: 720)
    }

    public func preview(source: String, colors: [[Float]]) async throws -> GeneratedShaderPreview {
        let key = CatalogHash.sha256(Data("\(rendererVersion):1280:720:3:bgra8Unorm_srgb:\(CatalogHash.sha256(Data(source.utf8)))".utf8))
        let pngURL = directory.appendingPathComponent(key + ".png")
        let hashURL = directory.appendingPathComponent(key + ".sha256")
        if let size = try? pngURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_388_608,
           let png = try? Data(contentsOf: pngURL),
           let hash = try? String(contentsOf: hashURL, encoding: .utf8),
           CatalogHash.sha256(png) == hash, ShaderPNG.isValid(png) {
            return GeneratedShaderPreview(png: png, cacheKey: key, diagnostic: nil)
        }
        let png: Data
        do {
            png = try await render(source)
            guard ShaderPNG.isValid(png) else { throw ShaderToolError("Renderer returned an invalid preview PNG") }
        } catch {
            return GeneratedShaderPreview(png: try ShaderPNG.gradient(colors: colors), cacheKey: key,
                diagnostic: error.localizedDescription)
        }
        // Disk failures reject reload, rather than being mislabeled as rendering failures.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: pngURL, options: .atomic)
        try Data(CatalogHash.sha256(png).utf8).write(to: hashURL, options: .atomic)
        return GeneratedShaderPreview(png: png, cacheKey: key, diagnostic: nil)
    }

    public func prune(keeping keys: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["png", "sha256"].contains(file.pathExtension) && !keys.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
#endif
