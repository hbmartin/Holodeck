import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class CatalogCancellationTests: XCTestCase {
    private func flight() throws -> (CatalogService, CatalogTestBox, RefreshGate, XCTestExpectation) {
        let box = CatalogTestBox()
        let candidate = CatalogTestFixtures.candidate(ninth: true)
        _ = try CatalogTestFixtures.makeService(candidate, box: box)
        let started = expectation(description: "Service download starts")
        let gate = RefreshGate(started: started)
        addTeardownBlock { await gate.release() }
        let network = box.network
        let service = CatalogService(initialCatalog: TestCatalog.catalog, network: .init { url, limit in
            if url.host == "api.github.com" { await gate.hold() }
            return try await network.get(url, limit)
        }, storage: box.storage)
        return (service, box, gate, started)
    }

    private func waitForWaiters(_ count: Int, in service: CatalogService) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await service.refreshWaiterCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Refresh waiter registration timed out")
                throw CancellationTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func result(of task: Task<ValidatedCatalog?, Error>) async throws -> Result<ValidatedCatalog?, Error> {
        let completed = expectation(description: "Refresh caller completes promptly")
        let observer = Task { let result = await task.result; completed.fulfill(); return result }
        let outcome = await XCTWaiter.fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(outcome, .completed)
        guard outcome == .completed else { throw CancellationTestError.timedOut }
        return await observer.value
    }

    private func assertCancelled(_ result: Result<ValidatedCatalog?, Error>) {
        guard case .failure(let error) = result else { return XCTFail("Cancelled caller must fail") }
        XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }

    func testAlreadyCancelledCallerDoesNotStartDownload() async throws {
        let box = CatalogTestBox()
        let service = try CatalogTestFixtures.makeService(CatalogTestFixtures.candidate(), box: box)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.refresh()
        }
        assertCancelled(try await result(of: task))
        XCTAssertTrue(box.urls.isEmpty)
        XCTAssertTrue(box.storageWrites.isEmpty)
    }

    func testOneCancelledCallerDoesNotCancelSharedDownload() async throws {
        let (service, box, gate, started) = try flight()
        let cancelled = Task { try await service.refresh() }
        await fulfillment(of: [started], timeout: 3)
        let survivor = Task { try await service.refresh(force: true) }
        try await waitForWaiters(2, in: service)
        cancelled.cancel()
        assertCancelled(try await result(of: cancelled))
        XCTAssertTrue(box.storageWrites.isEmpty, "Cancellation completes while the download is still held")
        await gate.release()
        let downloaded = try await result(of: survivor).get()
        XCTAssertEqual(downloaded?.shaders.count, 9)
        XCTAssertEqual(box.urls.filter { $0.host == "api.github.com" }.count, 1)
        XCTAssertEqual(box.storageWrites, ["snapshot.json"])
    }

    func testFlightSurvivesAllCallersLeavingAndNewCallerJoins() async throws {
        let (service, box, gate, started) = try flight()
        let first = Task { try await service.refresh() }
        await fulfillment(of: [started], timeout: 3)
        first.cancel()
        assertCancelled(try await result(of: first))
        try await waitForWaiters(0, in: service)
        let later = Task { try await service.refresh(force: true) }
        try await waitForWaiters(1, in: service)
        await gate.release()
        let downloaded = try await result(of: later).get()
        XCTAssertEqual(downloaded?.shaders.count, 9)
        XCTAssertEqual(box.urls.filter { $0.host == "api.github.com" }.count, 1)
        XCTAssertEqual(box.storageWrites, ["snapshot.json"])
    }

    func testNoWaitersStillPublishesAndCancellationCompletionRaceResolvesOnce() async throws {
        for iteration in 0..<20 {
            let (service, box, gate, started) = try flight()
            let task = Task { try await service.refresh() }
            await fulfillment(of: [started], timeout: 3)
            if iteration.isMultiple(of: 2) {
                task.cancel()
                assertCancelled(try await result(of: task))
                try await waitForWaiters(0, in: service)
                await gate.release()
            } else {
                async let release: Void = gate.release()
                task.cancel()
                _ = try await result(of: task)
                await release
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while await service.current()?.shaders.count != 9 {
                guard ContinuousClock.now < deadline else { throw CancellationTestError.timedOut }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(box.storageWrites, ["snapshot.json"])
            let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: XCTUnwrap(box.files["snapshot.json"]))
            XCTAssertEqual(try persisted.validated().shaders.count, 9)
        }
    }

    func testViewerShutdownDetachesWithoutStoppingCachePublication() async throws {
        let (service, box, gate, started) = try flight()
        let viewer = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .mac)
        let refresh = viewer.refresh()
        await fulfillment(of: [started], timeout: 3)
        viewer.shutdown()
        let stopped = expectation(description: "Viewer shutdown finishes its refresh wait")
        Task { await refresh.value; stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertFalse(viewer.isRefreshing)
        XCTAssertEqual(viewer.shaders.count, 8)
        XCTAssertTrue(box.storageWrites.isEmpty)
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while await service.current()?.shaders.count != 9 {
            guard ContinuousClock.now < deadline else { throw CancellationTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(box.storageWrites, ["snapshot.json"])
        XCTAssertEqual(viewer.shaders.count, 8, "A closed viewer does not apply the background result")
    }
}

private enum CancellationTestError: Error { case timedOut }
