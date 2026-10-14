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
    var beforeVerification: @Sendable () -> Void = {}
    var removeStage: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
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
public struct PreparedCatalogPublication: Sendable {
    public let id: UUID
    public let catalog: ValidatedCatalog
    public let previewWarnings: [ShaderPreviewWarning]
}

public actor DirectoryCatalog {
    private struct Prepared { let candidate: DirectoryCandidate; let warnings: [ShaderPreviewWarning]; let cacheKeys: Set<String> }
    private var prepared: [UUID: Prepared] = [:]
    private let directory: URL
    private let files: DirectoryCatalogFileOperations
    private let previews: ShaderPreviewGenerator
    private let io: DirectoryCatalogIO
    private var verificationRevisions: Set<String> = []
    private var reloading = false
    private var reloadWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRevision: String?
    private var allowed: [String: Set<String>] = [:]
    private var leases: [UUID: String] = [:]

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Holodeck/LocalCatalog", isDirectory: true),
                previewGenerator: ShaderPreviewGenerator? = nil) {
        self.directory = directory; files = DirectoryCatalogFileOperations()
        io = DirectoryCatalogIO(directory: directory, files: files)
        previews = previewGenerator ?? ShaderPreviewGenerator(directory: directory.appendingPathComponent("preview-cache"))
    }

    init(directory: URL, files: DirectoryCatalogFileOperations, previewGenerator: ShaderPreviewGenerator? = nil) {
        self.directory = directory; self.files = files
        io = DirectoryCatalogIO(directory: directory, files: files)
        previews = previewGenerator ?? ShaderPreviewGenerator(directory: directory.appendingPathComponent("preview-cache"))
    }

    public nonisolated var source: CatalogSource {
        var source = CatalogSource { [self] request, limit in try await get(request, limit: limit) }
        source.isLocalPublication = true
        return source
    }

    public func publicationRevisionValue() -> String? { currentRevision }

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
            try CatalogPublicationFiles.read(publication.appendingPathComponent(path), limit: limit)
        }
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: read("catalog.json", limit: CatalogLimits.manifestBytes))
        var builder = try CatalogBuilder(manifest: manifest)
        try CatalogPublication.validate(builder.manifest, revision: head.revision)
        var paths: Set<String> = ["catalog.json"]
        for entry in manifest.shaders {
            try builder.addSource(read(entry.sourcePath, limit: CatalogLimits.sourceBytes), for: entry)
            _ = try CatalogPublicationFiles.verified(publication.appendingPathComponent(entry.previewPath),
                hash: entry.previewSHA256, limit: CatalogLimits.previewBytes, error: .invalidPreview)
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
        let candidate = try await prepare(from: root)
        return try await install(candidate.id)
    }

    func maintainStages() async { await io.maintenance() }

    public func prepare(from root: URL) async throws -> PreparedCatalogPublication {
        var preparation = try await io.prepare(from: root)
        var retainedRevision: String?
        do {
            var warnings: [ShaderPreviewWarning] = [], cacheKeys: Set<String> = []
            for index in preparation.manifest.shaders.indices {
                try Task.checkCancellation()
                let entry = preparation.manifest.shaders[index]
                let generated = try await previews.preview(source: preparation.sources[entry.id]!, colors: entry.colors)
                cacheKeys.insert(generated.cacheKey)
                if let diagnostic = generated.diagnostic {
                    warnings.append(ShaderPreviewWarning(shaderID: entry.id, message: diagnostic))
                }
                preparation.manifest.shaders[index].previewSHA256 = try await io.writePreview(generated.png, path: entry.previewPath, stage: preparation.stage)
                preparation.paths.insert(entry.previewPath)
            }
            try Task.checkCancellation()
            let candidate = try await io.finish(preparation)
            let revision = candidate.catalog.publicationRevision
            verificationRevisions.insert(revision); retainedRevision = revision
            let id = UUID()
            prepared[id] = Prepared(candidate: candidate, warnings: warnings, cacheKeys: cacheKeys)
            return PreparedCatalogPublication(id: id, catalog: candidate.catalog, previewWarnings: warnings)
        } catch {
            if let retainedRevision { verificationRevisions.remove(retainedRevision) }
            await io.cleanup(preparation.stage)
            throw error
        }
    }

    public func discard(_ id: UUID) async {
        guard let value = prepared.removeValue(forKey: id) else { return }
        releaseVerificationPin(value.candidate.catalog.publicationRevision)
        await io.cleanup(value.candidate.preparation.stage)
    }

    private func releaseVerificationPin(_ revision: String) {
        if !prepared.values.contains(where: { $0.candidate.catalog.publicationRevision == revision }) {
            verificationRevisions.remove(revision)
        }
    }

    public func install(_ id: UUID) async throws -> CatalogReloadResult {
        guard let value = prepared[id] else { throw CatalogError.invalidResponse }
        let candidate = value.candidate
        let preparation = candidate.preparation
        let revision = candidate.catalog.publicationRevision
        do {
            let matches = try await io.matches(candidate)
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(revision)
            if FileManager.default.fileExists(atPath: destination.path) {
                if !matches { try files.swap(preparation.stage, destination) }
            } else { try FileManager.default.moveItem(at: preparation.stage, to: destination) }
            try files.writeMarker(JSONEncoder().encode(CatalogHead(revision: revision)), directory.appendingPathComponent("current.json"))
            let previous = currentRevision
            allowed[revision] = preparation.paths; currentRevision = revision
            prepared[id] = nil; releaseVerificationPin(revision)
            trim(previous: previous)
            await io.cleanup(preparation.stage)
            await previews.prune(keeping: value.cacheKeys)
            return CatalogReloadResult(catalog: candidate.catalog, previewWarnings: value.warnings)
        } catch {
            await discard(id)
            throw error
        }
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
        let keep = Set(leases.values).union(verificationRevisions).union([currentRevision, previousRevision].compactMap { $0 })
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
