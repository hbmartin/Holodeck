import AppKit
import HolodeckCore
import SwiftUI

struct ScenePreview: View {
    let shader: ShaderDefinition
    let service: CatalogService
    @State private var image: NSImage?

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
            image = nil
            guard let preview = shader.preview,
                  let data = try? await service.preview(preview), !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }
}
