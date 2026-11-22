#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRecoveryOwnershipTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr51-ownership-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func accept(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await registration.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Recovery ownership backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testLocalPreparationStartsWhileRegistrationHoldsTrustedRead() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate(), read = TrustedReadGate()
        addTeardownBlock { read.release(); await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } }), b = try await fixture()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        backend.gateReads(read)
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: b))
        addTeardownBlock { registration.completion.cancel(); read.release() }
        try await wait { read.entered }; armed.on = true
        let recovery = Task { try await a.retryReconciliation() }
        addTeardownBlock { recovery.cancel(); read.release(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        XCTAssertTrue(read.entered)
        let held = await authority.observation
        XCTAssertTrue(held.transitionActive)
        armed.on = false; await repairing.release(); read.release(); backend.gateReads(nil)
        _ = try await accept(registration); try await recovery.value
        XCTAssertEqual(backend.writes, 0)
    }
    func testHandoffWaitsForMetadataButNotTrustedResultHold() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate()
        addTeardownBlock { await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let old = TrustedBackendFixture(nil).coordinator(), next = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a)))
        armed.on = true; let pass = UUID()
        let local = Task { try await a.trustedRecoveryOutcome(pass: pass) }
        addTeardownBlock { local.cancel(); await repairing.release(); await a.finishTrustedRecovery(pass: pass) }
        try await wait { await repairing.hasEntered }
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel(); await repairing.release() }
        try await wait { await a.localPreparationWaiters == 1 }
        let pending = await next.observation; XCTAssertNil(pending.acceptedGeneration)
        armed.on = false; await repairing.release()
        let outcome = try await local.value
        XCTAssertEqual(outcome.receipt?.authority, old.id)
        _ = try await accept(registration)
        let checked = await a.validateTrustedRecovery(outcome)
        XCTAssertFalse(checked.completed)
        let accepted = await next.observation; XCTAssertEqual(accepted.targets, 1)
        await a.finishTrustedRecovery(pass: pass)
    }
    func testInitialBindingAlsoWaitsForUnboundLocalPreparation() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate()
        addTeardownBlock { await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } }), authority = TrustedBackendFixture(nil).coordinator()
        armed.on = true
        let local = Task { try await a.trustedRecoveryOutcome() }
        addTeardownBlock { local.cancel(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel(); await repairing.release() }
        try await wait { await a.localPreparationWaiters == 1 }
        armed.on = false; await repairing.release()
        let outcome = try await local.value
        XCTAssertNil(outcome.receipt?.authority)
        _ = try await accept(registration)
        let checked = await a.validateTrustedRecovery(outcome); XCTAssertFalse(checked.completed)
    }
    func testAdmittedRemovalCompletesBeforeTargetMetadataPreparation() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate(), writing = TrustedReadGate()
        addTeardownBlock { writing.release(); await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { data in writing.wait(); try backend.write(data) })
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let replay = Task { try await authority.replay() }
        addTeardownBlock { replay.cancel(); writing.release() }
        try await wait { writing.entered }; armed.on = true
        let before = await a.localRecoveryPhaseCount
        let local = Task { try await a.recoverDepartureLocal() }
        addTeardownBlock { local.cancel(); writing.release(); await repairing.release() }
        try await wait { await a.localRecoveryPhaseCount == before + 1 }
        let started = await repairing.hasEntered; XCTAssertFalse(started)
        writing.release(); try await replay.value
        try await wait { await repairing.hasEntered }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        armed.on = false; await repairing.release()
        let completed = try await local.value; XCTAssertTrue(completed.completed)
        XCTAssertEqual(backend.writes, 1)
    }
}
private final class RecoveryOwnershipSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
