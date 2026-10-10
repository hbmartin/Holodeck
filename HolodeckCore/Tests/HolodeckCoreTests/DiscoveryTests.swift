import XCTest
@testable import HolodeckCore

@MainActor
final class DiscoveryTests: XCTestCase {
    private func fixture() throws -> CatalogSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DiscoveryFixture", withExtension: "json", subdirectory: "TestSupport"))
        let value = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func testExpandedPublicationPassesFrozenLegacyDecoder() throws {
        let snapshot = try fixture()
        let data = try JSONEncoder().encode(snapshot)
        let legacy = try JSONDecoder().decode(LegacyCatalogSnapshot.self, from: data)
        try legacy.validate()
        XCTAssertEqual(legacy.shaders.map(\.id), try snapshot.validated().shaders.map(\.id))
        XCTAssertEqual(legacy.initialShader.id, "plasma")
        XCTAssertEqual(legacy.shaders.map(\.source), try snapshot.validated().shaders.map(\.source))
    }

    func testOldCacheAndOptionalMetadataRoundTrip() throws {
        XCTAssertNil(TestCatalog.snapshot.manifest.collections)
        XCTAssertTrue(TestCatalog.shaders.allSatisfy { $0.discovery == nil })
        XCTAssertEqual(TestCatalog.catalog.collections.map(\.id), ["procedural", "materials"])
        let snapshot = try fixture()
        let restored = try JSONDecoder().decode(CatalogSnapshot.self, from: JSONEncoder().encode(snapshot))
        try restored.validate()
        XCTAssertEqual(try restored.validated().collections, try snapshot.validated().collections)
        XCTAssertEqual(try restored.validated().shaders.map(\.discovery), try snapshot.validated().shaders.map(\.discovery))
        var future = restored
        future.manifest.shaders[0].discovery = SceneDiscovery(tags: ["future"], moods: ["serene"], motion: "glacial")
        XCTAssertNoThrow(try future.validate())
        XCTAssertTrue(SceneLibrary.moods(try future.validated().shaders).contains("serene"))
    }

    func testCollectionOrderAndIntersectingFilters() throws {
        let snapshot = try fixture()
        let collection = (try snapshot.validated()).collections[0]
        let scenes = try snapshot.validated().shaders
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "", favoritesOnly: false, favorites: [], collection: collection).map(\.id), collection.shaderIDs)
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "", favoritesOnly: true, favorites: ["waves", "aurora", "chrome"], collection: collection, mood: "calm", motion: "slow").map(\.id), ["aurora", "chrome"])
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "material", favoritesOnly: false, favorites: []).map(\.id), ["chrome", "brushed-gold", "iridescent"])
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "", favoritesOnly: false, favorites: [], collection: collection, mood: "energetic").map(\.id), ["kaleidoscope"])
        XCTAssertTrue(SceneLibrary.filter(scenes, query: "", favoritesOnly: false, favorites: [], mood: "dreamy", motion: "fast").isEmpty)
        XCTAssertTrue(SceneLibrary.filter(TestCatalog.shaders, query: "", favoritesOnly: false, favorites: [], mood: "calm").isEmpty)
        XCTAssertEqual(SceneLibrary.filter(scenes, query: "", favoritesOnly: false, favorites: []).map(\.id), scenes.map(\.id))
    }

    func testInvalidCollectionsRejectPublicationAndDuplicateLabelsNormalize() throws {
        let original = try fixture()
        var invalid = original
        invalid.manifest.collections![0].id = "all"
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.manifest.collections![0].shaderIDs = ["missing"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.manifest.collections![0].shaderIDs = ["aurora", "aurora"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.manifest.collections!.append(invalid.manifest.collections![0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.manifest.shaders[0].discovery!.tags = ["duplicate", "duplicate"]
        XCTAssertEqual(try invalid.validated().shaders[0].discovery?.tags, ["duplicate"])
    }

    func testMalformedDiscoveryDoesNotBlockCatalogOrCacheRoundTrip() throws {
        let original = try fixture()
        let badObjects: [[String: Any]] = [
            ["tags": [], "moods": []],
            ["tags": [1], "moods": [], "motion": "slow"],
            ["tags": [], "moods": (0..<9).map { "mood\($0)" }, "motion": "slow"],
            ["tags": (0..<33).map { "tag\($0)" }, "moods": [], "motion": "slow"],
            ["tags": [""], "moods": [], "motion": "slow"],
            ["tags": [], "moods": [], "motion": "  "],
            ["tags": [], "moods": [], "motion": String(repeating: "x", count: 101)]
        ]
        for object in badObjects {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var manifest = try XCTUnwrap(json["manifest"] as? [String: Any])
            var entries = try XCTUnwrap(manifest["shaders"] as? [[String: Any]])
            entries[0]["discovery"] = object
            manifest["shaders"] = entries; json["manifest"] = manifest
            let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            let catalog = try decoded.validated()
            XCTAssertEqual(catalog.shaders.count, original.manifest.shaders.count)
            XCTAssertNil(catalog.shaders[0].discovery)
            XCTAssertEqual(catalog.shaders[1].discovery, try original.validated().shaders[1].discovery)
            XCTAssertEqual(catalog.snapshot.sources, original.sources)
            let restored = try JSONDecoder().decode(CatalogSnapshot.self, from: JSONEncoder().encode(catalog.snapshot)).validated()
            XCTAssertNil(restored.shaders[0].discovery)
        }
        var programmatic = original
        programmatic.manifest.shaders[0].discovery!.moods = (0..<9).map { "mood\($0)" }
        XCTAssertNil(try programmatic.validated().snapshot.manifest.shaders[0].discovery)
    }

    func testDiscoveryNormalizationAndDuplicateIDFiltering() throws {
        var snapshot = try fixture()
        snapshot.manifest.shaders[0].discovery = SceneDiscovery(tags: [" Night ", "night"], moods: [" Calm ", "calm"], motion: " SLOW ")
        let catalog = try snapshot.validated()
        XCTAssertEqual(catalog.shaders[0].discovery, SceneDiscovery(tags: ["night"], moods: ["calm"], motion: "slow"))
        XCTAssertEqual(catalog.moods.filter { $0 == "calm" }.count, 1)
        XCTAssertEqual(catalog.motions.filter { $0 == "slow" }.count, 1)
        XCTAssertTrue(SceneLibrary.filter(catalog.shaders, query: "", favoritesOnly: false, favorites: [], mood: " CALM ", motion: "Slow").contains { $0.id == "plasma" })
        let duplicated = [catalog.shaders[0], catalog.shaders[0], catalog.shaders[1]]
        XCTAssertEqual(SceneLibrary.filter(duplicated, query: "", favoritesOnly: false, favorites: []).count, 3)
        let collection = CatalogCollection(id: "test", name: "Test", description: "Test", shaderIDs: ["plasma", "aurora"])
        XCTAssertEqual(SceneLibrary.filter(duplicated, query: "", favoritesOnly: false, favorites: [], collection: collection).map(\.id), ["plasma", "aurora"])
    }

    func testFilterCacheInvalidatesForEveryInputAndPublication() throws {
        let catalog = try fixture().validated()
        let cache = SceneFilterCache()
        func check(query: String = "", only: Bool = false, favorites: Set<String> = [], collection: String = "all", mood: String? = nil, motion: String? = nil) {
            let count = cache.computationCount
            let expected = SceneLibrary.filter(catalog.shaders, query: query, favoritesOnly: only, favorites: favorites,
                collection: catalog.collections.first { $0.id == collection }, mood: mood, motion: motion).map(\.id)
            for _ in 0..<3 {
                XCTAssertEqual(cache.filter(catalog, query: query, favoritesOnly: only, favorites: favorites, collectionID: collection, mood: mood, motion: motion).map(\.id), expected)
            }
            XCTAssertEqual(cache.computationCount, count + 1)
        }
        check(); check(query: "material"); check(only: true); check(only: true, favorites: ["plasma"])
        check(collection: catalog.collections[0].id); check(mood: "calm"); check(motion: "slow")
        var next = catalog.snapshot
        next.publicationRevision = String(repeating: "f", count: 40)
        next.manifest.shaders[0].name = "New Name"
        let count = cache.computationCount
        XCTAssertEqual(cache.filter(try next.validated()).first?.title, "New Name")
        XCTAssertEqual(cache.computationCount, count + 1)
    }

    func testRefreshPersistsSanitizedDiscoveryAndInvalidRefreshRetainsSnapshot() async throws {
        var snapshot = try fixture()
        snapshot.manifest.shaders[0].discovery!.moods = (0..<9).map { "mood\($0)" }
        snapshot.manifest.shaders[1].discovery = .init(tags: [" NIGHT ", "night"], moods: [" Calm ", "calm"], motion: " Slow ")
        let box = CatalogTestBox()
        var responses = ["/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(snapshot.publicationRevision)\"}}".utf8),
                         "/catalog.json": try JSONEncoder().encode(snapshot.manifest)]
        for entry in snapshot.manifest.shaders { responses["/\(entry.sourcePath)"] = Data(snapshot.sources[entry.id]!.utf8) }
        box.setResponses(responses)
        try box.storage.write("snapshot.json", TestCatalog.data)
        let service = CatalogService(network: box.network, storage: box.storage, clock: box.clock)
        let refreshed = try await service.refresh(force: true)
        XCTAssertEqual(refreshed?.collections, try snapshot.validated().collections)
        let cached = CatalogService(storage: box.storage, enabled: false)
        let current = await cached.current()
        XCTAssertEqual(current?.shaders.map(\.discovery), try snapshot.validated().shaders.map(\.discovery))
        XCTAssertNil(current?.shaders[0].discovery)
        XCTAssertEqual(current?.shaders[1].discovery, .init(tags: ["night"], moods: ["calm"], motion: "slow"))
        var bad = snapshot.manifest; bad.collections![0].shaderIDs = ["missing"]
        responses["/git/ref/heads/published"] = Data("{\"object\":{\"sha\":\"\(String(repeating: "f", count: 40))\"}}".utf8)
        responses["/catalog.json"] = try JSONEncoder().encode(bad)
        box.setResponses(responses)
        do { _ = try await service.refresh(force: true); XCTFail("Invalid collection must fail refresh") } catch {}
        let retained = await service.current()
        XCTAssertEqual(retained?.publicationRevision, snapshot.publicationRevision)
        let reloaded = await CatalogService.offline(storage: box.storage).current()
        XCTAssertEqual(reloaded?.collections, try snapshot.validated().collections)
    }
}
