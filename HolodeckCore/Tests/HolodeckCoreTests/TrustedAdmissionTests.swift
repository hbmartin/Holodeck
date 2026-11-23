#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedAdmissionTests: XCTestCase {
    private func fixture() async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr48-admission-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Admission test backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testBothReplayDependenciesProgressPastPendingOpposingReplacements() async throws {
        let a = try await fixture(), b = try await fixture(), firstGate = RecoveryGate(), secondGate = RecoveryGate()
        addTeardownBlock { await firstGate.release(); await secondGate.release() }
        let firstIntent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let secondIntent = RequestRevocationIntent(operationID: UUID(), deviceID: "B")
        let firstBackend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [firstIntent]).encoded())
        let secondBackend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [secondIntent]).encoded())
        let first = firstBackend.coordinator(), second = secondBackend.coordinator()
        _ = try await accept(first.register(TrustedOwnerRecorder().owner(service: a, beforeReplay: { _ in try await firstGate.wait() })))
        _ = try await accept(second.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in try await secondGate.wait() })))
        let movingA = try await second.register(TrustedOwnerRecorder().owner(service: a))
        try await wait { await firstGate.hasEntered }
        let movingB = try await first.register(TrustedOwnerRecorder().owner(service: b))
        try await wait { await secondGate.hasEntered }
        try await wait { await first.observation.departures == 1 }
        try await wait { await second.observation.departures == 1 }
        let latestFirst = try await first.register(TrustedOwnerRecorder().owner())
        let latestSecond = try await second.register(TrustedOwnerRecorder().owner())
        addTeardownBlock { [movingA, movingB, latestFirst, latestSecond].forEach { $0.completion.cancel() } }
        let heldFirst = await first.observation, heldSecond = await second.observation
        XCTAssertEqual(heldFirst.queuedGeneration, latestFirst.generation); XCTAssertEqual(heldSecond.queuedGeneration, latestSecond.generation)
        XCTAssertLessThanOrEqual(heldFirst.departures, 1); XCTAssertLessThanOrEqual(heldSecond.departures, 1)
        let result = AdmissionResult()
        let completion = Task {
            do {
                guard case .superseded = try await movingA.value(), case .superseded = try await movingB.value() else { throw ShaderRequestError.invalidRequest }
                _ = try await self.accept(latestFirst); _ = try await self.accept(latestSecond)
                await result.finish(nil)
            } catch { await result.finish(error) }
        }
        addTeardownBlock { completion.cancel() }
        await firstGate.release(); await secondGate.release()
        try await wait { await result.finished }; try await result.check()
        try await wait { await first.observation.departures == 0 }; try await wait { await second.observation.departures == 0 }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(firstBackend.read())).revocations.isEmpty)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(secondBackend.read())).revocations.isEmpty)
    }
    func testReadyRevocationsUnblockOpposingDeparturePreparations() async throws {
        let a = try await fixture(), b = try await fixture()
        let bytes = try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()
        let firstBackend = TrustedBackendFixture(bytes), secondBackend = TrustedBackendFixture(bytes)
        let firstPreparation = RecoveryGate(), secondPreparation = RecoveryGate()
        let firstReservation = RecoveryGate(), secondReservation = RecoveryGate()
        addTeardownBlock {
            await firstPreparation.release(); await secondPreparation.release()
            await firstReservation.release(); await secondReservation.release()
        }
        let first = TrustedApprovalsCoordinator(read: { try firstBackend.checkedRead() }, write: { try firstBackend.write($0) },
            beforeReservation: { _ in try await firstReservation.wait() },
            beforeAuthorityPreparation: { id in if id == b.runtimeID { try await firstPreparation.wait() } })
        let second = TrustedApprovalsCoordinator(read: { try secondBackend.checkedRead() }, write: { try secondBackend.write($0) },
            beforeReservation: { _ in try await secondReservation.wait() },
            beforeAuthorityPreparation: { id in if id == a.runtimeID { try await secondPreparation.wait() } })
        let initialFirst = try await accept(first.register(TrustedOwnerRecorder().owner(service: a)))
        let initialSecond = try await accept(second.register(TrustedOwnerRecorder().owner(service: b)))
        let movingA = try await second.register(TrustedOwnerRecorder().owner(service: a))
        let movingB = try await first.register(TrustedOwnerRecorder().owner(service: b))
        try await wait { await firstPreparation.hasEntered }
        try await wait { await secondPreparation.hasEntered }
        let latestFirst = try await first.register(TrustedOwnerRecorder().owner())
        let latestSecond = try await second.register(TrustedOwnerRecorder().owner())
        let firstRevocation = Task { try await first.revoke("B", permit: initialFirst.permit) { _ in } }
        let secondRevocation = Task { try await second.revoke("B", permit: initialSecond.permit) { _ in } }
        addTeardownBlock { firstRevocation.cancel(); secondRevocation.cancel(); [movingA, movingB, latestFirst, latestSecond].forEach { $0.completion.cancel() } }
        // Witness both admitted revocations while preparation is suspended at
        // its real boundary. No cooperative worker or service actor is blocked.
        try await wait { await firstReservation.hasEntered }
        try await wait { await secondReservation.hasEntered }
        let heldFirst = await first.observation, heldSecond = await second.observation
        XCTAssertEqual(heldFirst.queuedGeneration, latestFirst.generation); XCTAssertEqual(heldSecond.queuedGeneration, latestSecond.generation)
        XCTAssertEqual(firstBackend.writes, 0); XCTAssertEqual(secondBackend.writes, 0)
        let result = AdmissionResult()
        let completion = Task {
            do {
                try await firstRevocation.value; try await secondRevocation.value
                guard case .superseded = try await movingA.value(), case .superseded = try await movingB.value() else { throw ShaderRequestError.invalidRequest }
                _ = try await self.accept(latestFirst); _ = try await self.accept(latestSecond)
                await result.finish(nil)
            } catch { await result.finish(error) }
        }
        addTeardownBlock { completion.cancel() }
        await firstPreparation.release(); await secondPreparation.release()
        await firstReservation.release(); await secondReservation.release()
        try await wait { await result.finished }; try await result.check()
        let finalFirst = await first.observation, finalSecond = await second.observation
        XCTAssertEqual(finalFirst.queuedRevocations, 0); XCTAssertEqual(finalSecond.queuedRevocations, 0)
        XCTAssertEqual(firstBackend.writes, 2); XCTAssertEqual(secondBackend.writes, 2)
    }
}
private actor AdmissionResult {
    private(set) var finished = false
    private var error: Error?
    func finish(_ error: Error?) { self.error = error; finished = true }
    func check() throws { if let error { throw error } }
}
#endif
