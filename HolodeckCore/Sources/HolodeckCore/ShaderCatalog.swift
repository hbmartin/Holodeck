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
    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func sanitized() throws -> Self {
        func unique(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.map(Self.normalized).filter { seen.insert($0).inserted }
        }
        let value = Self(tags: unique(tags), moods: unique(moods), motion: Self.normalized(motion))
        try value.validate()
        return value
    }
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
    public let sourceHash: String
    public var updatedAt: Date? = nil
    public var preview: ShaderPreview? = nil
    public var discovery: SceneDiscovery? = nil
    public init(id: String, title: String, category: Category, description: String,
                colors: [SIMD3<Float>], source: String, updatedAt: Date? = nil, preview: ShaderPreview? = nil,
                discovery: SceneDiscovery? = nil) {
        self.id = id; self.title = title; self.category = category; self.description = description
        self.colors = colors; self.source = source; self.updatedAt = updatedAt; self.preview = preview
        self.discovery = discovery
        self.sourceHash = CatalogHash.sha256(Data(source.utf8))
    }

    fileprivate init(entry: CatalogManifest.Entry, source: String, date: Date, revision: String) {
        id = entry.id; title = entry.name; category = entry.category; description = entry.description
        colors = entry.colors.map { SIMD3($0[0], $0[1], $0[2]) }
        self.source = source; sourceHash = entry.sourceSHA256; updatedAt = date
        preview = ShaderPreview(path: entry.previewPath, hash: entry.previewSHA256, publicationRevision: revision)
        discovery = entry.discovery
    }
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
        private enum CodingKeys: String, CodingKey {
            case id, name, category, description, colors, updatedAt, sourcePath, sourceSHA256, previewPath, previewSHA256, discovery
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            category = try values.decode(ShaderDefinition.Category.self, forKey: .category)
            description = try values.decode(String.self, forKey: .description)
            colors = try values.decode([[Float]].self, forKey: .colors)
            updatedAt = try values.decode(String.self, forKey: .updatedAt)
            sourcePath = try values.decode(String.self, forKey: .sourcePath)
            sourceSHA256 = try values.decode(String.self, forKey: .sourceSHA256)
            previewPath = try values.decode(String.self, forKey: .previewPath)
            previewSHA256 = try values.decode(String.self, forKey: .previewSHA256)
            do {
                discovery = try values.decodeIfPresent(SceneDiscovery.self, forKey: .discovery)?.sanitized()
            } catch {
                let shaderID = id
                Diagnostics.catalog.warning("Discarding discovery for \(shaderID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                discovery = nil
            }
        }
    }
    public var schemaVersion: Int
    public var defaultShaderID: String
    public var sourceRevision: String
    public var shaders: [Entry]
    public var collections: [CatalogCollection]? = nil

    public static func date(_ string: String) -> Date? {
        // FormatStyle.parse accepts a valid prefix, so require a complete timezone-bearing timestamp.
        guard string.range(of: #"\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3])(:?[0-5][0-9])?)\z"#,
                           options: .regularExpression) != nil else { return nil }
        let components = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        let year = components[0], month = components[1], day = components[2]
        let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard year > 0, day <= days[month - 1] else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string))
    }

    public func validate() throws {
        _ = try validatedDates()
    }

    fileprivate func validatedDates() throws -> [String: Date] {
        var dates: [String: Date] = [:]
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
                  let date = Self.date(shader.updatedAt),
                  shader.sourcePath == "sources/\(shader.id).metal",
                  shader.previewPath == "previews/\(shader.id).png",
                  CatalogHash.isSHA(shader.sourceSHA256), CatalogHash.isSHA(shader.previewSHA256)
            else { throw CatalogError.invalidManifest }
            dates[shader.id] = date
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
        return dates
    }

    fileprivate func sanitizingDiscovery() -> Self {
        var value = self
        for index in value.shaders.indices {
            guard let discovery = value.shaders[index].discovery else { continue }
            do { value.shaders[index].discovery = try discovery.sanitized() }
            catch {
                Diagnostics.catalog.warning("Discarding discovery for \(value.shaders[index].id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                value.shaders[index].discovery = nil
            }
        }
        return value
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
        _ = try validated()
    }

    public func validated() throws -> ValidatedCatalog {
        guard sources.count == manifest.shaders.count else { throw CatalogError.invalidManifest }
        var builder = try CatalogBuilder(manifest: manifest)
        for entry in manifest.shaders {
            guard let source = sources[entry.id] else { throw CatalogError.invalidSource }
            try builder.addSource(Data(source.utf8), for: entry)
        }
        return try builder.finish(revision: publicationRevision)
    }
}

/// Prepared once on the catalog actor; UI consumers cannot activate unvalidated wire data.
nonisolated public struct ValidatedCatalog: Sendable {
    public let snapshot: CatalogSnapshot
    public let shaders: [ShaderDefinition]
    public let initialShader: ShaderDefinition
    public let collections: [CatalogCollection]
    public let moods: [String]
    public let motions: [String]
    public var publicationRevision: String { snapshot.publicationRevision }

    fileprivate init(snapshot: CatalogSnapshot, shaders: [ShaderDefinition]) {
        self.snapshot = snapshot
        self.shaders = shaders
        initialShader = shaders.first { $0.id == snapshot.manifest.defaultShaderID }!
        collections = SceneLibrary.collections(snapshot.manifest.collections, shaders: shaders)
        moods = SceneLibrary.moods(shaders)
        motions = SceneLibrary.motions(shaders)
    }

    public func startupShader(savedID: String?) -> ShaderDefinition {
        shaders.first { $0.id == savedID } ?? initialShader
    }
}

/// The download and disk paths share validation without rehashing or reparsing at activation.
nonisolated struct CatalogBuilder {
    let manifest: CatalogManifest
    private let dates: [String: Date]
    private var sources: [String: String] = [:]
    private var sourceBytes = 0

    init(manifest: CatalogManifest) throws {
        self.manifest = manifest.sanitizingDiscovery()
        dates = try manifest.validatedDates()
    }

    mutating func addSource(_ data: Data, for entry: CatalogManifest.Entry) throws {
        guard !data.isEmpty, data.count <= 1_048_576,
              CatalogHash.sha256(data) == entry.sourceSHA256,
              let source = String(validating: data, as: UTF8.self) else { throw CatalogError.invalidSource }
        sourceBytes += data.count
        guard sourceBytes <= 16_777_216 else { throw CatalogError.oversizedResponse }
        sources[entry.id] = source
    }

    func finish(revision: String) throws -> ValidatedCatalog {
        guard CatalogHash.isSHA(revision, length: 40), sources.count == manifest.shaders.count else {
            throw CatalogError.invalidManifest
        }
        let shaders = manifest.shaders.map {
            ShaderDefinition(entry: $0, source: sources[$0.id]!, date: dates[$0.id]!, revision: revision)
        }
        return ValidatedCatalog(snapshot: CatalogSnapshot(manifest: manifest, sources: sources, publicationRevision: revision),
                                shaders: shaders)
    }
}
