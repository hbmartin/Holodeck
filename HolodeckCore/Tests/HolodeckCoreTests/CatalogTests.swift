import XCTest
import Metal
import Dependencies
@testable import HolodeckCore

@MainActor
final class CatalogTests: XCTestCase {
    func candidate(ninth: Bool = false) -> CatalogSnapshot {
        var snapshot = TestCatalog.snapshot
        snapshot.publicationRevision = String(repeating: "a", count: 40)
        if ninth {
            var entry = snapshot.manifest.shaders[0]
            entry.id = "ninth-shader"
            entry.name = "Ninth Shader"
            entry.sourcePath = "sources/ninth-shader.metal"
            entry.previewPath = "previews/ninth-shader.png"
            snapshot.manifest.shaders.append(entry)
            snapshot.sources[entry.id] = snapshot.sources["plasma"]
        }
        return snapshot
    }

    func makeService(_ candidate: CatalogSnapshot, box: CatalogTestBox = CatalogTestBox(), cached: Bool = true) throws -> CatalogService {
        var responses: [String: Data] = [
            "/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(candidate.publicationRevision)\"}}".utf8),
            "/catalog.json": try JSONEncoder().encode(candidate.manifest)
        ]
        for entry in candidate.manifest.shaders {
            responses["/\(entry.sourcePath)"] = candidate.sources[entry.id].map { Data($0.utf8) }
        }
        box.setResponses(responses)
        let storage = CatalogStorage(read: { name in
            if let value = try box.storage.read(name) { return value }
            return cached && name == "snapshot.json" ? TestCatalog.data : nil
        }, write: box.storage.write)
        return CatalogService(network: box.network, storage: storage, clock: box.clock)
    }

    func testFirstLaunchHasNoCatalogAndCanRetryImmediatelyAfterNetworkFailure() async throws {
        let box = CatalogTestBox()
        let expected = candidate()
        let service = try makeService(expected, box: box, cached: false)
        XCTAssertNil(service.initialCatalog)
        let responses = box.responseFiles
        box.setResponses([:])
        do { _ = try await service.refresh(); XCTFail("Offline first launch must fail") } catch {}
        let empty = await service.current()
        XCTAssertNil(empty)
        XCTAssertNil(box.files["snapshot.json"])
        box.setResponses(responses)
        let downloaded = try await service.refresh()
        XCTAssertEqual(downloaded?.shaders.count, 8)
        XCTAssertEqual(downloaded?.publicationRevision, expected.publicationRevision)
        XCTAssertNotNil(box.files["snapshot.json"])
    }
    func testCachedCatalogAndEveryPreviewValidateOffline() async throws {
        let snapshot = TestCatalog.snapshot
        try snapshot.validate()
        let service = CatalogService(storage: TestCatalog.storage, enabled: false)
        let cached = await service.current()
        XCTAssertEqual(cached?.shaders.count, 8)
        let refreshed = try await service.refresh()
        XCTAssertNil(refreshed)
        for shader in try snapshot.validated().shaders {
            let preview = try XCTUnwrap(shader.preview)
            let data = try await service.preview(preview)
            XCTAssertEqual(CatalogHash.sha256(data), preview.hash)
        }
    }
    func testMalformedManifestAndIncompleteSourcesAreRejected() throws {
        var mutations: [CatalogSnapshot] = []
        var value = candidate(); value.manifest.schemaVersion = 2; mutations.append(value)
        value = candidate(); value.manifest.defaultShaderID = "missing"; mutations.append(value)
        value = candidate(); value.manifest.shaders.append(value.manifest.shaders[0]); mutations.append(value)
        value = candidate(); value.manifest.shaders[0].colors = [[0, 1]]; mutations.append(value)
        value = candidate(); value.manifest.shaders[0].updatedAt = "yesterday"; mutations.append(value)
        value = candidate(); value.manifest.shaders[0].sourcePath = "../secret"; mutations.append(value)
        value = candidate(); value.manifest.shaders[0].previewPath = "https://example.com/image.png"; mutations.append(value)
        value = candidate(); value.sources["plasma"] = "corrupt"; mutations.append(value)
        value = candidate(); value.sources.removeValue(forKey: "aurora"); mutations.append(value)
        for invalid in mutations { XCTAssertThrowsError(try invalid.validate()) }
    }
    func testNinthShaderPublishesAtomicallyAndUsesPinnedRevision() async throws {
        let expected = candidate(ninth: true)
        let box = CatalogTestBox()
        let service = try makeService(expected, box: box)
        let updated = try await service.refresh()
        XCTAssertEqual(updated?.shaders.count, 9)
        let current = await service.current()
        XCTAssertEqual(current?.publicationRevision, expected.publicationRevision)
        let data = try XCTUnwrap(box.files["snapshot.json"])
        let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
        try persisted.validate()
        XCTAssertEqual(try persisted.validated().shaders.last?.id, "ninth-shader")
        let urls = box.urls
        XCTAssertEqual(urls.count, 11)
        XCTAssertTrue(urls.dropFirst().allSatisfy { $0.host == "raw.githubusercontent.com" && $0.path.contains("/" + expected.publicationRevision + "/") })
    }
    func testInvalidSourceAndInterruptedWriteRetainPreviousSnapshot() async throws {
        for writeFails in [false, true] {
            var expected = candidate()
            if !writeFails { expected.sources["aurora"] = "corrupt download" }
            let box = CatalogTestBox()
            if writeFails {
                try box.storage.write("snapshot.json", JSONEncoder().encode(TestCatalog.snapshot))
            }
            let previousFile = box.files["snapshot.json"]
            box.failWrites = writeFails
            let service = try makeService(expected, box: box)
            do { _ = try await service.refresh(); XCTFail("Invalid publication must fail") } catch {}
            let current = await service.current()
            XCTAssertEqual(current?.publicationRevision, TestCatalog.snapshot.publicationRevision)
            XCTAssertEqual(box.files["snapshot.json"], previousFile)
        }
    }
    func testMissingSourceAndNetworkFailureKeepOfflineCatalog() async throws {
        var expected = candidate(); expected.sources.removeValue(forKey: "waves")
        let box = CatalogTestBox()
        let service = try makeService(expected, box: box)
        do { _ = try await service.refresh(); XCTFail("Missing source must fail") } catch {}
        let current = await service.current()
        XCTAssertEqual(current?.shaders.count, 8)
        XCTAssertNil(box.files["snapshot.json"])
        let offline = CatalogService(network: box.network, storage: TestCatalog.storage)
        box.setResponses([:])
        do { _ = try await offline.refresh(); XCTFail("Offline refresh must fail") } catch {}
        let fallback = await offline.current()
        XCTAssertEqual(fallback?.initialShader.id, "plasma")
    }
    func testStartupUsesValidCacheAndRejectsCorruptCache() async throws {
        let cached = candidate(ninth: true)
        let box = CatalogTestBox()
        try box.storage.write("snapshot.json", JSONEncoder().encode(cached))
        let service = CatalogService(storage: box.storage, enabled: false)
        let current = await service.current()
        XCTAssertEqual(current?.shaders.count, 9)
        try box.storage.write("snapshot.json", Data("interrupted JSON".utf8))
        let fallback = CatalogService(storage: box.storage, enabled: false)
        let missing = await fallback.current()
        XCTAssertNil(missing)
    }
    func testRefreshThrottlesAndUnchangedPublicationSkipsAssets() async throws {
        let box = CatalogTestBox()
        let service = try makeService(TestCatalog.snapshot, box: box)
        let unchanged = try await service.refresh()
        XCTAssertNil(unchanged)
        XCTAssertEqual(box.urls.count, 1)
        let throttled = try await service.refresh()
        XCTAssertNil(throttled)
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(899))
        _ = try await service.refresh()
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(1))
        _ = try await service.refresh()
        XCTAssertEqual(box.urls.count, 2)
    }
    func testConcurrentRefreshDoesNotStartDuplicateDownloads() async throws {
        let gate = PreviewRequestGate()
        let service = CatalogService(
                                     network: CatalogNetwork { url, _ in await gate.image(url.lastPathComponent) },
                                     storage: TestCatalog.storage)
        let first = Task { try await service.refresh() }
        await gate.waitForRequest("published")
        let concurrent = Task { try await service.refresh() }
        let reference = Data("{\"object\":{\"sha\":\"\(TestCatalog.snapshot.publicationRevision)\"}}".utf8)
        await gate.complete("published", data: reference)
        let result = try await first.value
        let secondResult = try await concurrent.value
        XCTAssertNil(result)
        XCTAssertNil(secondResult)
    }
    func testForcedRefreshBypassesThrottle() async throws {
        let box = CatalogTestBox()
        let service = try makeService(TestCatalog.snapshot, box: box)
        _ = try await service.refresh()
        _ = try await service.refresh()
        XCTAssertEqual(box.urls.count, 1)
        _ = try await service.refresh(force: true)
        XCTAssertEqual(box.urls.count, 2)
    }

    func testConcurrentRefreshCallersReceiveSamePublication() async throws {
        let expected = candidate()
        let gate = PreviewRequestGate()
        let box = CatalogTestBox()
        _ = try makeService(expected, box: box)
        let network = box.network
        let service = CatalogService(network: CatalogNetwork { url, limit in
            if url.lastPathComponent == "published" { return await gate.image("published") }
            return try await network.get(url, limit)
        }, storage: TestCatalog.storage)
        let first = Task { try await service.refresh() }
        await gate.waitForRequest("published")
        let second = Task { try await service.refresh(force: true) }
        // Let the second caller enter the actor before completing the reference request.
        await Task.yield()
        await gate.complete("published", data: Data("{\"object\":{\"sha\":\"\(expected.publicationRevision)\"}}".utf8))
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult?.publicationRevision, expected.publicationRevision)
        XCTAssertEqual(secondResult?.publicationRevision, expected.publicationRevision)
        XCTAssertEqual(box.urls.count, 9)
    }

    func testFailedRefreshIsAlsoThrottled() async throws {
        let box = CatalogTestBox()
        let service = try makeService(candidate(), box: box)
        box.setResponses([:])
        do { _ = try await service.refresh(); XCTFail("Expected failure") } catch {}
        let retry = try await service.refresh()
        XCTAssertNil(retry)
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(899))
        let stillThrottled = try await service.refresh()
        XCTAssertNil(stillThrottled)
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(1))
        do { _ = try await service.refresh(); XCTFail("Eligible failed attempts must check again") } catch {}
        XCTAssertEqual(box.urls.count, 2)
    }
    func testPreviewHashFailureCacheReuseAndUnavailableImage() async throws {
        let box = CatalogTestBox()
        let image = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array("test-image".utf8))
        let preview = ShaderPreview(path: "previews/test.png", hash: CatalogHash.sha256(image), publicationRevision: candidate().publicationRevision)
        let service = CatalogService(network: box.network, storage: box.storage)
        box.setResponses(["/previews/test.png": Data("corrupt".utf8)])
        do { _ = try await service.preview(preview); XCTFail("Bad image hash must fail") } catch {}
        XCTAssertTrue(box.files.isEmpty)
        box.setResponses(["/previews/test.png": image])
        let downloaded = try await service.preview(preview)
        XCTAssertEqual(downloaded, image)
        let count = box.urls.count
        let reads = box.storageReads.count
        box.setResponses([:])
        let cached = try await service.preview(preview)
        XCTAssertEqual(cached, image)
        XCTAssertEqual(box.urls.count, count)
        XCTAssertEqual(box.storageReads.count, reads, "Memory hits must skip disk validation")
        let missing = ShaderPreview(path: "previews/missing.png", hash: String(repeating: "b", count: 64), publicationRevision: preview.publicationRevision)
        do { _ = try await service.preview(missing); XCTFail("Missing image must fail") } catch {}
    }
    func testPipelineCacheRecompilesSameIDWithChangedSource() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device)
        let first = TestCatalog.initialShader
        var revised = ShaderDefinition(id: first.id, title: first.title, category: first.category,
                                       description: first.description, colors: first.colors, source: first.source + "\n// revision\n")
        revised.updatedAt = Date()
        let pipeline = try await compiler.pipeline(for: first)
        let updated = try await compiler.pipeline(for: revised)
        XCTAssertFalse(pipeline === updated)
        let reused = try await compiler.pipeline(for: revised)
        XCTAssertTrue(updated === reused)
    }
}

nonisolated final class CatalogTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var responses: [String: Data] = [:]
    private var requests: [URL] = []
    private var reads: [String] = []
    private var writes: [String] = []
    private var readOnMain = false
    let clock = TestClock()
    private var failing = false
    var files: [String: Data] { lock.withLock { stored } }
    var responseFiles: [String: Data] { lock.withLock { responses } }
    var urls: [URL] { lock.withLock { requests } }
    var storageReads: [String] { lock.withLock { reads } }
    var storageWrites: [String] { lock.withLock { writes } }
    var storageReadOnMain: Bool { lock.withLock { readOnMain } }
    var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func setResponses(_ values: [String: Data]) { lock.withLock { responses = values } }
    var network: CatalogNetwork {
        CatalogNetwork { [self] url, _ in
            try lock.withLock {
                requests.append(url)
                let path = url.host == "raw.githubusercontent.com"
                    ? "/" + url.path.split(separator: "/").dropFirst(3).joined(separator: "/")
                    : url.path.replacingOccurrences(of: "/repos/hbmartin/HolodeckShaders", with: "")
                guard let response = responses[path] else { throw CatalogError.invalidResponse }
                return response
            }
        }
    }
    var storage: CatalogStorage {
        CatalogStorage(read: { [self] name in lock.withLock {
            reads.append(name)
            readOnMain = readOnMain || Thread.isMainThread
            return stored[name]
        } }, write: { [self] name, data in
            try lock.withLock {
                if failing { throw CatalogError.invalidResponse }
                stored[name] = data
                writes.append(name)
            }
        })
    }
}

actor PreviewRequestGate {
    private(set) var requestCount = 0
    private var requests: [String: CheckedContinuation<Data, Never>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func image(_ path: String) async -> Data {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            requests[path] = continuation
            observers.removeValue(forKey: path)?.resume()
        }
    }
    func waitForRequest(_ path: String) async {
        if requests[path] != nil { return }
        await withCheckedContinuation { observers[path] = $0 }
    }
    func complete(_ path: String, data: Data) {
        requests.removeValue(forKey: path)?.resume(returning: data)
    }
}
