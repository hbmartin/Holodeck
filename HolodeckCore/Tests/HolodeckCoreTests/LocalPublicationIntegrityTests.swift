import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class LocalPublicationIntegrityTests: XCTestCase {
    private func bytes() throws -> Data { try CatalogPublication.encodedManifest(TestCatalog.snapshot.manifest) }
    private func catalog(_ bytes: Data) throws -> ValidatedCatalog {
        let revision = CatalogHash.sha256(bytes)
        return try CatalogPublication.finish(CatalogPublication.builder(bytes, revision: revision, kind: .localPublication),
            sources: TestCatalog.snapshot.sources.mapValues { Data($0.utf8) }, revision: revision)
    }
    private func source(_ bytes: Data, box: CatalogTestBox, revision: String? = nil) throws -> CatalogSource {
        var responses = ["/head": try JSONEncoder().encode(CatalogHead(revision: revision ?? CatalogHash.sha256(bytes))), "/catalog.json": bytes]
        for (id, text) in TestCatalog.snapshot.sources { responses["/sources/\(id).metal"] = Data(text.utf8) }
        box.setResponses(responses)
        return CatalogSource(kind: .localPublication, get: box.source.get)
    }
    private func changed(_ data: Data, update: (inout [String: Any]) -> Void) throws -> Data {
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        update(&wire)
        return try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
    }
    func testPoisonedCacheIsDeletedAndSameRevisionDownloadedAgain() async throws {
        let wire = try bytes(), good = try catalog(wire), box = CatalogTestBox()
        let poisoned = try changed(wire) { raw in
            var entries = raw["shaders"] as! [[String: Any]]; entries[0]["name"] = "Unexpected title"; raw["shaders"] = entries
        }
        let bad = try changed(CatalogPublication.persisted(good, kind: .localPublication)) { $0["manifestBytes"] = poisoned.base64EncodedString() }
        try box.storage.write("snapshot.json", bad)
        let service = CatalogService(source: try source(wire, box: box), storage: box.storage)
        let cached = await service.current(); XCTAssertNil(cached)
        XCTAssertNil(box.files["snapshot.json"]); XCTAssertEqual(box.storageRemovals, ["snapshot.json"])
        let recovered = try await service.refresh()
        XCTAssertEqual(recovered?.shaders[0].title, good.shaders[0].title)
        let persisted = try CatalogPublication.restored(XCTUnwrap(box.files["snapshot.json"]), kind: .localPublication)
        XCTAssertEqual(persisted.localPublicationEvidence?.manifestBytes, wire)
        let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(box.files["snapshot.json"])) as? [String: Any])
        XCTAssertNil(cache["manifest"])
    }
    func testHealthyVersionTwoCacheWorksOfflineAndUnchangedRefreshSkipsAssets() async throws {
        let wire = try bytes(), good = try catalog(wire), box = CatalogTestBox()
        try box.storage.write("snapshot.json", CatalogPublication.persisted(good, kind: .localPublication))
        let network = try source(wire, box: box)
        let offline = CatalogService(source: network, storage: box.storage, enabled: false)
        let cached = await offline.current(); XCTAssertEqual(cached?.publicationRevision, good.publicationRevision)
        XCTAssertTrue(box.urls.isEmpty)
        let online = CatalogService(source: network, storage: box.storage)
        guard case .unchanged = try await online.refreshOutcome() else { return XCTFail("Unchanged publication downloaded") }
        XCTAssertEqual(box.urls, [.head])
    }
    func testOldLocalCachesAreDeletedAndVersionOneManifestsRejected() async throws {
        let box = CatalogTestBox(), old = try JSONEncoder().encode(TestCatalog.snapshot)
        try box.storage.write("snapshot.json", old)
        let network = CatalogSource(kind: .localPublication, get: box.source.get)
        let service = CatalogService(source: network, storage: box.storage, enabled: false)
        let cached = await service.current(); XCTAssertNil(cached); XCTAssertNil(box.files["snapshot.json"])
        let manifest = try JSONEncoder().encode(TestCatalog.snapshot.manifest)
        XCTAssertThrowsError(try CatalogPublication.builder(manifest, revision: CatalogHash.sha256(manifest), kind: .localPublication))
        box.setResponses(["/head": try JSONEncoder().encode(CatalogHead(revision: TestCatalog.snapshot.publicationRevision))])
        do { _ = try await CatalogService(source: network, storage: .disabled).refresh(); XCTFail("Legacy revision accepted") }
        catch CatalogError.invalidManifest {}
    }
    func testRawHashMismatchCannotReplaceGoodSnapshot() async throws {
        let wire = try bytes(), good = try catalog(wire), box = CatalogTestBox()
        let next = try changed(wire) { $0["newOptionalField"] = "next" }
        try box.storage.write("snapshot.json", CatalogPublication.persisted(good, kind: .localPublication))
        let service = CatalogService(source: try source(wire, box: box, revision: CatalogHash.sha256(next)), storage: box.storage)
        do { _ = try await service.refresh(); XCTFail("Mismatched hash accepted") } catch CatalogError.invalidManifest {}
        let current = await service.current(); XCTAssertEqual(current?.publicationRevision, good.publicationRevision)
    }
    func testInitialLocalCatalogRequiresImmutableEvidence() throws {
        let good = try catalog(bytes())
        let network = CatalogSource(kind: .localPublication, get: CatalogSource.unavailable.get)
        XCTAssertNotNil(CatalogService(initialCatalog: good, source: network, storage: .disabled).initialCatalog)
        var bad = good.snapshot; bad.manifest.shaders[0].name = "Unexpected title"
        XCTAssertNil(CatalogService(initialCatalog: try bad.validated(), source: network, storage: .disabled).initialCatalog)
    }
    func testUnknownFieldsDiscardedDiscoveryAndAlternateFloatSpellingsKeepRawIdentity() throws {
        let wire = try changed(bytes()) { raw in
            raw["futureOptional"] = ["enabled": true]
            var entries = raw["shaders"] as! [[String: Any]]
            entries[0]["colors"] = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
            entries[0]["discovery"] = ["tags": [""], "moods": ["calm"], "motion": "slow"]
            entries[0]["futureEntryField"] = 42; raw["shaders"] = entries
        }
        for data in [wire, Data(String(decoding: wire, as: UTF8.self).replacingOccurrences(of: "0.10000000000000001", with: "1e-1").replacingOccurrences(of: "0.1,", with: "1e-1,").utf8)] {
            let value = try catalog(data)
            XCTAssertEqual(value.publicationRevision, CatalogHash.sha256(data))
            XCTAssertEqual(value.snapshot.manifest.sourceRevision, value.publicationRevision)
            XCTAssertNil(value.shaders[0].discovery)
            let restored = try CatalogPublication.restored(CatalogPublication.persisted(value, kind: .localPublication), kind: .localPublication)
            XCTAssertEqual(restored.localPublicationEvidence?.manifestBytes, data)
        }
    }
    func testFinalEncodedManifestSizeBoundaryAndNoSelfReference() throws {
        var manifest = TestCatalog.snapshot.manifest
        manifest.shaders = [manifest.shaders[0]]; manifest.collections = nil; manifest.shaders[0].description = "x"
        let base = try CatalogPublication.encodedManifest(manifest).count, padding = CatalogLimits.manifestBytes - base
        manifest.shaders[0].description += String(repeating: "\u{0300}", count: padding / 2)
        if padding % 2 != 0 { manifest.shaders[0].description += "a" }
        try manifest.validate()
        let encoded = try CatalogPublication.encodedManifest(manifest)
        XCTAssertEqual(encoded.count, CatalogLimits.manifestBytes)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(raw["schemaVersion"] as? Int, 2); XCTAssertNil(raw["sourceRevision"])
        manifest.sourceRevision = String(repeating: "f", count: 64)
        XCTAssertEqual(try CatalogPublication.encodedManifest(manifest), encoded)
        manifest.shaders[0].description += "a"
        XCTAssertThrowsError(try CatalogPublication.encodedManifest(manifest))
    }
    func testSourceWrapperPreservesKindAndAvailability() async throws {
        let box = CatalogTestBox(), data = try bytes()
        let original = CatalogSource(kind: .localPublication, waitForAvailability: {}) { _, _ in data }
        let wrapped = original.replacingGet { request, limit in try await original.get(request, limit) }
        XCTAssertEqual(wrapped.kind, .localPublication); XCTAssertNotNil(wrapped.waitForAvailability)
        let service = CatalogService(source: wrapped, storage: box.storage)
        // The wrapper still requires raw identity; it cannot silently become a standard source.
        let bad = try CatalogSnapshot(manifest: TestCatalog.snapshot.manifest, sources: TestCatalog.snapshot.sources,
            publicationRevision: CatalogHash.sha256(data)).validated()
        XCTAssertNil(CatalogService(initialCatalog: bad, source: wrapped, storage: .disabled).initialCatalog)
        _ = await service.current()
    }
}
