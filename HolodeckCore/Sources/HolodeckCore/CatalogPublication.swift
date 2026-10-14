import Foundation

nonisolated enum CatalogLimits {
    static let headBytes = 65_536
    static let manifestBytes = 2_097_152
    static let sourceBytes = 1_048_576
    static let totalSourceBytes = 16_777_216
    static let previewBytes = 8_388_608
    static let shaderCount = 500
}

/// Local revisions fingerprint the normalized manifest, without its self-reference.
nonisolated enum CatalogPublication {
    static func revision(for manifest: CatalogManifest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var canonical = try JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any] else {
            throw CatalogError.invalidManifest
        }
        canonical["sourceRevision"] = nil
        return CatalogHash.sha256(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
    }

    static func validate(_ manifest: CatalogManifest, revision: String) throws {
        guard CatalogHash.isSHA(revision), manifest.sourceRevision == revision,
              try self.revision(for: manifest) == revision else { throw CatalogError.invalidManifest }
    }

    static func encodedManifest(_ manifest: CatalogManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= CatalogLimits.manifestBytes else {
            throw LocalCatalogError.invalidFile("index.json", "Catalog exceeds 2 MiB.")
        }
        return data
    }
}

nonisolated enum CatalogPublicationFiles {
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw CatalogError.oversizedResponse }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw CatalogError.oversizedResponse }
        return data
    }
    static func verified(_ url: URL, hash: String, limit: Int, error: CatalogError) throws -> Data {
        let data = try read(url, limit: limit)
        guard CatalogHash.sha256(data) == hash else { throw error }
        return data
    }
}
