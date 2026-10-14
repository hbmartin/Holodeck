import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class CatalogWorkerRecoveryTests: XCTestCase {
    private func fixture(_ box: CatalogTestBox) throws -> (Data, ValidatedCatalog, CatalogSource) {
        let bytes = try CatalogPublication.encodedManifest(TestCatalog.snapshot.manifest), revision = CatalogHash.sha256(bytes)
        let builder = try CatalogPublication.builder(bytes, revision: revision, kind: .localPublication)
        let value = try CatalogPublication.finish(builder, sources: TestCatalog.snapshot.sources.mapValues { Data($0.utf8) }, revision: revision)
        var responses = ["/head": try JSONEncoder().encode(CatalogHead(revision: revision)), "/catalog.json": bytes]
        for (id, source) in TestCatalog.snapshot.sources { responses["/sources/\(id).metal"] = Data(source.utf8) }
        box.setResponses(responses)
        return (bytes, value, CatalogSource(kind: .localPublication, get: box.source.get))
    }
    func testColdRestorationIsSharedServiceOwnedAndLeavesActorResponsive() async throws {
        let box = CatalogTestBox(), (_, good, network) = try fixture(box)
        try box.storage.write("snapshot.json", CatalogPublication.persisted(good, kind: .localPublication))
        let service = CatalogService(source: network, storage: box.storage), gate = CatalogValidationGate()
        defer { gate.release() }
        await service.setBeforeCatalogValidation { gate.hold() }
        let first = Task { await service.current() }, second = Task { await service.current() }
        try await waitForGate(gate); first.cancel()
        let responsive = expectation(description: "Actor state readable during disk verification")
        let query = Task { let count = await service.previewFailureCount; XCTAssertEqual(count, 0); responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        gate.release(); await query.value
        let a = await first.value, b = await second.value
        XCTAssertEqual(a?.publicationRevision, good.publicationRevision); XCTAssertEqual(b?.publicationRevision, good.publicationRevision)
        XCTAssertEqual(box.storageReads, ["snapshot.json"])
        _ = await service.current(); XCTAssertEqual(box.storageReads.count, 1)
        XCTAssertFalse(gate.timedOut)
    }
    func testDownloadValidationServesOldCatalogUntilCandidateFinishes() async throws {
        let box = CatalogTestBox(), (wire, good, network) = try fixture(box)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any]); json["futureOptional"] = true
        let next = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), revision = CatalogHash.sha256(next)
        var responses = box.responseFiles
        responses["/head"] = try JSONEncoder().encode(CatalogHead(revision: revision)); responses["/catalog.json"] = next
        box.setResponses(responses)
        let service = CatalogService(initialCatalog: good, source: network, storage: box.storage), gate = CatalogValidationGate()
        defer { gate.release() }
        await service.setBeforeCatalogValidation { gate.hold() }
        let refresh = Task { try await service.refresh() }
        try await waitForGate(gate)
        let responsive = expectation(description: "Existing publication available during new manifest validation")
        let query = Task { let current = await service.current(); XCTAssertEqual(current?.publicationRevision, good.publicationRevision); responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        XCTAssertEqual(box.urls.count, 2)
        gate.release(); await query.value
        let result = try await refresh.value; XCTAssertEqual(result?.publicationRevision, revision)
        XCTAssertFalse(gate.timedOut)
    }
    func testDeletionFailureNeverActivatesOldSnapshotAndRefreshReplacesIt() async throws {
        let box = CatalogTestBox(), (_, good, network) = try fixture(box)
        try box.storage.write("snapshot.json", TestCatalog.data)
        let storage = CatalogStorage(read: box.storage.read, write: box.storage.write, remove: { _ in throw POSIXError(.EACCES) })
        let service = CatalogService(source: network, storage: storage)
        let old = await service.current(); XCTAssertNil(old)
        XCTAssertEqual(box.files["snapshot.json"], TestCatalog.data)
        let new = try await service.refresh(); XCTAssertEqual(new?.publicationRevision, good.publicationRevision)
        XCTAssertNoThrow(try CatalogPublication.restored(XCTUnwrap(box.files["snapshot.json"]), kind: .localPublication))
    }
    private func waitForGate(_ gate: CatalogValidationGate) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.entered { guard ContinuousClock.now < deadline else { throw LocalCatalogError.timeout }; await Task.yield() }
    }
}

private final class CatalogValidationGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var holding = false, expired = false
    var entered: Bool { lock.withLock { holding } }
    var timedOut: Bool { lock.withLock { expired } }
    func hold() {
        lock.withLock { holding = true }
        if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
    }
    func release() { semaphore.signal() }
}
