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

    func testInvalidDiscoveryAndCollectionsRejectPublication() throws {
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
        XCTAssertThrowsError(try invalid.validate())
    }

    func testRefreshPersistsDiscoveryAndInvalidRefreshRetainsSnapshot() async throws {
        let snapshot = try fixture()
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
