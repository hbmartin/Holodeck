#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRetirementBoundaryTests: XCTestCase {
    private struct Fixture { let service: ShaderRequestService; let root: URL }
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in },
                         beforeWrite: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pr52-retirement-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("worker.py"), reconcileWorker: reconcile,
            beforePersistenceReplacement: beforeWrite)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return Fixture(service: service, root: root)
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Retirement boundary backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func completed<Value: Sendable>(_ body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let result = RetirementResult<Value>()
        let task = Task { do { result.value = .success(try await body()) } catch { result.value = .failure(error) } }
        addTeardownBlock { task.cancel() }
        try await wait { result.value != nil }
        return try XCTUnwrap(result.value).get()
    }
    private func accepted(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await completed({ try await registration.value() }) else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func submit(_ service: ShaderRequestService, device: String = "TV") async throws -> UUID {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader,
            screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4),
            animationTime: 1, width: 1920, height: 1080)
        let request = ShaderRequest(prompt: "Retirement regression", context: context)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: device)
        return request.id
    }
    /// This deliberately injects exceptional departure state; no normal producer is asserted.
    private func exceptional(_ fixture: Fixture, authority: TrustedApprovalsCoordinator) async throws -> TrustedAuthorityDeparture {
        let departure = try await authority.prepareDeparture(fixture.service, ticket: UUID())
        try departure.activate {}
        await authority.retainDepartureRecovery(serviceID: fixture.service.runtimeID, ticket: departure.id)
        return departure
    }
    func testRetirementIgnoresHealthyProgressAndAnUnrelatedCommit() async throws {
        let armed = RetirementSwitch(), writing = TrustedReadGate()
        addTeardownBlock { writing.release() }
        let f = try await fixture(beforeWrite: { if armed.on && $0.lastPathComponent == "journal.json" { writing.wait() } })
        let id = try await submit(f.service), job = f.root.appendingPathComponent(id.uuidString)
        try """
        import json,sys,time
        from pathlib import Path
        p=Path(sys.argv[3]);(p/'started').touch()
        while not (p/'progress').exists():time.sleep(.005)
        print(json.dumps(dict(event='stage',stage='implementing',message='healthy progress')),flush=True)
        while not (p/'release').exists():time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
        """.write(to: f.root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? Data().write(to: job.appendingPathComponent("release")); writing.release() }
        try await f.service.retryReconciliation()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        await f.service.activateScheduling(); await f.service.resume()
        try await wait { FileManager.default.fileExists(atPath: job.appendingPathComponent("started").path) }
        let captured = await f.service.departureRetirementAssessment(); let receipt = try XCTUnwrap(captured)
        try Data().write(to: job.appendingPathComponent("progress"))
        try await wait { await f.service.allJobs().first(where: { $0.id == id })?.message == "healthy progress" }
        let valid = await f.service.validateDepartureRetirement(receipt); XCTAssertTrue(valid)
        try await wait {
            (try? String(contentsOf: f.root.appendingPathComponent("journal.json"), encoding: .utf8))?.contains("healthy progress") == true
        }
        let phases = await f.service.localRecoveryPhaseCount, reads = backend.reads
        armed.on = true
        let queued = Task { try await self.submit(f.service, device: "Other") }
        addTeardownBlock { queued.cancel(); writing.release() }
        try await wait { writing.entered }
        let busy = await f.service.hasPendingStorageChange; XCTAssertTrue(busy)
        let departure = try await exceptional(f, authority: authority)
        try await completed { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        let after = await f.service.localRecoveryPhaseCount, retired = await authority.observation
        XCTAssertEqual(after, phases); XCTAssertEqual(backend.reads, reads); XCTAssertEqual(retired.targets, 0)
        let active = await f.service.allJobs().first(where: { $0.id == id }); XCTAssertEqual(active?.stage, .implementing)
        armed.on = false; writing.release()
        let other = try await completed { try await queued.value }
        try await f.service.cancelQueued(other)
        try Data().write(to: job.appendingPathComponent("release"))
        try await wait { await f.service.allJobs().first(where: { $0.id == id })?.stage == .awaitingClarification }
        try await wait { await !f.service.hasActiveCheckoutWork }
    }
    func testStorageFaultAfterValidationRejectsRetirementAdmission() async throws {
        let armed = RetirementSwitch(), admission = RecoveryGate()
        addTeardownBlock { await admission.release() }
        let f = try await fixture(beforeWrite: { if armed.on && $0.lastPathComponent == "preferences.json" { throw POSIXError(.EIO) } })
        let backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeDepartureRetirementAdmission: { _ in try await admission.wait() })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        try await f.service.retryReconciliation()
        let departure = try await exceptional(f, authority: authority)
        let retiring = Task { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { retiring.cancel(); await admission.release() }
        try await wait { await admission.hasEntered }
        armed.on = true
        do { try await f.service.disable(); XCTFail("Storage fault ignored") } catch is RequestPersistence.Fault {}
        armed.on = false; await admission.release()
        do { try await completed { try await retiring.value }; XCTFail("Stale retirement was admitted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ownership changed before retirement admission")) }
        let retained = await authority.observation
        XCTAssertEqual(retained.targets, 1); XCTAssertEqual(retained.recoverySubscriptions, 1)
        let statuses = await f.service.recoveryStatuses(); XCTAssertTrue(statuses.contains { $0.id == departure.id })
        try await f.service.retryReconciliation()
        let repaired = await authority.observation; XCTAssertEqual(repaired.targets, 0)
    }
    func testRetirementPermitCanBeAdmittedOnlyOnce() async throws {
        let f = try await fixture(); try await f.service.retryReconciliation()
        let captured = await f.service.departureRetirementAssessment(); let receipt = try XCTUnwrap(captured)
        XCTAssertTrue(receipt.admit()); XCTAssertFalse(receipt.admit())
        let refreshed = await f.service.departureRetirementAssessment(); let second = try XCTUnwrap(refreshed)
        XCTAssertFalse(receipt === second); XCTAssertTrue(second.isCurrent)
    }
    func testUnrelatedTrustedRecoveryWaitsForRetainedSettlement() async throws {
        let fault = RetirementSwitch(), armed = RetirementSwitch(), settling = RetirementSettlementGate()
        addTeardownBlock { await settling.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { await settling.wait() } },
            beforeWrite: { if fault.on && $0.lastPathComponent == "preferences.json" { throw POSIXError(.EIO) } })
        let b = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        let departure = try await exceptional(a, authority: authority)
        fault.on = true
        do { try await a.service.disable(); XCTFail("Storage fault ignored") } catch is RequestPersistence.Fault {}
        fault.on = false; armed.on = true
        let first = Task { try await authority.recoverDeparture(serviceID: a.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { first.cancel(); await settling.release() }
        try await wait { await settling.entered }
        first.cancel()
        do { try await completed { try await first.value }; XCTFail("Cancelled participant succeeded") } catch is CancellationError {}
        let result = RetirementResult<Void>()
        let retry = Task { do { try await b.service.retryReconciliation(); result.value = .success(()) } catch { result.value = .failure(error) } }
        addTeardownBlock { retry.cancel(); await settling.release() }
        try await wait { await authority.observation.departureRecoverySuccessors == 1 }
        XCTAssertNil(result.value)
        let phases = await b.service.localRecoveryPhaseCount; XCTAssertEqual(phases, 1)
        let statuses = await a.service.recoveryStatuses()
        XCTAssertTrue(statuses.contains { $0.id == departure.id && $0.message.contains("settling retained recovery work") })
        armed.on = false; await settling.release()
        try await wait { result.value != nil }; try XCTUnwrap(result.value).get()
        let done = await authority.observation
        XCTAssertEqual(done.departureRecoveryParticipants, 0); XCTAssertEqual(done.departureRecoverySuccessors, 0)
    }
    func testLaterRevocationsRemainCoveredByPendingLocalOutcome() async throws {
        let f = try await fixture(), fail = RetirementSwitch(); fail.on = true
        let first = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [
            .init(id: "B", name: "B", tokenHash: "B"), .init(id: "C", name: "C", tokenHash: "C")], revocations: [first]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeRemovalFinalization: { intent, _ in if intent == first.operationID && fail.on { throw POSIXError(.EIO) } })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        // Construct retained committed-removal evidence explicitly; this test
        // does not claim a normal producer of exceptional finalization failure.
        do { try await authority.replay(); XCTFail("Injected finalization failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let hold = UUID()
        addTeardownBlock { await f.service.finishTrustedRecovery(pass: hold) }
        let local = try await f.service.trustedRecoveryOutcome(pass: hold, authority: authority.id)
        XCTAssertTrue(local.completed)
        fail.on = false
        for (index, device) in ["B", "C"].enumerated() {
            do { try await authority.revoke(device, permit: binding.permit, beforeCommit: { _ in }); XCTFail("Unaccepted local outcome lost its fence") }
            catch { XCTAssertTrue(error.localizedDescription.contains("awaiting its trusted pass admission")) }
            let current = await authority.observation
            XCTAssertEqual(current.pendingLocalOutcomes, 1); XCTAssertEqual(current.obligations, index + 1)
            XCTAssertEqual(current.recoveryPasses, 0)
            let bytes = try XCTUnwrap(backend.read())
            XCTAssertEqual(Set(try TrustedTVApprovals.decode(bytes).revocations.map(\.deviceID)), Set(["B", "C"].prefix(index + 1)))
        }
        try await f.service.retryReconciliation()
        let done = await authority.observation
        XCTAssertEqual(done.pendingLocalOutcomes, 0); XCTAssertEqual(done.obligations, 0)
        XCTAssertEqual(done.applicationRecoveryTargets, 0)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testCommittedRemovalPrunesOnlyItsPendingOutcomeObligation() async throws {
        for anotherIntent in [false, true] {
            let f = try await fixture(), fail = RetirementSwitch(); fail.on = true
            let first = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
            let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [first]).encoded())
            let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
                beforeRemovalFinalization: { _, _ in if fail.on { throw POSIXError(.EIO) } })
            let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
            // The injected finalization fault constructs retained committed-removal
            // evidence; it does not assert a normal producer of this state.
            do { try await authority.replay(); XCTFail("Finalization failure ignored") }
            catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
            XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
            let next = RequestRevocationIntent(operationID: UUID(), deviceID: "B")
            if anotherIntent {
                try backend.write(TrustedTVApprovals(revocations: [next]).encoded())
                _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
            }
            let hold = UUID()
            addTeardownBlock { await f.service.finishTrustedRecovery(pass: hold) }
            let local = try await f.service.trustedRecoveryOutcome(pass: hold, authority: authority.id)
            XCTAssertTrue(local.completed)
            let pending = await authority.observation; XCTAssertEqual(pending.pendingLocalOutcomes, 1)
            fail.on = false
            if anotherIntent {
                do { try await authority.replay(); XCTFail("The other pending intent was lost") }
                catch { XCTAssertTrue(error.localizedDescription.contains("awaiting its trusted pass admission")) }
                let remains = await authority.observation
                XCTAssertEqual(remains.pendingLocalOutcomes, 1); XCTAssertEqual(remains.obligations, 1)
                XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [next])
                await f.service.finishTrustedRecovery(pass: hold)
                try await f.service.retryReconciliation()
            } else {
                try await authority.replay()
                let done = await authority.observation
                XCTAssertEqual(done.pendingLocalOutcomes, 0); XCTAssertEqual(done.applicationRecoveryTargets, 0)
                XCTAssertEqual(done.obligations, 0)
                _ = try await authority.approve(binding.permit) { .init(record: .init(id: "C", name: "C", tokenHash: "token"), token: "token", eligibility: .init()) }
                let writes = backend.writes
                try await authority.revoke("C", permit: binding.permit, beforeCommit: { _ in })
                XCTAssertEqual(backend.writes, writes + 2)
                await f.service.finishTrustedRecovery(pass: hold)
            }
            let final = await authority.observation
            XCTAssertEqual(final.pendingLocalOutcomes, 0); XCTAssertEqual(final.obligations, 0)
        }
    }
}
@MainActor private final class RetirementResult<Value: Sendable> { var value: Result<Value, Error>? }
private final class RetirementSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
private actor RetirementSettlementGate {
    private(set) var entered = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
#endif
