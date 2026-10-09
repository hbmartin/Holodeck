import Foundation
import CryptoKit

nonisolated struct ShaderDefinition: Identifiable, Sendable {
    enum Category: String, Codable, Sendable {
        case procedural = "PROCEDURAL"
        case material = "3D MATERIAL"
    }
    let id: String
    let title: String
    let category: Category
    let description: String
    let colors: [SIMD3<Float>]
    let source: String
    var updatedAt: Date? = nil
    var preview: ShaderPreview? = nil
    var sourceHash: String { CatalogHash.sha256(Data(source.utf8)) }
}

nonisolated struct ShaderPreview: Sendable, Equatable {
    let path: String
    let hash: String
    let publicationRevision: String
}

nonisolated enum CatalogHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isSHA(_ value: String, length: Int = 64) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

nonisolated enum CatalogError: Error {
    case invalidManifest, invalidSource, invalidPreview, invalidResponse, oversizedResponse
}

nonisolated struct CatalogManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var id: String
        var name: String
        var category: ShaderDefinition.Category
        var description: String
        var colors: [[Float]]
        var updatedAt: String
        var sourcePath: String
        var sourceSHA256: String
        var previewPath: String
        var previewSHA256: String
    }
    var schemaVersion: Int
    var defaultShaderID: String
    var sourceRevision: String
    var shaders: [Entry]

    static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    func validate() throws {
        guard schemaVersion == 1, !shaders.isEmpty, shaders.count <= 500,
              CatalogHash.isSHA(sourceRevision, length: 40),
              Set(shaders.map(\.id)).count == shaders.count,
              shaders.contains(where: { $0.id == defaultShaderID }) else { throw CatalogError.invalidManifest }
        for shader in shaders {
            guard !shader.id.isEmpty, shader.id.count <= 100,
                  shader.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil,
                  !shader.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !shader.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  shader.name.count <= 200, shader.description.count <= 2000,
                  shader.colors.count == 2,
                  shader.colors.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }),
                  Self.date(shader.updatedAt) != nil,
                  shader.sourcePath == "sources/\(shader.id).metal",
                  shader.previewPath == "previews/\(shader.id).png",
                  CatalogHash.isSHA(shader.sourceSHA256), CatalogHash.isSHA(shader.previewSHA256)
            else { throw CatalogError.invalidManifest }
        }
    }
}

/// A single JSON file makes disk activation atomic; sources are included and revalidated when read.
nonisolated struct CatalogSnapshot: Codable, Sendable {
    var manifest: CatalogManifest
    var sources: [String: String]
    var publicationRevision: String

    func validate() throws {
        try manifest.validate()
        guard CatalogHash.isSHA(publicationRevision, length: 40), sources.count == manifest.shaders.count,
              sources.values.reduce(0, { $0 + $1.utf8.count }) <= 16_777_216 else {
            throw CatalogError.invalidManifest
        }
        for entry in manifest.shaders {
            guard let source = sources[entry.id], !source.isEmpty, source.utf8.count <= 1_048_576,
                  CatalogHash.sha256(Data(source.utf8)) == entry.sourceSHA256 else { throw CatalogError.invalidSource }
        }
    }

    var shaders: [ShaderDefinition] {
        manifest.shaders.map { entry in
            ShaderDefinition(id: entry.id, title: entry.name, category: entry.category,
                             description: entry.description, colors: entry.colors.map { SIMD3($0[0], $0[1], $0[2]) },
                             source: sources[entry.id]!, updatedAt: CatalogManifest.date(entry.updatedAt),
                             preview: ShaderPreview(path: entry.previewPath, hash: entry.previewSHA256, publicationRevision: publicationRevision))
        }
    }

    var initialShader: ShaderDefinition { shaders.first { $0.id == manifest.defaultShaderID }! }
}
