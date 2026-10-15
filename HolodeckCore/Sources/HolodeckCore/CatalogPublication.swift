import Foundation

nonisolated enum CatalogLimits {
    static let headBytes = 65_536
    static let manifestBytes = 2_097_152
    static let sourceBytes = 1_048_576
    static let totalSourceBytes = 16_777_216
    static let previewBytes = 8_388_608
    static let shaderCount = 500

    static func checkByteCount(_ count: Int, limit: Int, path: String, kind: String) throws {
        guard count <= limit else {
            throw LocalCatalogError.invalidFile(path, CatalogError.sizeLimit(kind: kind, actual: count, limit: limit).localizedDescription)
        }
    }
}

/// Proof is created only after hashing the exact schema-2 wire bytes.
nonisolated struct LocalPublicationEvidence: Sendable {
    let manifestBytes: Data
    let revision: String
    fileprivate init(manifestBytes: Data, revision: String) {
        self.manifestBytes = manifestBytes; self.revision = revision
    }
}

nonisolated enum CatalogPublication {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let defaultShaderID: String
        let shaders: [CatalogManifest.Entry]
        let collections: [CatalogCollection]?
    }
    private struct Cache: Codable {
        let formatVersion: Int
        let revision: String
        let manifestBytes: Data
        let sources: [String: String]
    }

    static func encodedManifest(_ manifest: CatalogManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Manifest(schemaVersion: 2, defaultShaderID: manifest.defaultShaderID,
            shaders: manifest.shaders, collections: manifest.collections))
        try CatalogLimits.checkByteCount(data.count, limit: CatalogLimits.manifestBytes,
                                         path: "index.json", kind: "Catalog manifest")
        return data
    }

    static func builder(_ data: Data, revision: String, kind: CatalogSource.Kind) throws -> CatalogBuilder {
        guard data.count <= CatalogLimits.manifestBytes else { throw CatalogError.oversizedResponse }
        if kind == .standard {
            return try CatalogBuilder(manifest: JSONDecoder().decode(CatalogManifest.self, from: data))
        }
        guard CatalogHash.isSHA(revision), CatalogHash.sha256(data) == revision else { throw CatalogError.invalidManifest }
        let wire = try JSONDecoder().decode(Manifest.self, from: data)
        guard wire.schemaVersion == 2 else { throw CatalogError.invalidManifest }
        let manifest = CatalogManifest(schemaVersion: 1, defaultShaderID: wire.defaultShaderID,
            sourceRevision: revision, shaders: wire.shaders, collections: wire.collections)
        return try CatalogBuilder(manifest: manifest,
            evidence: LocalPublicationEvidence(manifestBytes: data, revision: revision))
    }

    static func accepts(_ catalog: ValidatedCatalog, kind: CatalogSource.Kind) -> Bool {
        kind == .standard || catalog.localPublicationEvidence?.revision == catalog.publicationRevision
    }

    static func persisted(_ catalog: ValidatedCatalog, kind: CatalogSource.Kind) throws -> Data {
        guard accepts(catalog, kind: kind) else { throw CatalogError.invalidManifest }
        if kind == .standard { return try JSONEncoder().encode(catalog.snapshot) }
        guard let proof = catalog.localPublicationEvidence else { throw CatalogError.invalidManifest }
        return try JSONEncoder().encode(Cache(formatVersion: 2, revision: proof.revision,
            manifestBytes: proof.manifestBytes, sources: catalog.snapshot.sources))
    }

    static func restored(_ data: Data, kind: CatalogSource.Kind) throws -> ValidatedCatalog {
        if kind == .standard { return try JSONDecoder().decode(CatalogSnapshot.self, from: data).validated() }
        let cache = try JSONDecoder().decode(Cache.self, from: data)
        guard cache.formatVersion == 2 else { throw CatalogError.invalidManifest }
        let builder = try builder(cache.manifestBytes, revision: cache.revision, kind: kind)
        guard cache.sources.count == builder.manifest.shaders.count else { throw CatalogError.invalidManifest }
        let sources = try Dictionary(uniqueKeysWithValues: builder.manifest.shaders.map { entry in
            guard let text = cache.sources[entry.id] else { throw CatalogError.invalidSource }
            return (entry.id, Data(text.utf8))
        })
        return try finish(builder, sources: sources, revision: cache.revision)
    }

    static func finish(_ builder: CatalogBuilder, sources: [String: Data], revision: String) throws -> ValidatedCatalog {
        var builder = builder
        for entry in builder.manifest.shaders {
            guard let bytes = sources[entry.id] else { throw CatalogError.invalidSource }
            try builder.addSource(bytes, for: entry)
        }
        return try builder.finish(revision: revision)
    }
}

nonisolated enum CatalogPublicationFiles {
    static func read(_ url: URL, limit: Int, root: URL? = nil) throws -> Data {
        let root = root ?? url.deletingLastPathComponent()
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw CatalogError.invalidResponse }
        return try BoundedCatalogReader(root: root).read(String(url.path.dropFirst(prefix.count)), limit: limit).bytes
    }
    static func verified(_ url: URL, hash: String, limit: Int, error: CatalogError, root: URL? = nil) throws -> Data {
        let data = try read(url, limit: limit, root: root)
        guard CatalogHash.sha256(data) == hash else { throw error }
        return data
    }
}
