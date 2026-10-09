import XCTest
@testable import HolodeckCore

extension CatalogTests {
    func testDatesAcceptFractionsAndOffsetsButRequireTimezone() throws {
        for date in ["2026-10-09T17:04:08Z", "2026-10-09T17:04:08.000Z",
                     "2026-10-09T17:04:08.123456+01:00", "2026-10-09T17:04:08-07:00",
                     "2026-10-09T17:04:08+0100", "2026-10-09T17:04:08+01", "2026-10-09T17:04:08z"] {
            var value = candidate()
            value.manifest.shaders[0].updatedAt = date
            let catalog = try value.validated()
            XCTAssertEqual(catalog.shaders[0].updatedAt, CatalogManifest.date(date))
        }
        for date in ["yesterday", "2026-10-09T17:04:08", "2026-10-09", "2026-10-09T17:04:08Zjunk",
                     "2026-02-30T17:04:08Z", "2026-10-09T25:04:08Z", "2026-10-09T17:60:08Z",
                     "2026-10-09T17:04:08+99:00", "2026-10-09T17:04:08Z\n"] {
            XCTAssertNil(CatalogManifest.date(date), date)
        }
    }

    func testBOMDownloadPreservesBytesThroughDiskRoundTrip() async throws {
        var expected = candidate()
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data(expected.sources["plasma"]!.utf8)
        expected.sources["plasma"] = String(validating: bytes, as: UTF8.self)!
        expected.manifest.shaders[0].sourceSHA256 = CatalogHash.sha256(bytes)
        let box = CatalogTestBox()
        let service = try makeService(expected, box: box)
        let downloaded = try await service.refresh()
        let result = try XCTUnwrap(downloaded)
        XCTAssertEqual(Data(result.shaders[0].source.utf8), bytes)
        XCTAssertEqual(result.shaders[0].sourceHash, CatalogHash.sha256(bytes))
        let reloaded = await CatalogService.offline(storage: box.storage).current()
        XCTAssertEqual(reloaded?.shaders[0].source, result.shaders[0].source)
    }

    func testInvalidUTF8WithMatchingHashIsRejected() async throws {
        var expected = candidate()
        let bytes = Data([0xff, 0xfe, 0x41])
        expected.manifest.shaders[0].sourceSHA256 = CatalogHash.sha256(bytes)
        let box = CatalogTestBox()
        let service = try makeService(expected, box: box)
        var responses = box.responseFiles
        responses["/sources/plasma.metal"] = bytes
        box.setResponses(responses)
        do { _ = try await service.refresh(); XCTFail("Invalid UTF-8 must not activate") } catch {}
        let retained = await service.current()
        XCTAssertEqual(retained?.publicationRevision, TestCatalog.catalog.publicationRevision)
        XCTAssertNil(box.files["snapshot.json"])
    }

    func testCacheLoadsOnceOffMainAndConstructorDoesNoIO() async throws {
        let box = CatalogTestBox()
        try box.storage.write("snapshot.json", TestCatalog.data)
        let service = CatalogService.offline(storage: box.storage)
        XCTAssertTrue(box.storageReads.isEmpty)
        let first = await service.current()
        let second = await service.current()
        XCTAssertEqual(first?.publicationRevision, second?.publicationRevision)
        XCTAssertEqual(box.storageReads, ["snapshot.json"])
        XCTAssertFalse(box.storageReadOnMain)
    }

    func testFullSizeDiskCacheLoadsOffMainAndRejectsAggregateOverflow() async throws {
        var expected = candidate()
        let original = expected.manifest.shaders[0]
        let bytes = Data(repeating: 0x20, count: 1_048_576)
        let source = String(validating: bytes, as: UTF8.self)!
        let hash = CatalogHash.sha256(bytes)
        expected.manifest.shaders = (0..<16).map { number in
            var entry = original
            entry.id = "boundary-\(number)"
            entry.sourcePath = "sources/\(entry.id).metal"
            entry.previewPath = "previews/\(entry.id).png"
            entry.sourceSHA256 = hash
            return entry
        }
        expected.manifest.defaultShaderID = expected.manifest.shaders[0].id
        expected.manifest.collections = nil
        expected.sources = Dictionary(uniqueKeysWithValues: expected.manifest.shaders.map { ($0.id, source) })
        let box = CatalogTestBox()
        try box.storage.write("snapshot.json", JSONEncoder().encode(expected))
        let service = CatalogService.offline(storage: box.storage)
        let full = await service.current()
        XCTAssertEqual(full?.shaders.count, 16)
        XCTAssertFalse(box.storageReadOnMain)
        var extra = original
        extra.id = "overflow"
        extra.sourcePath = "sources/overflow.metal"
        extra.previewPath = "previews/overflow.png"
        extra.sourceSHA256 = CatalogHash.sha256(Data([0x20]))
        expected.manifest.shaders.append(extra)
        expected.sources[extra.id] = " "
        try box.storage.write("snapshot.json", JSONEncoder().encode(expected))
        let rejected = await CatalogService.offline(storage: box.storage).current()
        XCTAssertNil(rejected)
    }

    func testLargeCatalogUsesOnlyOneAPIRequestAndPreviewsAreIndependent() async throws {
        var expected = candidate()
        let original = expected.manifest.shaders[0]
        for number in 0..<64 {
            var entry = original
            entry.id = "extra-\(number)"
            entry.sourcePath = "sources/\(entry.id).metal"
            entry.previewPath = "previews/\(entry.id).png"
            expected.manifest.shaders.append(entry)
            expected.sources[entry.id] = expected.sources[original.id]
        }
        let box = CatalogTestBox()
        let service = try makeService(expected, box: box)
        let downloaded = try await service.refresh()
        let result = try XCTUnwrap(downloaded)
        XCTAssertEqual(result.shaders.count, 72)
        XCTAssertEqual(box.urls.filter { $0.host == "api.github.com" }.count, 1)
        XCTAssertTrue(box.urls.dropFirst().allSatisfy { $0.path.hasPrefix("/hbmartin/HolodeckShaders/\(expected.publicationRevision)/") })
        do { _ = try await service.preview(result.shaders[0].preview!); XCTFail("Preview is unavailable") } catch {}
        let current = await service.current()
        XCTAssertEqual(current?.publicationRevision, result.publicationRevision)
    }

    func testDecodedPreviewMemoryHitReusesImageAndReadsDiskOnce() async throws {
        let preview = TestCatalog.shaders[0].preview!
        let box = CatalogTestBox()
        try box.storage.write("preview-\(preview.hash).png", TestCatalog.preview(named: "preview-\(preview.hash).png"))
        let service = CatalogService.offline(storage: box.storage)
        let first = try await service.previewImage(preview, maxPixelSize: 640)
        let second = try await service.previewImage(preview, maxPixelSize: 640)
        let small = try await service.previewImage(preview, maxPixelSize: 176)
        XCTAssertTrue(first === second)
        XCTAssertLessThanOrEqual(max(first.width, first.height), 640)
        XCTAssertLessThanOrEqual(max(small.width, small.height), 176)
        XCTAssertEqual(box.storageReads.count, 1)
        XCTAssertFalse(box.storageReadOnMain)
    }

    func testPreviewRequestsCoalesceByHashAcrossRevisions() async throws {
        let gate = PreviewRequestGate()
        let bytes = try TestCatalog.preview(named: "preview-" + TestCatalog.shaders[0].preview!.hash + ".png")
        let hash = CatalogHash.sha256(bytes)
        let firstPreview = ShaderPreview(path: "previews/first.png", hash: hash, publicationRevision: String(repeating: "a", count: 40))
        let secondPreview = ShaderPreview(path: "previews/second.png", hash: hash, publicationRevision: String(repeating: "b", count: 40))
        let service = CatalogService(network: CatalogNetwork { url, _ in await gate.image(url.lastPathComponent) }, storage: .disabled)
        let first = Task { try await service.preview(firstPreview) }
        await gate.waitForRequest("first.png")
        let second = Task { try await service.preview(secondPreview) }
        await Task.yield()
        await gate.complete("first.png", data: bytes)
        let one = try await first.value
        let two = try await second.value
        XCTAssertEqual(one, two)
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
    }

    func testPreviewMemoryBudgetEvictsLeastRecentlyUsedData() async throws {
        let box = CatalogTestBox()
        let service = CatalogService.offline(storage: box.storage)
        var previews: [ShaderPreview] = []
        for value in UInt8(1)...3 {
            let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: value, count: 6_000_000)
            let hash = CatalogHash.sha256(bytes)
            try box.storage.write("preview-\(hash).png", bytes)
            previews.append(ShaderPreview(path: "previews/test.png", hash: hash, publicationRevision: TestCatalog.catalog.publicationRevision))
        }
        _ = try await service.preview(previews[0])
        _ = try await service.preview(previews[1])
        _ = try await service.preview(previews[0])
        _ = try await service.preview(previews[2])
        _ = try await service.preview(previews[0])
        XCTAssertEqual(box.storageReads.count, 3)
        _ = try await service.preview(previews[1])
        XCTAssertEqual(box.storageReads.count, 4)
    }

    func testDecodedPreviewBudgetEvictsImagesWithoutRereadingEncodedData() async throws {
        let preview = TestCatalog.shaders[0].preview!
        let box = CatalogTestBox()
        try box.storage.write("preview-\(preview.hash).png", TestCatalog.preview(named: "preview-\(preview.hash).png"))
        let service = CatalogService.offline(storage: box.storage)
        let first = try await service.previewImage(preview, maxPixelSize: 1280)
        for size in 1281...1292 { _ = try await service.previewImage(preview, maxPixelSize: size) }
        let redecoded = try await service.previewImage(preview, maxPixelSize: 1280)
        XCTAssertFalse(first === redecoded, "Decoded images must fit the 32 MiB budget")
        XCTAssertEqual(box.storageReads.count, 1, "Encoded memory hits avoid disk reads even after decoded eviction")
    }

    func testConcurrentThumbnailRequestsReuseOneDecodedImage() async throws {
        let gate = PreviewRequestGate()
        let preview = TestCatalog.shaders[0].preview!
        let bytes = try TestCatalog.preview(named: "preview-\(preview.hash).png")
        let service = CatalogService(network: CatalogNetwork { url, _ in await gate.image(url.lastPathComponent) }, storage: .disabled)
        let first = Task { try await service.previewImage(preview, maxPixelSize: 640) }
        await gate.waitForRequest("plasma.png")
        let second = Task { try await service.previewImage(preview, maxPixelSize: 640) }
        await Task.yield()
        await gate.complete("plasma.png", data: bytes)
        let image = try await first.value
        let coalesced = try await second.value
        XCTAssertTrue(image === coalesced)
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
    }
}
