import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class LocalPublicationIntegrityTests: XCTestCase {
    private func localSnapshot() throws -> CatalogSnapshot {
        var snapshot = try TestCatalog.snapshot.validated().snapshot
        let revision = try CatalogPublication.revision(for: snapshot.manifest)
        snapshot.manifest.sourceRevision = revision; snapshot.publicationRevision = revision
        return snapshot
    }
    private func source(_ snapshot: CatalogSnapshot, box: CatalogTestBox) throws -> CatalogSource {
        var responses = ["/head": try JSONEncoder().encode(CatalogHead(revision: snapshot.publicationRevision)),
                         "/catalog.json": try JSONEncoder().encode(snapshot.manifest)]
        for entry in snapshot.manifest.shaders { responses["/" + entry.sourcePath] = Data(snapshot.sources[entry.id]!.utf8) }
        box.setResponses(responses)
        var source = box.source; source.isLocalPublication = true
        return source
    }
    func testPoisonedCacheIsRejectedAndSameRevisionIsDownloadedAgain() async throws {
        let good = try localSnapshot(), box = CatalogTestBox()
        var bad = good; bad.manifest.shaders[0].name = "Unexpected title"
        try box.storage.write("snapshot.json", JSONEncoder().encode(bad))
        let service = CatalogService(source: try source(good, box: box), storage: box.storage)
        let cached = await service.current()
        XCTAssertNil(cached)
        let recovered = try await service.refresh()
        XCTAssertEqual(recovered?.publicationRevision, good.publicationRevision)
        XCTAssertEqual(recovered?.shaders[0].title, good.manifest.shaders[0].name)
        XCTAssertTrue(box.urls.contains { $0.lastPathComponent == "catalog.json" })
        let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: XCTUnwrap(box.files["snapshot.json"]))
        XCTAssertEqual(persisted.manifest.shaders[0].name, good.manifest.shaders[0].name)
    }
    func testHealthyLocalCacheWorksOfflineAndUnchangedRefreshSkipsAssets() async throws {
        let snapshot = try localSnapshot(), box = CatalogTestBox()
        try box.storage.write("snapshot.json", JSONEncoder().encode(snapshot))
        var network = box.source; network.isLocalPublication = true
        let offline = CatalogService(source: network, storage: box.storage, enabled: false)
        let cached = await offline.current()
        XCTAssertEqual(cached?.publicationRevision, snapshot.publicationRevision)
        XCTAssertTrue(box.urls.isEmpty)
        let online = CatalogService(source: try source(snapshot, box: box), storage: box.storage)
        let outcome = try await online.refreshOutcome()
        guard case .unchanged = outcome else { return XCTFail("Healthy identity must retain unchanged shortcut") }
        XCTAssertEqual(box.urls, [.head])
    }
    func testLegacyCommitCacheRemainsCompatibleWithLocalSource() async throws {
        let box = CatalogTestBox()
        var network = box.source; network.isLocalPublication = true
        let service = CatalogService(source: network, storage: TestCatalog.storage, enabled: false)
        let value = await service.current()
        XCTAssertEqual(value?.publicationRevision, TestCatalog.snapshot.publicationRevision)
    }
    func testChangedNetworkMetadataOrSourceRevisionCannotReplaceGoodSnapshot() async throws {
        let good = try localSnapshot()
        for changesRevision in [false, true] {
            let box = CatalogTestBox()
            var bad = good
            bad.manifest.shaders[0].name = "Next publication"
            let nextRevision = try CatalogPublication.revision(for: bad.manifest)
            bad.publicationRevision = nextRevision; bad.manifest.sourceRevision = nextRevision
            if changesRevision { bad.manifest.sourceRevision = String(repeating: "f", count: 64) }
            else { bad.manifest.shaders[0].name = "Unexpected title" }
            try box.storage.write("snapshot.json", JSONEncoder().encode(good))
            let service = CatalogService(source: try source(bad, box: box), storage: box.storage)
            do { _ = try await service.refresh(); XCTFail("Inconsistent publication accepted") }
            catch CatalogError.invalidManifest {}
            let value = await service.current()
            XCTAssertEqual(value?.publicationRevision, good.publicationRevision)
            let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: XCTUnwrap(box.files["snapshot.json"]))
            XCTAssertEqual(persisted.publicationRevision, good.publicationRevision)
        }
    }
    func testInvalidInjectedInitialCatalogIsNeverActivated() throws {
        var bad = try localSnapshot(); bad.manifest.shaders[0].name = "Unexpected title"
        var source = CatalogSource.unavailable; source.isLocalPublication = true
        let service = CatalogService(initialCatalog: try bad.validated(), source: source, storage: .disabled)
        XCTAssertNil(service.initialCatalog)
    }
    func testFingerprintMatchesPreviousAlgorithmAndIgnoresSelfReference() throws {
        var manifest = try localSnapshot().manifest
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        json["sourceRevision"] = nil
        let expected = CatalogHash.sha256(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        XCTAssertEqual(try CatalogPublication.revision(for: manifest), expected)
        manifest.sourceRevision = String(repeating: "f", count: 64)
        XCTAssertEqual(try CatalogPublication.revision(for: manifest), expected)
    }
    func testFinalEncodedManifestSizeBoundary() throws {
        var manifest = TestCatalog.snapshot.manifest
        manifest.shaders = [manifest.shaders[0]]; manifest.collections = nil
        manifest.shaders[0].description = "x"
        let base = try CatalogPublication.encodedManifest(manifest).count
        let padding = 2_097_152 - base
        // Combining marks keep this valid under the grapheme-count metadata limit.
        manifest.shaders[0].description += String(repeating: "\u{0300}", count: padding / 2)
        if padding % 2 != 0 { manifest.shaders[0].description += "a" }
        try manifest.validate()
        XCTAssertEqual(try CatalogPublication.encodedManifest(manifest).count, 2_097_152)
        manifest.shaders[0].description += "a"
        try manifest.validate()
        XCTAssertThrowsError(try CatalogPublication.encodedManifest(manifest))
    }
}
