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
        await gate.release()
        do { try await first.value; XCTFail("Old pass accepted a superseded proof") } catch is TrustedPartialRecovery {}
        try await second.value
        let after = await authority.observation
        XCTAssertEqual(after.recoveryPasses, before + 2); XCTAssertEqual(after.successorParticipants, 0)
        XCTAssertEqual(after.obligations, 0)
    }
    func testImmediateLateLocalFailureKeepsIntentUntilSuccessorRepairsIt() async throws {
        let failure = AdmissionFailureSwitch(), gate = RecoveryGate()
        let a = try await fixture(), b = try await fixture(reconcile: { _ in if failure.on { throw POSIXError(.EIO) } })
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in try await gate.wait() })))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        let first = Task { try await a.retryReconciliation() }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        failure.on = true
        let late = Task { try await b.retryReconciliation() }
        addTeardownBlock { late.cancel(); await gate.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        await gate.release()
        do { try await first.value; XCTFail("Active pass ignored changed target evidence") }
        catch let error as TrustedPartialRecovery { XCTAssertFalse(error.completedServices.contains(b.runtimeID)) }
        do { try await late.value; XCTFail("Failed local phase reported recovered") }
        catch let error as TrustedPartialRecovery { XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription)) }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        failure.on = false; try await b.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testLateSuccessfulReceiptClearsOnlyItsPreviousSuppression() async throws {
        let armed = AdmissionFailureSwitch(), oldPhase = AdmissionCompletionGate(), seal = RecoveryGate(), sealArmed = AdmissionFailureSwitch()
        let a = try await fixture(reconcile: { _ in if armed.on { await oldPhase.wait() } }), b = try await fixture()
        let backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeRecoverySealing: { if sealArmed.on { try await seal.wait() } })
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in throw POSIXError(.EIO) })))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Injected application failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b)))
        armed.on = true
        let cancelled = Task { try await a.retryReconciliation() }
        addTeardownBlock { cancelled.cancel(); await oldPhase.release(); await seal.release() }
        try await wait { await oldPhase.entered }; cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled phase succeeded") } catch is CancellationError {}
        sealArmed.on = true
        let first = Task { try await b.retryReconciliation() }
        addTeardownBlock { first.cancel(); await oldPhase.release(); await seal.release() }
        try await wait { await seal.hasEntered }
        armed.on = false; await oldPhase.release()
        try await wait { await a.canDisableRequests() }
        let late = Task { try await a.retryReconciliation() }
        addTeardownBlock { late.cancel(); await seal.release() }
        try await wait { await authority.observation.recoveryParticipants == 2 }
        await seal.release(); try await first.value; try await late.value
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testSuccessorWaitsForCancelledPredecessorsOwnedLocalSettlement() async throws {
        let armed = AdmissionFailureSwitch(), settling = AdmissionCompletionGate()
        let a = try await fixture(), b = try await fixture(reconcile: { _ in if armed.on { await settling.wait() } }), c = try await fixture()
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: b)))
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: c, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Injected replay fault ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: c)))
        armed.on = true
        let first = Task { try await a.retryReconciliation() }
        addTeardownBlock { first.cancel(); await settling.release() }
        try await wait { await settling.entered }
        first.cancel()
        do { try await first.value; XCTFail("Cancelled caller succeeded") } catch is CancellationError {}
        let passes = await authority.observation.recoveryPasses, reads = backend.reads
        let next = Task { try await c.retryReconciliation() }
        addTeardownBlock { next.cancel(); await settling.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        let pending = await authority.observation
        XCTAssertEqual(pending.recoveryPasses, passes); XCTAssertEqual(backend.reads, reads)
        armed.on = false; await settling.release(); try await next.value
        let final = await authority.observation
        XCTAssertEqual(final.recoveryPasses, passes + 1); XCTAssertEqual(final.obligations, 0)
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
        await gate.release()
        do { try await first.value; XCTFail("Old pass accepted invalidated evidence") } catch is TrustedPartialRecovery {}
        XCTAssertFalse(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        try await b.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
}
private final class AdmissionFailureSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
private actor AdmissionCompletionGate {
    private(set) var entered = false; private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; if open { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
#endif
