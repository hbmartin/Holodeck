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
    private var scanCount = 0
    func maintenanceCounts() async -> (scans: Int, active: Int) {
        (try? await run { (self.scanCount, self.activeStages.count) }) ?? (0, 0)
    }

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
        scanCount += 1
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where !activeStages.contains(stageKey(entry)) {
            let name = entry.lastPathComponent
            guard name.hasPrefix("stage-"), UUID(uuidString: String(name.dropFirst(6))) != nil,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            removeStage(entry)
        }
    }

    private func stageKey(_ url: URL) -> String {
        url.lastPathComponent
    }

    private func removeStage(_ stage: URL) {
        activeStages.remove(stageKey(stage))
        guard FileManager.default.fileExists(atPath: stage.path) else { return }
        do { try files.removeStage(stage) }
        catch { Diagnostics.catalog.error("Couldn’t remove abandoned publication stage: \(error.localizedDescription, privacy: .public)") }
    }

    func cleanup(_ stage: URL) async {
        _ = try? await run { self.removeStage(stage) }
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
                    try CatalogLimits.checkByteCount(size, limit: limit, path: path, kind: "File")
                    let bytes = try Data(contentsOf: url)
                    try CatalogLimits.checkByteCount(bytes.count, limit: limit, path: path, kind: "File")
                    return bytes
                } catch let error as LocalCatalogError { throw error }
                catch { throw LocalCatalogError.invalidFile(path, error.localizedDescription) }
            }
            func json(_ path: String) throws -> [String: Any] {
                do {
                    guard let value = try JSONSerialization.jsonObject(with: read(path, limit: CatalogLimits.manifestBytes)) as? [String: Any] else {
                        throw CatalogError.invalidManifest
                    }
                    return value
                } catch let error as LocalCatalogError { throw error }
                catch { throw LocalCatalogError.invalidFile(path, error.localizedDescription) }
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
                let bodyPath = folder + "body.metal"
                guard !bytes.isEmpty else {
                    throw LocalCatalogError.invalidFile(bodyPath, "Assembled source for \(id) is empty.")
                }
                try CatalogLimits.checkByteCount(bytes.count, limit: CatalogLimits.sourceBytes,
                                                 path: bodyPath, kind: "Assembled source for \(id)")
                try CatalogLimits.checkByteCount(total, limit: CatalogLimits.totalSourceBytes,
                                                 path: "index.json", kind: "Catalog source total after shader \(id)")
                guard let text = String(validating: bytes, as: UTF8.self) else {
                    throw LocalCatalogError.invalidFile(bodyPath, "Assembled source for \(id) is not valid UTF-8.")
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
            try CatalogLimits.checkByteCount(manifestData.count, limit: CatalogLimits.manifestBytes,
                                             path: "index.json", kind: "Catalog manifest")
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
            let encoded = try CatalogPublication.encodedManifest(preparation.manifest)
            let revision = CatalogHash.sha256(encoded)
            let builder = try CatalogPublication.builder(encoded, revision: revision, kind: .localPublication)
            let catalog = try CatalogPublication.finish(builder,
                sources: preparation.sources.mapValues { Data($0.utf8) }, revision: revision)
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
                _ = try self.verify(revision: candidate.catalog.publicationRevision, expected: candidate.manifest)
                return true
            } catch { return false }
        }
    }

    func marker() async throws -> CatalogHead? {
        try await run {
            let marker = self.directory.appendingPathComponent("current.json")
            guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
            let head = try JSONDecoder().decode(CatalogHead.self,
                from: CatalogPublicationFiles.read(marker, limit: CatalogLimits.headBytes))
            guard CatalogHash.isSHA(head.revision) else { throw CatalogError.invalidManifest }
            return head
        }
    }

    func restore(_ revision: String) async throws -> ValidatedCatalog {
        try await run {
            self.files.beforeVerification()
            return try self.verify(revision: revision)
        }
    }

    private func verify(revision: String, expected: Data? = nil) throws -> ValidatedCatalog {
        let publication = directory.appendingPathComponent(revision)
        let bytes = try CatalogPublicationFiles.read(publication.appendingPathComponent("catalog.json"), limit: CatalogLimits.manifestBytes)
        if let expected, expected != bytes { throw CatalogError.invalidManifest }
        var builder = try CatalogPublication.builder(bytes, revision: revision, kind: .localPublication)
        for entry in builder.manifest.shaders {
            try builder.addSource(CatalogPublicationFiles.read(publication.appendingPathComponent(entry.sourcePath),
                limit: CatalogLimits.sourceBytes), for: entry)
            _ = try CatalogPublicationFiles.verified(publication.appendingPathComponent(entry.previewPath),
                hash: entry.previewSHA256, limit: CatalogLimits.previewBytes, error: .invalidPreview)
        }
        return try builder.finish(revision: revision)
    }
}
#endif
