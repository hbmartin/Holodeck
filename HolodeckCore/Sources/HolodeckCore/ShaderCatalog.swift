import Foundation
import CryptoKit

nonisolated public struct SceneDiscovery: Codable, Sendable, Equatable {
    public var tags: [String]
    public var moods: [String]
    public var motion: String
    public init(tags: [String], moods: [String], motion: String) {
        self.tags = tags; self.moods = moods; self.motion = motion
    }
    public var summary: String { (moods.map { $0.capitalized } + [motion.capitalized + " motion"]).joined(separator: " · ") }
    public func validate() throws {
        guard tags.count <= 32, moods.count <= 8, Set(tags).count == tags.count,
              Set(moods).count == moods.count,
              (tags + moods + [motion]).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 100 })
        else { throw CatalogError.invalidManifest }
    }
}

nonisolated public struct CatalogCollection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var shaderIDs: [String]
    public init(id: String, name: String, description: String, shaderIDs: [String]) {
        self.id = id; self.name = name; self.description = description; self.shaderIDs = shaderIDs
    }
}

nonisolated public struct ShaderDefinition: Identifiable, Sendable {
    public enum Category: String, Codable, Sendable {
        case procedural = "PROCEDURAL"
        case material = "3D MATERIAL"
    }
    public let id: String
    public let title: String
    public let category: Category
    public let description: String
    public let colors: [SIMD3<Float>]
    public let source: String
    public var updatedAt: Date? = nil
    public var preview: ShaderPreview? = nil
    public var discovery: SceneDiscovery? = nil
    public init(id: String, title: String, category: Category, description: String,
                colors: [SIMD3<Float>], source: String, updatedAt: Date? = nil, preview: ShaderPreview? = nil,
                discovery: SceneDiscovery? = nil) {
        self.id = id; self.title = title; self.category = category; self.description = description
        self.colors = colors; self.source = source; self.updatedAt = updatedAt; self.preview = preview
        self.discovery = discovery
    }
    public var sourceHash: String { CatalogHash.sha256(Data(source.utf8)) }
}

nonisolated public struct ShaderPreview: Sendable, Equatable {
    public let path: String
    public let hash: String
    public let publicationRevision: String
    public init(path: String, hash: String, publicationRevision: String) {
        self.path = path; self.hash = hash; self.publicationRevision = publicationRevision
    }
}

nonisolated public enum CatalogHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func isSHA(_ value: String, length: Int = 64) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

nonisolated public enum CatalogError: Error {
    case invalidManifest, invalidSource, invalidPreview, invalidResponse, oversizedResponse
}

nonisolated public struct CatalogManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: String
        public var name: String
        public var category: ShaderDefinition.Category
        public var description: String
        public var colors: [[Float]]
        public var updatedAt: String
        public var sourcePath: String
        public var sourceSHA256: String
        public var previewPath: String
        public var previewSHA256: String
        public var discovery: SceneDiscovery? = nil
    }
    public var schemaVersion: Int
    public var defaultShaderID: String
    public var sourceRevision: String
    public var shaders: [Entry]
    public var collections: [CatalogCollection]? = nil

    public static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    public func validate() throws {
        guard schemaVersion == 1, !shaders.isEmpty, shaders.count <= 500,
              CatalogHash.isSHA(sourceRevision, length: 40),
              Set(shaders.map(\.id)).count == shaders.count,
              shaders.contains(where: { $0.id == defaultShaderID }) else { throw CatalogError.invalidManifest }
        for shader in shaders {
            try shader.discovery?.validate()
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
        if let collections {
            guard collections.count <= 100, Set(collections.map(\.id)).count == collections.count else { throw CatalogError.invalidManifest }
            let ids = Set(shaders.map(\.id))
            for collection in collections {
                guard collection.id != "all", collection.id.count <= 100,
                      collection.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil,
                      !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, collection.name.count <= 200,
                      !collection.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, collection.description.count <= 2000,
                      !collection.shaderIDs.isEmpty, collection.shaderIDs.count <= 500,
                      Set(collection.shaderIDs).count == collection.shaderIDs.count,
                      Set(collection.shaderIDs).isSubset(of: ids) else { throw CatalogError.invalidManifest }
            }
        }
    }
}

/// A single JSON file makes disk activation atomic; sources are included and revalidated when read.
nonisolated public struct CatalogSnapshot: Codable, Sendable {
    public var manifest: CatalogManifest
    public var sources: [String: String]
    public var publicationRevision: String

    public init(manifest: CatalogManifest, sources: [String: String], publicationRevision: String) {
        self.manifest = manifest; self.sources = sources; self.publicationRevision = publicationRevision
    }
    public func validate() throws {
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

    public var shaders: [ShaderDefinition] {
        manifest.shaders.map { entry in
            ShaderDefinition(id: entry.id, title: entry.name, category: entry.category,
                             description: entry.description, colors: entry.colors.map { SIMD3($0[0], $0[1], $0[2]) },
                             source: sources[entry.id]!, updatedAt: CatalogManifest.date(entry.updatedAt),
                             preview: ShaderPreview(path: entry.previewPath, hash: entry.previewSHA256, publicationRevision: publicationRevision),
                             discovery: entry.discovery)
        }
    }

    public var initialShader: ShaderDefinition { shaders.first { $0.id == manifest.defaultShaderID }! }
    public var collections: [CatalogCollection] { SceneLibrary.collections(manifest.collections, shaders: shaders) }
}
