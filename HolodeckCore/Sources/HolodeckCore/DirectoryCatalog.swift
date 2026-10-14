#if os(macOS)
import Foundation
import ImageIO

/// App-owned immutable publications. Requests never read the authoring directory.
public actor DirectoryCatalog {
    private let directory: URL
    private var currentRevision: String?
    private var allowed: [String: Set<String>] = [:]
    private var leases: [UUID: String] = [:]

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Holodeck/LocalCatalog", isDirectory: true)) { self.directory = directory }

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
            let url = publication.appendingPathComponent(path)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw CatalogError.oversizedResponse }
            let data = try Data(contentsOf: url)
            guard data.count <= limit else { throw CatalogError.oversizedResponse }
            return data
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
    public func reload(from root: URL) throws -> ValidatedCatalog {
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
            let previewPath = folder + "preview.png", png = try read(previewPath, limit: 8_388_608)
            guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let image = CGImageSourceCreateWithData(png as CFData, nil),
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
                throw LocalCatalogError.invalidFile(previewPath, "Expected a valid PNG preview.")
            }
            let dependencies = sourcePaths + [metadataPath]
            let date = try dependencies.map { path in
                try root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            }.max() ?? .distantPast
            var entry = metadata.filter { ["id", "name", "category", "description", "colors", "discovery"].contains($0.key) }
            entry["updatedAt"] = date.ISO8601Format(.init(includingFractionalSeconds: true))
            entry["sourcePath"] = "sources/\(id).metal"; entry["sourceSHA256"] = CatalogHash.sha256(bytes)
            entry["previewPath"] = "previews/\(id).png"; entry["previewSHA256"] = CatalogHash.sha256(png)
            do {
                let decoded = try JSONDecoder().decode(CatalogManifest.Entry.self, from: JSONSerialization.data(withJSONObject: entry))
                let single = CatalogManifest(schemaVersion: 1, defaultShaderID: id, sourceRevision: String(repeating: "0", count: 64), shaders: [decoded])
                try single.validate()
            } catch { throw LocalCatalogError.invalidFile(metadataPath, error.localizedDescription) }
            entries.append(entry); sources[id] = text
            for (path, data) in [("sources/\(id).metal", bytes), ("previews/\(id).png", png)] {
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
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = try JSONSerialization.jsonObject(with: encoder.encode(manifest)) as! [String: Any]
        canonical["sourceRevision"] = nil
        let revision = CatalogHash.sha256(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
        manifest.sourceRevision = revision
        let catalog = try CatalogSnapshot(manifest: manifest, sources: sources, publicationRevision: revision).validated()
        try encoder.encode(catalog.snapshot.manifest).write(to: stage.appendingPathComponent("catalog.json"), options: .atomic)
        let destination = directory.appendingPathComponent(revision)
        if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: stage, to: destination) }
        try JSONEncoder().encode(CatalogHead(revision: revision)).write(to: directory.appendingPathComponent("current.json"), options: .atomic)
        let previous = currentRevision
        allowed[revision] = paths; currentRevision = revision
        // Retain the previous publication as well as all connection-pinned publications.
        trim(previous: previous)
        return catalog
    }

    public func get(_ request: CatalogRequest, limit: Int, pinFor connection: UUID? = nil) throws -> Data {
        let data: Data
        switch request {
        case .head:
            guard let currentRevision else { throw LocalCatalogError.disconnected }
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
