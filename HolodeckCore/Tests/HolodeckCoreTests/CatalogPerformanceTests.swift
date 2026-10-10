import Foundation
import ImageIO
import XCTest
@testable import HolodeckCore

/// Opt-in optimized comparisons, using deterministic chunk delivery and a real preview file.
@MainActor
final class CatalogPerformanceTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_PROFILE"] == "1" else {
            throw XCTSkip("Set HOLODECK_PROFILE=1 and run with -c release to profile catalog loading.")
        }
    }

    func testRepeatedFilteringAtCatalogLimitUsesPreparedResults() throws {
        try requireOptIn()
        var snapshot = TestCatalog.snapshot
        let template = snapshot.manifest.shaders[0]
        let source = try XCTUnwrap(snapshot.sources[template.id])
        snapshot.manifest.shaders = (0..<500).map { index in
            var entry = template
            entry.id = "scene-\(index)"
            entry.name = "Scene \(index)"
            entry.sourcePath = "sources/scene-\(index).metal"
            entry.previewPath = "previews/scene-\(index).png"
            entry.discovery = .init(tags: ["color"], moods: ["calm"], motion: "slow")
            return entry
        }
        snapshot.manifest.defaultShaderID = "scene-0"
        snapshot.sources = Dictionary(uniqueKeysWithValues: snapshot.manifest.shaders.map { ($0.id, source) })
        let catalog = try snapshot.validated()
        let cache = SceneFilterCache()
        let expected = cache.filter(catalog, query: "scene", mood: "calm").map(\.id)
        let clock = ContinuousClock()
        var start = clock.now
        for _ in 0..<1000 {
            XCTAssertEqual(SceneLibrary.filter(catalog.shaders, query: "scene", favoritesOnly: false, favorites: [], mood: "calm").map(\.id), expected)
        }
        let uncached = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
        start = clock.now
        for _ in 0..<1000 {
            XCTAssertEqual(cache.filter(catalog, query: "scene", mood: "calm").map(\.id), expected)
        }
        let cached = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
        XCTAssertEqual(cache.computationCount, 1)
        print("Scene filter profile: 500 scenes, 1000 repeated redraws; filter \(uncached) ms, prepared results \(cached) ms, 1 computation")
    }

    func testChunkedDownloadComparedWithPreviousByteLoop() async throws {
        try requireOptIn()
        let preview = TestCatalog.shaders[3].preview!
        let data = try TestCatalog.preview(named: "preview-\(preview.hash).png")
        let url = URL(string: "https://catalog.test/" + UUID().uuidString)!
        let chunks = stride(from: 0, to: data.count, by: 16_384).map { offset in
            data.subdata(in: offset..<min(offset + 16_384, data.count))
        }
        CatalogProtocol.registry.set(url, response: .init(status: 200, length: data.count, chunks: chunks, started: nil, stopped: nil))
        defer { CatalogProtocol.registry.remove(url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let network = CatalogNetwork.session(configuration: configuration)
        let previous = URLSession(configuration: configuration)
        defer { previous.invalidateAndCancel() }
        var oldTimes: [Double] = [], chunkTimes: [Double] = []
        for iteration in 0..<7 {
            let clock = ContinuousClock()
            var start = clock.now
            let old = try await Task.detached { try await CatalogBenchmark.byteLoop(previous, url: url, limit: 8_388_608) }.value
            let oldTime = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
            start = clock.now
            let current = try await network.get(url, 8_388_608)
            let chunkTime = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
            XCTAssertEqual(old, data)
            XCTAssertEqual(current, data)
            if iteration >= 2 { oldTimes.append(oldTime); chunkTimes.append(chunkTime) }
        }
        print("Catalog download profile: \(data.count) bytes, median of 5 after 2 warmups, URLProtocol chunks; byte loop \(oldTimes.sorted()[2]) ms, delegate \(chunkTimes.sorted()[2]) ms")
    }

    func testRepeatedPreviewBrowsingComparedWithPreviousReadHashDecode() async throws {
        try requireOptIn()
        let preview = TestCatalog.shaders[0].preview!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CatalogStorage.disk(at: directory)
        let filename = "preview-\(preview.hash).png"
        try disk.write(filename, TestCatalog.preview(named: filename))
        let counter = CatalogTestBox()
        let storage = CatalogStorage(read: { name in
            _ = try counter.storage.read(name)
            return try disk.read(name)
        }, write: disk.write)
        let service = CatalogService.offline(storage: storage)
        let first = try await service.previewImage(preview, maxPixelSize: 640)
        let clock = ContinuousClock()
        var start = clock.now
        for _ in 0..<50 {
            let image = try await service.previewImage(preview, maxPixelSize: 640)
            XCTAssertTrue(image === first)
        }
        let cachedTime = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
        XCTAssertEqual(counter.storageReads.count, 1)
        XCTAssertFalse(counter.storageReadOnMain)
        start = clock.now
        let fullImageCost = try await Task.detached {
            var cost = 0
            for _ in 0..<50 {
                let bytes = try XCTUnwrap(storage.read(filename))
                XCTAssertEqual(CatalogHash.sha256(bytes), preview.hash)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
                cost = image.bytesPerRow * image.height
            }
            return cost
        }.value
        let previousTime = CatalogBenchmark.milliseconds(start.duration(to: clock.now))
        XCTAssertEqual(counter.storageReads.count, 51)
        print("Preview browsing profile: 50 requests; read/hash/full decode \(previousTime) ms (50 reads), warm thumbnail cache \(cachedTime) ms (0 reads/decodes); full image \(fullImageCost) bytes, TV thumbnail \(first.bytesPerRow * first.height) bytes")
    }
}

nonisolated private enum CatalogBenchmark {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func byteLoop(_ session: URLSession, url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.invalidResponse }
        guard response.expectedContentLength <= Int64(limit) else { throw CatalogError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw CatalogError.oversizedResponse }
            data.append(byte)
        }
        return data
    }
}
