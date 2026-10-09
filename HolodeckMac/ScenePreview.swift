import AppKit
import HolodeckCore
import SwiftUI

struct ScenePreview: View {
    let shader: ShaderDefinition
    let service: CatalogService
    @State private var image: NSImage?
    @State private var imageHash: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: shader.colors.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 88, height: 49.5)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: shader.preview) {
            if imageHash != shader.preview?.hash { image = nil; imageHash = nil }
            guard image == nil else { return }
            guard let preview = shader.preview,
                  let decoded = try? await service.previewImage(preview, maxPixelSize: 176), !Task.isCancelled else { return }
            image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            imageHash = preview.hash
        }
    }
}
