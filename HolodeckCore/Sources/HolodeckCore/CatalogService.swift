import Foundation
import Clocks
import Dependencies
import CoreGraphics
import ImageIO

nonisolated public struct CatalogNetwork: Sendable {
    public var get: @Sendable (URL, Int) async throws -> Data
    public init(get: @escaping @Sendable (URL, Int) async throws -> Data) { self.get = get }
    public static let live = session(configuration: .default)

    static func session(configuration: URLSessionConfiguration) -> Self {
        let downloader = CatalogDownloader(configuration: configuration)
        return Self { url, limit in try await downloader.get(url, limit: limit) }
    }
}

nonisolated public struct CatalogStorage: Sendable {
    public var read: @Sendable (String) throws -> Data?
    public var write: @Sendable (String, Data) throws -> Void

    public init(read: @escaping @Sendable (String) throws -> Data?,
                write: @escaping @Sendable (String, Data) throws -> Void) {
        self.read = read; self.write = write
    }
    public static func disk(at directory: URL) -> Self {
        Self(read: { name in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }, write: { name, data in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        })
    }

    public static let live = disk(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ShaderCatalog", isDirectory: true))
    public static let disabled = Self(read: { _ in nil }, write: { _, _ in })
}

nonisolated public enum CatalogRefreshOutcome: Sendable {
    case updated(ValidatedCatalog)
    case unchanged, throttled, disabled
}

nonisolated public enum PreviewSizing {
    /// Shared destination buckets keep layout requests and decoded cache keys in agreement.
    public static func bucketedTargetPixels(_ size: CGSize) throws -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CatalogError.invalidPreview
        }
        return CGSize(width: min(2048, ceil(size.width / 64) * 64),
                      height: min(2048, ceil(size.height / 64) * 64))
    }
}

/// Refresh downloads and persistence run off the UI executor. Failed refreshes never replace current.
public actor CatalogService {
    public nonisolated let initialCatalog: ValidatedCatalog?
    private var snapshot: ValidatedCatalog?
    private var loadedCache = false
    private let network: CatalogNetwork
    private let storage: CatalogStorage
    private let clock: AnyClock<Duration>
    private let enabled: Bool
    private var lastAttempt: AnyClock<Duration>.Instant?
    private var refreshTask: Task<Void, Never>?
    private var refreshWaiters: [UUID: CatalogRefreshWaiter] = [:]
    var refreshWaiterCount: Int { refreshWaiters.count }
    private let repository: String

    private var previewData = CatalogLRU<String, Data>(limit: 16_777_216)
    private var previewImages = CatalogLRU<PreviewImageKey, CGImage>(limit: 33_554_432)
    private var previewTasks: [String: Task<Data, Error>] = [:]
    private var imageTasks: [PreviewImageKey: Task<CGImage, Error>] = [:]

    private let decoder = PreviewDecoder()
    private var cacheEpoch: UInt64 = 0
    private var previewFailures = CatalogLRU<PreviewFailureKey, PreviewFailure>(limit: 500)
    var previewCacheCosts: (encoded: Int, decoded: Int) { (previewData.cost, previewImages.cost) }
    // A test hook runs on the same bounded worker queue as ImageIO.
    private var beforePreviewDecode: (@Sendable () -> Void)?

    func setBeforePreviewDecode(_ hook: (@Sendable () -> Void)?) { beforePreviewDecode = hook }
    var previewFailureCount: Int { previewFailures.cost }
    private(set) var previewRetryWaiterCount = 0

    public func trimPreviewCaches() {
        cacheEpoch &+= 1
        previewData.removeAll()
        previewImages.removeAll()
    }

    public init(initialCatalog: ValidatedCatalog? = nil, network: CatalogNetwork = .live, storage: CatalogStorage = .live,
         clock: any Clock<Duration> = ContinuousClock(), enabled: Bool = true,
         repository: String = "hbmartin/HolodeckShaders") {
        self.initialCatalog = initialCatalog
        snapshot = initialCatalog
        loadedCache = initialCatalog != nil
        self.network = network
        self.storage = storage
        self.clock = AnyClock(clock)
        self.enabled = enabled
        self.repository = repository
    }

    public nonisolated static func offline(initialCatalog: ValidatedCatalog? = nil, storage: CatalogStorage = .disabled) -> CatalogService {
        CatalogService(initialCatalog: initialCatalog, storage: storage, enabled: false)
    }

    public func current() -> ValidatedCatalog? {
        if !loadedCache {
            loadedCache = true
            if let data = try? storage.read("snapshot.json"),
               let value = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) {
                snapshot = try? value.validated()
            }
        }
        return snapshot
    }

    @discardableResult
    public func refresh(force: Bool = false) async throws -> ValidatedCatalog? {
        if case .updated(let catalog) = try await refreshOutcome(force: force) { return catalog }
        return nil
    }

    /// Separates successful checks from skips; only updated and unchanged performed a network check.
    @discardableResult
    public func refreshOutcome(force: Bool = false) async throws -> CatalogRefreshOutcome {
        try Task.checkCancellation()
        _ = current()
        guard enabled else { return .disabled }
        if refreshTask == nil {
            let instant = clock.now
            if !force, snapshot != nil, let lastAttempt, lastAttempt.duration(to: instant) < .seconds(900) { return .throttled }
            lastAttempt = instant
            // The service owns this flight, including persistence after its last viewer leaves.
            refreshTask = Task {
                let result: Result<CatalogRefreshOutcome, Error>
                do {
                    if let catalog = try await downloadPublication() { result = .success(.updated(catalog)) }
                    else { result = .success(.unchanged) }
                }
                catch {
                    Diagnostics.catalog.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
                    result = .failure(error)
                }
                finishRefresh(result)
            }
        }
        let id = UUID()
        let waiter = CatalogRefreshWaiter()
        refreshWaiters[id] = waiter
        let value = try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
            Task { await self.removeRefreshWaiter(id) }
        }
        try Task.checkCancellation()
        return value
    }

    private func removeRefreshWaiter(_ id: UUID) { refreshWaiters[id] = nil }

    private func finishRefresh(_ result: Result<CatalogRefreshOutcome, Error>) {
        refreshTask = nil
        let waiters = Array(refreshWaiters.values)
        refreshWaiters.removeAll()
        waiters.forEach { $0.resolve(result) }
    }

    private func downloadPublication() async throws -> ValidatedCatalog? {
        struct Commit: Decodable { let sha: String }
        let commitURL = URL(string: "https://api.github.com/repos/\(repository)/git/ref/heads/published")!
        struct Reference: Decodable { let object: Commit }
        let reference = try JSONDecoder().decode(Reference.self, from: await network.get(commitURL, 65_536))
        let revision = reference.object.sha
        guard CatalogHash.isSHA(revision, length: 40) else { throw CatalogError.invalidManifest }
        if revision == snapshot?.publicationRevision { return nil }
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: await network.get(assetURL("catalog.json", revision: revision), 2_097_152))
        var builder = try CatalogBuilder(manifest: manifest)
        // Bounded sequential downloads keep memory and GitHub request concurrency predictable.
        for entry in manifest.shaders {
            let data = try await network.get(assetURL(entry.sourcePath, revision: revision), 1_048_576)
            try builder.addSource(data, for: entry)
        }
        let candidate = try builder.finish(revision: revision)
        try storage.write("snapshot.json", JSONEncoder().encode(candidate.snapshot))
        snapshot = candidate
        return candidate
    }

    public func preview(_ preview: ShaderPreview) async throws -> Data {
        try await self.preview(preview, epoch: cacheEpoch)
    }

    private func preview(_ preview: ShaderPreview, epoch: UInt64) async throws -> Data {
        try Task.checkCancellation()
        try validatePreview(preview)
        if let cached = previewData.value(for: preview.hash) { return cached }
        try checkPreviewFailure(preview)
        let task: Task<Data, Error>
        if let existing = previewTasks[preview.hash] { task = existing }
        else {
            task = Task {
                defer { previewTasks[preview.hash] = nil }
                do {
                    let data = try await downloadPreview(preview)
                    previewFailures.removeValue(for: PreviewFailureKey(preview))
                    if epoch == cacheEpoch { previewData.insert(data, for: preview.hash, cost: data.count) }
                    return data
                } catch {
                    recordPreviewFailure(error, preview: preview)
                    throw error
                }
            }
            previewTasks[preview.hash] = task
        }
        let data = try await task.value
        try Task.checkCancellation()
        return data
    }

    private func checkPreviewFailure(_ preview: ShaderPreview) throws {
        if let failure = previewFailures.value(for: PreviewFailureKey(preview)),
           failure.retryAt == nil || clock.now < failure.retryAt! { throw failure.error }
    }

    /// Returns when a retry is eligible, or false for a permanent failure. This does not fetch an image.
    public func waitForPreviewRetry(_ preview: ShaderPreview) async throws -> Bool {
        try Task.checkCancellation()
        try validatePreview(preview)
        while let failure = previewFailures.value(for: PreviewFailureKey(preview)) {
            guard let retryAt = failure.retryAt else { return false }
            if clock.now >= retryAt { return true }
            do {
                previewRetryWaiterCount += 1
                defer { previewRetryWaiterCount -= 1 }
                try await clock.sleep(until: retryAt)
            }
            try Task.checkCancellation()
        }
        return true
    }

    private func recordPreviewFailure(_ error: Error, preview: ShaderPreview) {
        guard !CatalogError.isCancellation(error) else { return }
        let key = PreviewFailureKey(preview)
        let attempts = min((previewFailures.value(for: key)?.attempts ?? 0) + 1, 5)
        let permanent: Bool
        if case CatalogError.invalidPreview = error { permanent = true } else { permanent = false }
        let retryAt = permanent ? nil : clock.now.advanced(by: .seconds(min(30 * (1 << (attempts - 1)), 300)))
        previewFailures.insert(PreviewFailure(error: error, attempts: attempts, retryAt: retryAt), for: key, cost: 1)
    }

    private func validatePreview(_ preview: ShaderPreview) throws {
        guard CatalogHash.isSHA(preview.hash), CatalogHash.isSHA(preview.publicationRevision, length: 40),
              preview.path.range(of: "^previews/[a-z0-9]+(-[a-z0-9]+)*\\.png$", options: .regularExpression) != nil
        else { throw CatalogError.invalidPreview }
    }

    private func downloadPreview(_ preview: ShaderPreview) async throws -> Data {
        let filename = "preview-\(preview.hash).png"
        if let cached = try? storage.read(filename), validPreview(cached, hash: preview.hash) { return cached }
        guard enabled else { throw CatalogError.invalidPreview }
        let data = try await network.get(assetURL(preview.path, revision: preview.publicationRevision), 8_388_608)
        guard validPreview(data, hash: preview.hash) else { throw CatalogError.invalidPreview }
        // An image-cache write failure should not prevent the fetched image from displaying.
        try? storage.write(filename, data)
        return data
    }

    public func previewImage(_ preview: ShaderPreview, maxPixelSize: Int) async throws -> CGImage {
        guard (1...2048).contains(maxPixelSize) else { throw CatalogError.invalidPreview }
        return try await previewImage(preview, request: .maximum(maxPixelSize))
    }

    /// Target dimensions are pixels, including any display scale and focus enlargement.
    public func previewImage(_ preview: ShaderPreview, targetPixelSize: CGSize) async throws -> CGImage {
        // Bucket destinations as well as decoded sizes to avoid a cache entry per layout fluctuation.
        let pixels = try PreviewSizing.bucketedTargetPixels(targetPixelSize)
        return try await previewImage(preview, request: .fill(Int(pixels.width), Int(pixels.height)))
    }

    private func previewImage(_ preview: ShaderPreview, request: PreviewSize) async throws -> CGImage {
        try Task.checkCancellation()
        try validatePreview(preview)
        let key = PreviewImageKey(hash: preview.hash, size: request)
        if let image = previewImages.value(for: key) { return image }
        try checkPreviewFailure(preview)
        let task: Task<CGImage, Error>
        if let existing = imageTasks[key] { task = existing }
        else {
            let epoch = cacheEpoch
            let hook = beforePreviewDecode
            task = Task {
                defer { imageTasks[key] = nil }
                let data = try await self.preview(preview, epoch: epoch)
                do {
                    let image = try await decoder.decode(data, size: request, beforeDecode: hook)
                    previewFailures.removeValue(for: PreviewFailureKey(preview))
                    if epoch == cacheEpoch { previewImages.insert(image, for: key, cost: image.bytesPerRow * image.height) }
                    return image
                } catch {
                    recordPreviewFailure(error, preview: preview)
                    throw error
                }
            }
            imageTasks[key] = task
        }
        let image = try await task.value
        try Task.checkCancellation()
        return image
    }

    private func validPreview(_ data: Data, hash: String) -> Bool {
        data.count <= 8_388_608 && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && CatalogHash.sha256(data) == hash
    }

    private func assetURL(_ path: String, revision: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(revision)/\(path)")!
    }
}

/// Completion and cancellation may race, including before continuation registration.
nonisolated private final class CatalogRefreshWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CatalogRefreshOutcome, Error>?
    private var continuation: CheckedContinuation<CatalogRefreshOutcome, Error>?

    func value() async throws -> CatalogRefreshOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<CatalogRefreshOutcome, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func resolve(_ result: Result<CatalogRefreshOutcome, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else { return Optional<CheckedContinuation<CatalogRefreshOutcome, Error>>.none }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

extension DependencyValues {
    public var catalogService: CatalogService {
        get { self[CatalogServiceKey.self] }
        set { self[CatalogServiceKey.self] = newValue }
    }
}

nonisolated public enum CatalogServiceKey: DependencyKey {
    public static let liveValue = CatalogService()
    public static let testValue = CatalogService.offline()
    public static let previewValue = CatalogService.offline()
}

nonisolated private struct PreviewImageKey: Hashable {
    let hash: String
    let size: PreviewSize
}

nonisolated private struct PreviewFailureKey: Hashable {
    let revision: String
    let path: String
    let hash: String
    init(_ preview: ShaderPreview) { revision = preview.publicationRevision; path = preview.path; hash = preview.hash }
}

nonisolated private struct PreviewFailure {
    let error: Error
    let attempts: Int
    let retryAt: AnyClock<Duration>.Instant?
}

nonisolated private enum PreviewSize: Hashable, Sendable {
    case maximum(Int)
    case fill(Int, Int)
}

/// Blocking ImageIO work never occupies the catalog actor; only two decodes run at once.
nonisolated private final class PreviewDecoder: Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Holodeck.preview-decoder"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func decode(_ data: Data, size: PreviewSize, beforeDecode: (@Sendable () -> Void)?) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                beforeDecode?()
                do { continuation.resume(returning: try Self.image(data, size: size)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func image(_ data: Data, size: PreviewSize) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CatalogError.invalidPreview }
        let maximum: Int
        switch size {
        case .maximum(let value): maximum = value
        case .fill(let targetWidth, let targetHeight):
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0 else { throw CatalogError.invalidPreview }
            let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
            let w = rotated ? height.doubleValue : width.doubleValue
            let h = rotated ? width.doubleValue : height.doubleValue
            let required = max(w, h) * max(Double(targetWidth) / w, Double(targetHeight) / h)
            maximum = Int(min(2048, ceil(required / 64) * 64))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ] as CFDictionary) else { throw CatalogError.invalidPreview }
        return image
    }
}
