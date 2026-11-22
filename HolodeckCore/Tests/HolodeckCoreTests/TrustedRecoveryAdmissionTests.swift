#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRecoveryAdmissionTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr50-recovery-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws {
        guard case .accepted = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Recovery admission backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testCancellationClosesAdmissionBeforeCallingTaskCancel() async throws {
        let gap = TrustedReadGate(), work = RecoveryGate()
        addTeardownBlock { gap.release(); await work.release() }
        let shared = TrustedRecoveryTask(beforeCancellation: { gap.wait() }) {
            try await work.wait(); try Task.checkCancellation(); return 42
        }
        let first = shared.subscribe(), waiter = Task { try await first.value() }
        addTeardownBlock { gap.release(); waiter.cancel(); await work.release() }
        try await wait { await work.hasEntered }
        // A dedicated thread holds the cancellation gap; never hold an actor or
        // cooperative-pool thread to orchestrate this synchronous primitive.
        Thread.detachNewThread { waiter.cancel() }
        try await wait { gap.entered }
        XCTAssertTrue(shared.isCancelled)
        do { _ = try await shared.subscribe().value(); XCTFail("Closed task admitted another waiter") }
        catch is TrustedRecoveryTaskClosed {}
        gap.release(); await work.release()
        do { _ = try await waiter.value; XCTFail("Cancelled waiter succeeded") } catch is CancellationError {}
        XCTAssertEqual(shared.waiterCount, 0)
    }
    func testCallerAfterReplaySealingGetsSuccessorPass() async throws {
        let a = try await fixture(), b = try await fixture(), gate = RecoveryGate()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in try await gate.wait() })))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        let before = await authority.observation.recoveryPasses
        let first = Task { try await a.retryReconciliation() }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let second = Task { try await b.retryReconciliation() }
        addTeardownBlock { second.cancel(); await gate.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        let active = await authority.observation; XCTAssertEqual(active.recoveryPasses, before + 1)
        await gate.release(); try await first.value; try await second.value
        let after = await authority.observation
        XCTAssertEqual(after.recoveryPasses, before + 2); XCTAssertEqual(after.successorParticipants, 0)
        XCTAssertEqual(after.obligations, 0)
    }
    func testCancelledSuccessorDoesNotCancelActivePass() async throws {
        let a = try await fixture(), b = try await fixture(), gate = RecoveryGate()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in try await gate.wait() })))
        try backend.write(TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "A")]).encoded())
        let first = Task { try await a.retryReconciliation() }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let second = Task { try await b.retryReconciliation() }
        addTeardownBlock { second.cancel(); await gate.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        second.cancel()
        do { try await second.value; XCTFail("Cancelled successor succeeded") } catch is CancellationError {}
        try await wait { await authority.observation.successorParticipants == 0 }
        await gate.release(); try await first.value
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
}
#endif
