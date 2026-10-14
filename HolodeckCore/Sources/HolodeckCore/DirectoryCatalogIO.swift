#if os(macOS)
import Foundation

nonisolated struct DirectoryPreparation: Sendable {
    let stage: URL
    var manifest: CatalogManifest
    let sources: [String: String]
    var paths: Set<String>
}

nonisolated struct DirectoryCandidate: Sendable {
    let preparation: DirectoryPreparation
    let catalog: ValidatedCatalog
    let manifest: Data
}

/// All staging and full-publication verification use one bounded I/O queue.
nonisolated final class DirectoryCatalogIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Holodeck.directory-catalog-io", qos: .userInitiated)
    private let directory: URL
    private let files: DirectoryCatalogFileOperations
    // Accessed only on queue, including cleanup after an async preview-generation pause.
    private var activeStages: Set<String> = []

    init(directory: URL, files: DirectoryCatalogFileOperations) {
        self.directory = directory; self.files = files
        queue.async { self.cleanupOrphans() }
    }

    private func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try autoreleasepool(invoking: work)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func maintenance() async {
        _ = try? await run { self.cleanupOrphans() }
    }

    private func cleanupOrphans() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where !activeStages.contains(stageKey(entry)) {
            let name = entry.lastPathComponent
            guard name.hasPrefix("stage-"), UUID(uuidString: String(name.dropFirst(6))) != nil,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            removeStage(entry)
        }
    }

    private func stageKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func removeStage(_ stage: URL) {
        activeStages.remove(stageKey(stage))
        guard FileManager.default.fileExists(atPath: stage.path) else { return }
        do { try files.removeStage(stage) }
        catch { Diagnostics.catalog.error("Couldn’t remove abandoned publication stage: \(error.localizedDescription, privacy: .public)") }
    }

    func cleanup(_ stage: URL) async {
        _ = try? await run { self.removeStage(stage); self.cleanupOrphans() }
    }

    func prepare(from root: URL) async throws -> DirectoryPreparation {
        try await run { try self.prepareFiles(from: root) }
    }

    private func prepareFiles(from root: URL) throws -> DirectoryPreparation {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupOrphans()
        let stage = directory.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        activeStages.insert(stageKey(stage))
        do {
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
                    guard let value = try JSONSerialization.jsonObject(with: read(path, limit: CatalogLimits.manifestBytes)) as? [String: Any] else {
                        throw CatalogError.invalidManifest
                    }
                    return value
                } catch { throw LocalCatalogError.invalidFile(path, error.localizedDescription) }
            }
            let index = try json("index.json")
            guard let ids = index["shaders"] as? [String], (1...CatalogLimits.shaderCount).contains(ids.count),
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
                for path in sourcePaths { bytes.append(try read(path, limit: CatalogLimits.sourceBytes)) }
                total += bytes.count
                guard !bytes.isEmpty, bytes.count <= CatalogLimits.sourceBytes, total <= CatalogLimits.totalSourceBytes,
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
            guard manifestData.count <= CatalogLimits.manifestBytes else { throw LocalCatalogError.invalidFile("index.json", "Catalog exceeds 2 MiB.") }
            let manifest: CatalogManifest
            do { manifest = try CatalogBuilder(manifest: JSONDecoder().decode(CatalogManifest.self, from: manifestData)).manifest }
            catch { throw LocalCatalogError.invalidFile("index.json", error.localizedDescription) }
            return DirectoryPreparation(stage: stage, manifest: manifest, sources: sources, paths: paths)
        } catch {
            removeStage(stage)
            throw error
        }
    }

    func writePreview(_ png: Data, path: String, stage: URL) async throws -> String {
        try await run {
            guard png.count <= CatalogLimits.previewBytes else { throw CatalogError.oversizedResponse }
            try png.write(to: stage.appendingPathComponent(path), options: .atomic)
            return CatalogHash.sha256(png)
        }
    }

    func finish(_ preparation: DirectoryPreparation) async throws -> DirectoryCandidate {
        try await run {
            var manifest = preparation.manifest
            let revision = try CatalogPublication.revision(for: manifest)
            manifest.sourceRevision = revision
            let catalog = try CatalogSnapshot(manifest: manifest, sources: preparation.sources, publicationRevision: revision).validated()
            let encoded = try CatalogPublication.encodedManifest(catalog.snapshot.manifest)
            try encoded.write(to: preparation.stage.appendingPathComponent("catalog.json"), options: .atomic)
            return DirectoryCandidate(preparation: preparation, catalog: catalog, manifest: encoded)
        }
    }

    func matches(_ candidate: DirectoryCandidate) async throws -> Bool {
        try await run {
            self.files.beforeVerification()
            let publication = self.directory.appendingPathComponent(candidate.catalog.publicationRevision)
            guard FileManager.default.fileExists(atPath: publication.path) else { return false }
            do {
                guard try CatalogPublicationFiles.read(publication.appendingPathComponent("catalog.json"),
                    limit: CatalogLimits.manifestBytes) == candidate.manifest else { return false }
                for entry in candidate.catalog.snapshot.manifest.shaders {
                    _ = try CatalogPublicationFiles.verified(publication.appendingPathComponent(entry.sourcePath),
                        hash: entry.sourceSHA256, limit: CatalogLimits.sourceBytes, error: .invalidSource)
                    _ = try CatalogPublicationFiles.verified(publication.appendingPathComponent(entry.previewPath),
                        hash: entry.previewSHA256, limit: CatalogLimits.previewBytes, error: .invalidPreview)
                }
                return true
            } catch { return false }
        }
    }
}
#endif
