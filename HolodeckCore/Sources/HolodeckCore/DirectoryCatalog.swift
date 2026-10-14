#if os(macOS)
import Foundation
import ImageIO
import Darwin

nonisolated struct DirectoryCatalogFileOperations: Sendable {
    var swap: @Sendable (URL, URL) throws -> Void = { stage, destination in
        let failure = stage.withUnsafeFileSystemRepresentation { source -> Int32 in
            guard let source else { return EINVAL }
            return destination.withUnsafeFileSystemRepresentation { target in
                guard let target else { return EINVAL }
                return renamex_np(source, target, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        guard failure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
    }
    var writeMarker: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
}

public struct ShaderPreviewWarning: Sendable, Equatable {
    public let shaderID: String
    public let message: String
}

public struct CatalogReloadResult: Sendable {
    public let catalog: ValidatedCatalog
    public let previewWarnings: [ShaderPreviewWarning]
}

/// App-owned immutable publications. Requests never read the authoring directory.
public actor DirectoryCatalog {
    private let directory: URL
    private let files: DirectoryCatalogFileOperations
    private let previews: ShaderPreviewGenerator
    private var reloading = false
    private var reloadWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRevision: String?
    private var allowed: [String: Set<String>] = [:]
    private var leases: [UUID: String] = [:]

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Holodeck/LocalCatalog", isDirectory: true),
                previewGenerator: ShaderPreviewGenerator? = nil) {
        self.directory = directory; files = DirectoryCatalogFileOperations()
        previews = previewGenerator ?? ShaderPreviewGenerator(directory: directory.appendingPathComponent("preview-cache"))
    }

    init(directory: URL, files: DirectoryCatalogFileOperations, previewGenerator: ShaderPreviewGenerator? = nil) {
        self.directory = directory; self.files = files
        previews = previewGenerator ?? ShaderPreviewGenerator(directory: directory.appendingPathComponent("preview-cache"))
    }

    public nonisolated var source: CatalogSource {
        CatalogSource { [self] request, limit in try await get(request, limit: limit) }
    }

    public func pin(_ revision: String, for connection: UUID) { leases[connection] = revision }
    public func release(_ connection: UUID) { leases[connection] = nil; trim() }

    /// Restore only copied, hash-verified assets from our own last successful publication.
    public func cached() throws -> ValidatedCatalog? {
        let marker = directory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let head = try JSONDecoder().decode(CatalogHead.self, from: Data(contentsOf: marker))
        guard CatalogHash.isSHA(head.revision) else { throw CatalogError.invalidManifest }
        let publication = directory.appendingPathComponent(head.revision)
        func read(_ path: String, limit: Int) throws -> Data {
            try readPublicationFile(publication.appendingPathComponent(path), limit: limit)
        }
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: read("catalog.json", limit: 2_097_152))
        var builder = try CatalogBuilder(manifest: manifest), paths: Set<String> = ["catalog.json"]
        for entry in manifest.shaders {
            try builder.addSource(read(entry.sourcePath, limit: 1_048_576), for: entry)
            let preview = try read(entry.previewPath, limit: 8_388_608)
            guard CatalogHash.sha256(preview) == entry.previewSHA256 else { throw CatalogError.invalidPreview }
            paths.insert(entry.sourcePath); paths.insert(entry.previewPath)
        }
        let catalog = try builder.finish(revision: head.revision)
        currentRevision = head.revision; allowed[head.revision] = paths
        return catalog
    }

    @discardableResult
    public func reload(from root: URL) async throws -> CatalogReloadResult {
        if reloading { await withCheckedContinuation { reloadWaiters.append($0) } }
        else { reloading = true }
        defer {
            if reloadWaiters.isEmpty { reloading = false }
            else { reloadWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await reloadCandidate(from: root)
    }

    private func reloadCandidate(from root: URL) async throws -> CatalogReloadResult {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = directory.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("previews"), withIntermediateDirectories: true)

        func read(_ path: String, limit: Int) throws -> Data {
            let url = root.appendingPathComponent(path)
            do {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    throw LocalCatalogError.invalidFile(path, "File must stay inside the selected folder.")
                }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw CatalogError.oversizedResponse }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= limit else { throw CatalogError.oversizedResponse }
                return bytes
            } catch { throw LocalCatalogError.invalidFile(path, error.localizedDescription) }
        }
        func json(_ path: String) throws -> [String: Any] {
            do {
                guard let value = try JSONSerialization.jsonObject(with: read(path, limit: 2_097_152)) as? [String: Any] else {
                    throw CatalogError.invalidManifest
                }
                return value
            } catch { throw LocalCatalogError.invalidFile(path, error.localizedDescription) }
        }
        let index = try json("index.json")
        guard let ids = index["shaders"] as? [String], (1...500).contains(ids.count),
              Set(ids).count == ids.count, let defaultID = index["defaultShaderID"] as? String, ids.contains(defaultID),
              ids.allSatisfy({ $0.count <= 100 && $0.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil }) else {
            throw LocalCatalogError.invalidFile("index.json", "Expected unique shader IDs and an indexed defaultShaderID.")
        }
        var entries: [[String: Any]] = [], sources: [String: String] = [:], paths: Set<String> = ["catalog.json"]
        var total = 0
        for id in ids {
            let folder = "shaders/\(id)/", metadataPath = folder + "metadata.json"
            let metadata = try json(metadataPath)
            guard metadata["id"] as? String == id, let shared = metadata["shared"] as? [String],
                  shared == ["common", "fragment"] || shared == ["common", "material", "fragment"] else {
                throw LocalCatalogError.invalidFile(metadataPath, "ID and shared helper declaration are invalid.")
            }
            let sourcePaths = shared.dropLast().map { "shared/\($0).metal" } + [folder + "body.metal", "shared/fragment.metal"]
            var bytes = Data()
            for path in sourcePaths { bytes.append(try read(path, limit: 1_048_576)) }
            total += bytes.count
            guard !bytes.isEmpty, bytes.count <= 1_048_576, total <= 16_777_216,
                  let text = String(validating: bytes, as: UTF8.self) else {
                throw LocalCatalogError.invalidFile(folder + "body.metal", "Assembled source must be UTF-8 and within the source size limits.")
            }
            let dependencies = sourcePaths + [metadataPath]
            let date = try dependencies.map { path in
                try root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            }.max() ?? .distantPast
            var entry = metadata.filter { ["id", "name", "category", "description", "colors", "discovery"].contains($0.key) }
            entry["updatedAt"] = date.ISO8601Format(.init(includingFractionalSeconds: true))
            entry["sourcePath"] = "sources/\(id).metal"; entry["sourceSHA256"] = CatalogHash.sha256(bytes)
            entry["previewPath"] = "previews/\(id).png"; entry["previewSHA256"] = String(repeating: "0", count: 64)
            do {
                let decoded = try JSONDecoder().decode(CatalogManifest.Entry.self, from: JSONSerialization.data(withJSONObject: entry))
                let single = CatalogManifest(schemaVersion: 1, defaultShaderID: id, sourceRevision: String(repeating: "0", count: 64), shaders: [decoded])
                try single.validate()
            } catch { throw LocalCatalogError.invalidFile(metadataPath, error.localizedDescription) }
            entries.append(entry); sources[id] = text
            for (path, data) in [("sources/\(id).metal", bytes)] {
                paths.insert(path); try data.write(to: stage.appendingPathComponent(path), options: .atomic)
            }
        }
        var wire: [String: Any] = ["schemaVersion": 1, "defaultShaderID": defaultID, "shaders": entries]
        if let collections = index["collections"] { wire["collections"] = collections }
        wire["sourceRevision"] = String(repeating: "0", count: 64)
        let manifestData = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        guard manifestData.count <= 2_097_152 else { throw LocalCatalogError.invalidFile("index.json", "Catalog exceeds 2 MiB.") }
        var manifest: CatalogManifest
        do { manifest = try CatalogBuilder(manifest: JSONDecoder().decode(CatalogManifest.self, from: manifestData)).manifest }
        catch { throw LocalCatalogError.invalidFile("index.json", error.localizedDescription) }
        var warnings: [ShaderPreviewWarning] = [], cacheKeys: Set<String> = []
        for index in manifest.shaders.indices {
            try Task.checkCancellation()
            let entry = manifest.shaders[index]
            let generated = try await previews.preview(source: sources[entry.id]!, colors: entry.colors)
            cacheKeys.insert(generated.cacheKey)
            if let diagnostic = generated.diagnostic {
                warnings.append(ShaderPreviewWarning(shaderID: entry.id, message: diagnostic))
            }
            manifest.shaders[index].previewSHA256 = CatalogHash.sha256(generated.png)
            paths.insert(entry.previewPath)
            try generated.png.write(to: stage.appendingPathComponent(entry.previewPath), options: .atomic)
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = try JSONSerialization.jsonObject(with: encoder.encode(manifest)) as! [String: Any]
        canonical["sourceRevision"] = nil
        let revision = CatalogHash.sha256(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
        manifest.sourceRevision = revision
        let catalog = try CatalogSnapshot(manifest: manifest, sources: sources, publicationRevision: revision).validated()
        let publishedManifest = try encoder.encode(catalog.snapshot.manifest)
        try publishedManifest.write(to: stage.appendingPathComponent("catalog.json"), options: .atomic)
        let destination = directory.appendingPathComponent(revision)
        if fm.fileExists(atPath: destination.path) {
            if (try? publicationMatches(catalog, manifest: publishedManifest, at: destination)) != true {
                // Both paths are siblings. A failed swap leaves the existing publication intact;
                // a successful swap leaves its damaged contents at stage for deferred cleanup.
                try files.swap(stage, destination)
            }
        } else { try fm.moveItem(at: stage, to: destination) }
        try files.writeMarker(JSONEncoder().encode(CatalogHead(revision: revision)), directory.appendingPathComponent("current.json"))
        let previous = currentRevision
        allowed[revision] = paths; currentRevision = revision
        // Retain the previous publication as well as all connection-pinned publications.
        trim(previous: previous)
        await previews.prune(keeping: cacheKeys)
        return CatalogReloadResult(catalog: catalog, previewWarnings: warnings)
    }

    private func readPublicationFile(_ url: URL, limit: Int) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw CatalogError.oversizedResponse }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw CatalogError.oversizedResponse }
        return data
    }

    private func publicationMatches(_ catalog: ValidatedCatalog, manifest: Data, at publication: URL) throws -> Bool {
        guard try readPublicationFile(publication.appendingPathComponent("catalog.json"), limit: 2_097_152) == manifest else { return false }
        for entry in catalog.snapshot.manifest.shaders {
            let source = try readPublicationFile(publication.appendingPathComponent(entry.sourcePath), limit: 1_048_576)
            let preview = try readPublicationFile(publication.appendingPathComponent(entry.previewPath), limit: 8_388_608)
            guard CatalogHash.sha256(source) == entry.sourceSHA256,
                  CatalogHash.sha256(preview) == entry.previewSHA256 else { return false }
        }
        return true
    }

    public func get(_ request: CatalogRequest, limit: Int, pinFor connection: UUID? = nil) throws -> Data {
        let data: Data
        switch request {
        case .head:
            guard let currentRevision else { throw CatalogError.invalidResponse }
            if let connection { leases[connection] = currentRevision }
            data = try JSONEncoder().encode(CatalogHead(revision: currentRevision))
        case .asset(let revision, let path):
            guard allowed[revision]?.contains(path) == true else { throw CatalogError.invalidResponse }
            let url = directory.appendingPathComponent(revision).appendingPathComponent(path)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw CatalogError.oversizedResponse }
            data = try Data(contentsOf: url)
        }
        guard limit >= 0, data.count <= limit else { throw CatalogError.oversizedResponse }
        return data
    }

    private var previousRevision: String?
    private func trim(previous: String? = nil) {
        if let previous, previous != currentRevision { previousRevision = previous }
        let keep = Set(leases.values).union([currentRevision, previousRevision].compactMap { $0 })
        for revision in Array(allowed.keys) where !keep.contains(revision) {
            allowed[revision] = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(revision))
        }
        if let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries where CatalogHash.isSHA(entry.lastPathComponent) && !keep.contains(entry.lastPathComponent) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
#endif
