import XCTest
@testable import HolodeckCore

@MainActor
final class CatalogRefreshOutcomeTests: XCTestCase {
    func testExplicitOutcomesAndCompatibilityWrapper() async throws {
        let box = CatalogTestBox()
        let service = try CatalogTests().makeService(TestCatalog.snapshot, box: box)
        guard case .unchanged = try await service.refreshOutcome() else { return XCTFail("Expected checked publication") }
        guard case .throttled = try await service.refreshOutcome() else { return XCTFail("Expected skipped check") }
        XCTAssertEqual(box.urls.count, 1)
        guard case .unchanged = try await service.refreshOutcome(force: true) else { return XCTFail("Force must check") }
        XCTAssertEqual(box.urls.count, 2)
        let compatible = try await service.refresh()
        XCTAssertNil(compatible)
        guard case .disabled = try await CatalogService.offline().refreshOutcome(force: true) else { return XCTFail("Expected disabled") }

        let expected = CatalogTests().candidate()
        _ = try CatalogTests().makeService(expected, box: box)
        guard case .updated(let updated) = try await service.refreshOutcome(force: true) else { return XCTFail("Expected update") }
        XCTAssertEqual(updated.publicationRevision, expected.publicationRevision)
        let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: XCTUnwrap(box.files["snapshot.json"]))
        XCTAssertEqual(persisted.publicationRevision, expected.publicationRevision)
    }

    func testFailedCheckNoticeSurvivesThrottleAndClearsOnlyAfterSuccessfulCheck() async throws {
        let box = CatalogTestBox()
        let service = CatalogService(initialCatalog: TestCatalog.catalog, network: box.network, storage: .disabled, clock: box.clock)
        let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .mac)
        await session.refresh().value
        let failure = try XCTUnwrap(session.catalogUpdateFailure)
        box.setResponses(["/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(TestCatalog.catalog.publicationRevision)\"}}".utf8)])
        let skipped = session.refresh()
        XCTAssertEqual(session.catalogUpdateFailure?.id, failure.id, "Starting a refresh must retain the notice")
        await skipped.value
        XCTAssertEqual(session.catalogUpdateFailure?.id, failure.id)
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(899))
        await session.refresh().value
        XCTAssertEqual(session.catalogUpdateFailure?.id, failure.id)
        XCTAssertEqual(box.urls.count, 1)
        await box.clock.advance(by: .seconds(1))
        await session.refresh().value
        XCTAssertNil(session.catalogUpdateFailure)
        XCTAssertEqual(box.urls.count, 2)

        box.setResponses([:])
        await session.refresh(force: true).value
        XCTAssertNotNil(session.catalogUpdateFailure)
        let expected = CatalogTests().candidate()
        _ = try CatalogTests().makeService(expected, box: box)
        await session.refresh(force: true).value
        XCTAssertNil(session.catalogUpdateFailure)
        XCTAssertEqual(session.catalog?.publicationRevision, expected.publicationRevision)
    }

    func testDisabledCheckRetainsNoticeAndReactivationPolicyRequiresTVRenderer() async {
        let disabled = ViewerSession(catalogService: .offline(initialCatalog: TestCatalog.catalog), preferences: .inMemory(), policy: .mac)
        let failure = ViewerSession.Failure(message: "Last check failed", operation: .catalog)
        disabled.failure = failure
        await disabled.refresh().value
        XCTAssertEqual(disabled.catalogUpdateFailure?.id, failure.id)
        let empty = ViewerSession(catalogService: .offline(), preferences: .inMemory(), policy: .mac)
        await empty.refresh().value
        let initialFailure = empty.failure?.id
        XCTAssertNotNil(initialFailure)
        await empty.refresh().value
        XCTAssertEqual(empty.failure?.id, initialFailure)
        for cached in [false, true] {
            for policy in [ViewerPolicy.tv, .mac, ViewerPolicy(restoresLastScene: false, replacesUpdatedScene: false)] {
                let box = CatalogTestBox()
                let service = CatalogService(initialCatalog: cached ? TestCatalog.catalog : nil, network: box.network, storage: .disabled)
                let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: policy)
                session.setActive(true)
                XCTAssertNil(session.refreshTask)
                session.setActive(false)
                session.setActive(true)
                await session.refreshTask?.value
                XCTAssertEqual(box.urls.count, policy.refreshesWithoutRenderer ? 1 : 0)
            }
        }
    }

    func testOutcomeCallersCoalesceAndCancelIndependently() async throws {
        let started = expectation(description: "One shared check begins")
        let gate = OutcomeRefreshGate(started: started)
        addTeardownBlock { await gate.release() }
        let service = CatalogService(initialCatalog: TestCatalog.catalog, network: CatalogNetwork { _, _ in
            await gate.hold()
            return Data("{\"object\":{\"sha\":\"\(TestCatalog.catalog.publicationRevision)\"}}".utf8)
        }, storage: .disabled)
        let first = Task { try await service.refreshOutcome() }
        await fulfillment(of: [started], timeout: 3)
        let second = Task { try await service.refreshOutcome(force: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await service.refreshWaiterCount != 2 {
            guard ContinuousClock.now < deadline else { return XCTFail("Waiters did not register") }
            await Task.yield()
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        await gate.release()
        guard case .unchanged = try await second.value else { return XCTFail("Surviving caller must receive checked outcome") }
    }
}

private actor OutcomeRefreshGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(started: XCTestExpectation) { self.started = started }
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
