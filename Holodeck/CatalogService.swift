import Foundation
import Dependencies

nonisolated struct CatalogNetwork: Sendable {
    var get: @Sendable (URL, Int) async throws -> Data
    static let live = Self { url, limit in
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(url.path.contains("/contents/") ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Holodeck", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CatalogError.invalidResponse }
        if response.expectedContentLength > Int64(limit) { throw CatalogError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw CatalogError.oversizedResponse }
            data.append(byte)
        }
        return data
    }
}

nonisolated struct CatalogStorage: Sendable {
    var read: @Sendable (String) throws -> Data?
    var write: @Sendable (String, Data) throws -> Void

    static func disk(at directory: URL) -> Self {
        Self(read: { name in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }, write: { name, data in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        })
    }

    static let live = disk(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShaderCatalog", isDirectory: true))
    static let disabled = Self(read: { _ in nil }, write: { _, _ in })
}

/// Refresh downloads and persistence run off the UI executor. Failed refreshes never replace current.
actor CatalogService {
    nonisolated let initialSnapshot: CatalogSnapshot?
    private var snapshot: CatalogSnapshot?
    private let network: CatalogNetwork
    private let storage: CatalogStorage
    private let now: @Sendable () -> Date
    private let enabled: Bool
    private var lastAttempt: Date?
    private var refreshing = false
    private let repository: String

    init(network: CatalogNetwork = .live, storage: CatalogStorage = .live,
         now: @escaping @Sendable () -> Date = { Date() }, enabled: Bool = true,
         repository: String = "hbmartin/HolodeckShaders") {
        let cached: CatalogSnapshot? = {
            guard let data = try? storage.read("snapshot.json"),
                  let value = try? JSONDecoder().decode(CatalogSnapshot.self, from: data),
                  (try? value.validate()) != nil else { return nil }
            return value
        }()
        initialSnapshot = cached
        snapshot = initialSnapshot
        self.network = network
        self.storage = storage
        self.now = now
        self.enabled = enabled
        self.repository = repository
    }

    func current() -> CatalogSnapshot? { snapshot }

    @discardableResult
    func refresh() async throws -> CatalogSnapshot? {
        guard enabled, !refreshing else { return nil }
        let date = now()
        if snapshot != nil, let lastAttempt, date.timeIntervalSince(lastAttempt) < 900 { return nil }
        lastAttempt = date
        refreshing = true
        defer { refreshing = false }
        struct Commit: Decodable { let sha: String }
        let commitURL = URL(string: "https://api.github.com/repos/\(repository)/git/ref/heads/published")!
        struct Reference: Decodable { let object: Commit }
        let reference = try JSONDecoder().decode(Reference.self, from: await network.get(commitURL, 65_536))
        let revision = reference.object.sha
        guard CatalogHash.isSHA(revision, length: 40) else { throw CatalogError.invalidManifest }
        if revision == snapshot?.publicationRevision { return nil }
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: await network.get(assetURL("catalog.json", revision: revision), 2_097_152))
        try manifest.validate()
        var sources: [String: String] = [:]
        var sourceBytes = 0
        // Bounded sequential downloads keep memory and GitHub request concurrency predictable.
        for entry in manifest.shaders {
            let data = try await network.get(assetURL(entry.sourcePath, revision: revision), 1_048_576)
            guard CatalogHash.sha256(data) == entry.sourceSHA256,
                  let source = String(data: data, encoding: .utf8) else { throw CatalogError.invalidSource }
            sourceBytes += data.count
            guard sourceBytes <= 16_777_216 else { throw CatalogError.oversizedResponse }
            sources[entry.id] = source
        }
        let candidate = CatalogSnapshot(manifest: manifest, sources: sources, publicationRevision: revision)
        try candidate.validate()
        try Task.checkCancellation()
        try storage.write("snapshot.json", JSONEncoder().encode(candidate))
        snapshot = candidate
        return candidate
    }

    func preview(_ preview: ShaderPreview) async throws -> Data {
        guard CatalogHash.isSHA(preview.hash), CatalogHash.isSHA(preview.publicationRevision, length: 40),
              preview.path.range(of: "^previews/[a-z0-9]+(-[a-z0-9]+)*\\.png$", options: .regularExpression) != nil
        else { throw CatalogError.invalidPreview }
        let filename = "preview-\(preview.hash).png"
        if let cached = try? storage.read(filename), validPreview(cached, hash: preview.hash) { return cached }
        guard enabled else { throw CatalogError.invalidPreview }
        let data = try await network.get(assetURL(preview.path, revision: preview.publicationRevision), 8_388_608)
        guard validPreview(data, hash: preview.hash) else { throw CatalogError.invalidPreview }
        // An image-cache write failure should not prevent the fetched image from displaying.
        try? storage.write(filename, data)
        return data
    }

    private func validPreview(_ data: Data, hash: String) -> Bool {
        data.count <= 8_388_608 && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && CatalogHash.sha256(data) == hash
    }

    private func assetURL(_ path: String, revision: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/contents/\(path)?ref=\(revision)")!
    }
}

extension DependencyValues {
    var catalogService: CatalogService {
        get { self[CatalogServiceKey.self] }
        set { self[CatalogServiceKey.self] = newValue }
    }
}

nonisolated enum CatalogServiceKey: DependencyKey {
    static let liveValue = CatalogService()
    static let testValue = CatalogService(storage: .disabled, enabled: false)
    static let previewValue = CatalogService(storage: .disabled, enabled: false)
}
