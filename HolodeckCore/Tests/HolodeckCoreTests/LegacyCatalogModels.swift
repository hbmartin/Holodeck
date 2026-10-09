// Frozen pre-discovery schema-1 decoder for compatibility tests.
import Foundation
import CryptoKit

nonisolated public struct LegacyShaderDefinition: Identifiable, Sendable {
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
    public var preview: LegacyShaderPreview? = nil
    public init(id: String, title: String, category: Category, description: String,
                colors: [SIMD3<Float>], source: String, updatedAt: Date? = nil, preview: LegacyShaderPreview? = nil) {
        self.id = id; self.title = title; self.category = category; self.description = description
        self.colors = colors; self.source = source; self.updatedAt = updatedAt; self.preview = preview
    }
    public var sourceHash: String { LegacyCatalogHash.sha256(Data(source.utf8)) }
}

nonisolated public struct LegacyShaderPreview: Sendable, Equatable {
    public let path: String
    public let hash: String
    public let publicationRevision: String
    public init(path: String, hash: String, publicationRevision: String) {
        self.path = path; self.hash = hash; self.publicationRevision = publicationRevision
    }
}

nonisolated public enum LegacyCatalogHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func isSHA(_ value: String, length: Int = 64) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

nonisolated public enum LegacyCatalogError: Error {
    case invalidManifest, invalidSource, invalidPreview, invalidResponse, oversizedResponse
}

nonisolated public struct LegacyCatalogManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: String
        public var name: String
        public var category: LegacyShaderDefinition.Category
        public var description: String
        public var colors: [[Float]]
        public var updatedAt: String
        public var sourcePath: String
        public var sourceSHA256: String
        public var previewPath: String
        public var previewSHA256: String
    }
    public var schemaVersion: Int
    public var defaultShaderID: String
    public var sourceRevision: String
    public var shaders: [Entry]

    public static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    public func validate() throws {
        guard schemaVersion == 1, !shaders.isEmpty, shaders.count <= 500,
              LegacyCatalogHash.isSHA(sourceRevision, length: 40),
              Set(shaders.map(\.id)).count == shaders.count,
              shaders.contains(where: { $0.id == defaultShaderID }) else { throw LegacyCatalogError.invalidManifest }
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
                  LegacyCatalogHash.isSHA(shader.sourceSHA256), LegacyCatalogHash.isSHA(shader.previewSHA256)
            else { throw LegacyCatalogError.invalidManifest }
        }
    }
}

/// A single JSON file makes disk activation atomic; sources are included and revalidated when read.
nonisolated public struct LegacyCatalogSnapshot: Codable, Sendable {
    public var manifest: LegacyCatalogManifest
    public var sources: [String: String]
    public var publicationRevision: String

    public init(manifest: LegacyCatalogManifest, sources: [String: String], publicationRevision: String) {
        self.manifest = manifest; self.sources = sources; self.publicationRevision = publicationRevision
    }
    public func validate() throws {
        try manifest.validate()
        guard LegacyCatalogHash.isSHA(publicationRevision, length: 40), sources.count == manifest.shaders.count,
              sources.values.reduce(0, { $0 + $1.utf8.count }) <= 16_777_216 else {
            throw LegacyCatalogError.invalidManifest
        }
        for entry in manifest.shaders {
            guard let source = sources[entry.id], !source.isEmpty, source.utf8.count <= 1_048_576,
                  LegacyCatalogHash.sha256(Data(source.utf8)) == entry.sourceSHA256 else { throw LegacyCatalogError.invalidSource }
        }
    }

    public var shaders: [LegacyShaderDefinition] {
        manifest.shaders.map { entry in
            LegacyShaderDefinition(id: entry.id, title: entry.name, category: entry.category,
                             description: entry.description, colors: entry.colors.map { SIMD3($0[0], $0[1], $0[2]) },
                             source: sources[entry.id]!, updatedAt: LegacyCatalogManifest.date(entry.updatedAt),
                             preview: LegacyShaderPreview(path: entry.previewPath, hash: entry.previewSHA256, publicationRevision: publicationRevision))
        }
    }

    public var initialShader: LegacyShaderDefinition { shaders.first { $0.id == manifest.defaultShaderID }! }
}
