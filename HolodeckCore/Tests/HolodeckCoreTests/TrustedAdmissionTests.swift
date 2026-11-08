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
        let latestFirst = try await first.register(TrustedOwnerRecorder().owner())
        let latestSecond = try await second.register(TrustedOwnerRecorder().owner())
        addTeardownBlock { [movingA, movingB, latestFirst, latestSecond].forEach { $0.completion.cancel() } }
        let heldFirst = await first.observation, heldSecond = await second.observation
        XCTAssertEqual(heldFirst.queuedGeneration, latestFirst.generation); XCTAssertEqual(heldSecond.queuedGeneration, latestSecond.generation)
        XCTAssertEqual(heldFirst.departures, 1); XCTAssertEqual(heldSecond.departures, 1)
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
        let first = firstBackend.coordinator(), second = secondBackend.coordinator()
        let initialFirst = try await accept(first.register(TrustedOwnerRecorder().owner(service: a)))
        let initialSecond = try await accept(second.register(TrustedOwnerRecorder().owner(service: b)))
        // Hold only the service actors, not either authority lane. This witnesses
        // both registration drivers awaiting source preparation before queueing replacements.
        let aGate = AdmissionActorGate(), bGate = AdmissionActorGate()
        addTeardownBlock { aGate.release(); bGate.release() }
        let heldA = Task.detached { await holdAdmissionActor(a, gate: aGate) }
        let heldB = Task.detached { await holdAdmissionActor(b, gate: bGate) }
        try await wait { aGate.entered && bGate.entered }
        let movingA = try await second.register(TrustedOwnerRecorder().owner(service: a))
        let movingB = try await first.register(TrustedOwnerRecorder().owner(service: b))
        try await wait { await first.observation.preparingGeneration == movingB.generation }
        try await wait { await second.observation.preparingGeneration == movingA.generation }
        let latestFirst = try await first.register(TrustedOwnerRecorder().owner())
        let latestSecond = try await second.register(TrustedOwnerRecorder().owner())
        let firstRevocation = Task { try await first.revoke("B", permit: initialFirst.permit) { _ in } }
        let secondRevocation = Task { try await second.revoke("B", permit: initialSecond.permit) { _ in } }
        addTeardownBlock { firstRevocation.cancel(); secondRevocation.cancel(); [movingA, movingB, latestFirst, latestSecond].forEach { $0.completion.cancel() } }
        // Ready revocations can already be admitted: they no longer wait behind
        // pending registrations. Actor holds keep their target notifications gated.
        try await wait { await first.observation.transitionActive }
        try await wait { await second.observation.transitionActive }
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
        aGate.release(); bGate.release(); await heldA.value; await heldB.value
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
private final class AdmissionActorGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false, reached = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return reached }
    func wait() {
        condition.lock(); defer { condition.unlock() }; reached = true
        let deadline = Date().addingTimeInterval(12)
        while !open { if !condition.wait(until: deadline) { return } }
    }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
}
private func holdAdmissionActor(_ service: isolated ShaderRequestService, gate: AdmissionActorGate) { gate.wait() }
#endif
