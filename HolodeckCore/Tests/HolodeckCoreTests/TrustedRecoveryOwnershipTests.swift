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
        guard case .accepted(let binding) = try await completed({ try await registration.value() }) else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Recovery ownership backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func completed<Value: Sendable>(_ body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let result = RecoveryOwnershipCompletion<Value>()
        let task = Task {
            do { result.value = .success(try await body()) }
            catch { result.value = .failure(error) }
        }
        addTeardownBlock { task.cancel() }
        try await wait { result.value != nil }
        return try XCTUnwrap(result.value).get()
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
        _ = try await accept(registration); try await completed { try await recovery.value }
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
        let outcome = try await completed { try await local.value }
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
        let outcome = try await completed { try await local.value }
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
        writing.release(); try await completed { try await replay.value }
        try await wait { await repairing.hasEntered }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        armed.on = false; await repairing.release()
        let outcome = try await completed { try await local.value }; XCTAssertTrue(outcome.completed)
        XCTAssertEqual(backend.writes, 1)
    }
    func testDepartureReusesOwnedLocalOutcomeIncludingFailure() async throws {
        for fail in [false, true] {
            let armed = RecoveryOwnershipSwitch(), callback = RecoveryGate()
            addTeardownBlock { await callback.release() }
            let a = try await fixture(reconcile: { _ in if fail && armed.on { throw POSIXError(.EIO) } })
            _ = await a.registerRevocationCoordinator(id: UUID(), recovery: { _ in try await callback.wait() })
            armed.on = true
            let requester = Task { try await a.retryReconciliation() }
            addTeardownBlock { requester.cancel(); await callback.release() }
            try await wait { await callback.hasEntered }
            let original = try await a.trustedRecoveryOutcome(), phases = await a.localRecoveryPhaseCount
            let departure = try await a.recoverDepartureLocal()
            let validated = await a.validateTrustedRecovery(original)
            XCTAssertEqual(departure.receipt?.attemptID, original.receipt?.attemptID)
            XCTAssertEqual(departure.completed, !fail); XCTAssertEqual(validated.completed, !fail)
            let after = await a.localRecoveryPhaseCount; XCTAssertEqual(after, phases)
            await callback.release()
            if fail {
                do { try await completed { try await requester.value }; XCTFail("Failed local outcome lost") }
                catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
            } else { try await completed { try await requester.value } }
        }
    }
    func testLocalOnlyCompletionDoesNotLeavePreparingApplicationBlocker() async throws {
        let a = try await fixture(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let local = try await a.recoverDepartureLocal(); XCTAssertTrue(local.completed)
        try await authority.replay()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        let observation = await authority.observation
        XCTAssertEqual(observation.obligations, 0); XCTAssertEqual(backend.writes, 1)
    }
    func testLocalOnlyCompletionPreservesIndependentApplicationFailure() async throws {
        let a = try await fixture(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Injected failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let local = try await a.recoverDepartureLocal(); XCTAssertTrue(local.completed)
        do { try await authority.replay(); XCTFail("Unrelated failure was cleared") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await a.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testCancelledLateOutcomeIsRecoveredByAnotherRequester() async throws {
        let a = try await fixture(), b = try await fixture(), requester = try await fixture()
        let gate = RecoveryOwnershipApplicationGate(), backend = TrustedBackendFixture(nil)
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeReplayApplication: { try await gate.call($0) })
        for target in [a, b, requester] { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: target))) }
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        let first = Task { try await requester.retryReconciliation() }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.serviceID != nil }
        let selected = await gate.serviceID
        let lateTarget = selected == a.runtimeID ? b : a
        let late = Task { try await lateTarget.retryReconciliation() }
        addTeardownBlock { late.cancel(); await gate.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        late.cancel()
        do { try await completed { try await late.value }; XCTFail("Cancelled successor succeeded") } catch is CancellationError {}
        try await wait { await authority.observation.successorParticipants == 0 }
        await gate.release()
        do { try await completed { try await first.value }; XCTFail("Old pass accepted the unadmitted outcome") } catch is TrustedPartialRecovery {}
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        let phases = await lateTarget.localRecoveryPhaseCount
        try await requester.retryReconciliation()
        let after = await lateTarget.localRecoveryPhaseCount
        XCTAssertEqual(after, phases + 1)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testRequesterDoesNotReintroduceExcludedTrustedCompletion() async throws {
        let a = try await fixture()
        _ = await a.registerRevocationCoordinator(id: UUID(), recovery: { _ in
            throw TrustedPartialRecovery(completedServices: [], remaining: ["The requester epoch was superseded."])
        })
        do { try await a.retryReconciliation(); XCTFail("Partial result ignored") }
        catch let error as TrustedPartialRecovery {
            XCTAssertFalse(error.completedServices.contains(a.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains("epoch was superseded"))
        }
    }

}
private actor RecoveryOwnershipApplicationGate {
    private(set) var serviceID: UUID?
    private let completion = TrustedCompletionSignal()
    func call(_ service: UUID) async throws {
        guard serviceID == nil else { return }
        serviceID = service; try await completion.wait()
    }
    func release() { completion.finish() }
}
@MainActor private final class RecoveryOwnershipCompletion<Value: Sendable> { var value: Result<Value, Error>? }
private final class RecoveryOwnershipSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
