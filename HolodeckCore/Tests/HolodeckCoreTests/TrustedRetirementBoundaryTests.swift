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
    @discardableResult
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
    func testIndependentTicketReceiptsShareOnlyOwnershipInvalidation() async throws {
        let armed = RetirementSwitch()
        let f = try await fixture(beforeWrite: { if armed.on && $0.lastPathComponent == "preferences.json" { throw POSIXError(.EIO) } })
        try await f.service.retryReconciliation()
        let authority = UUID(), firstTicket = UUID(), secondTicket = UUID()
        let captureda = await f.service.departureRetirementAssessment(authority: authority, ticket: firstTicket)
        let a = try XCTUnwrap(captureda)
        let capturedb = await f.service.departureRetirementAssessment(authority: authority, ticket: secondTicket)
        let b = try XCTUnwrap(capturedb)
        XCTAssertTrue(a.ownership === b.ownership)
        XCTAssertTrue(a.admit()); XCTAssertTrue(b.admit()); XCTAssertFalse(a.admit())
        let wrong = await f.service.validateDepartureRetirement(b, authority: authority, ticket: firstTicket)
        XCTAssertFalse(wrong)
        let capturedc = await f.service.departureRetirementAssessment(authority: authority, ticket: UUID())
        let c = try XCTUnwrap(capturedc)
        let capturedd = await f.service.departureRetirementAssessment(authority: UUID(), ticket: UUID())
        let d = try XCTUnwrap(capturedd)
        armed.on = true
        do { try await f.service.disable(); XCTFail("Fault ignored") } catch is RequestPersistence.Fault {}
        XCTAssertFalse(c.admit()); XCTAssertFalse(d.admit())
    }
    func testTwoExceptionalAuthoritiesRetireIndependentTickets() async throws {
        let f = try await fixture(), admission = RetirementSettlementGate()
        addTeardownBlock { await admission.release() }
        let one = TrustedBackendFixture(nil), two = TrustedBackendFixture(nil)
        let a = TrustedApprovalsCoordinator(read: { try one.checkedRead() }, write: { try one.write($0) },
            beforeDepartureRetirementAdmission: { _ in await admission.wait() })
        let b = TrustedApprovalsCoordinator(read: { try two.checkedRead() }, write: { try two.write($0) },
            beforeDepartureRetirementAdmission: { _ in await admission.wait() })
        _ = try await accepted(a.register(TrustedOwnerRecorder().owner(service: f.service)))
        let da = try await exceptional(f, authority: a)
        // Explicit invariant injection retains two old authorities. This does
        // not establish a normal producer of either exceptional departure.
        _ = await f.service.registerRevocationCoordinator(id: b.id, recovery: { _ in })
        _ = try await accepted(b.register(TrustedOwnerRecorder().owner(service: f.service)))
        let db = try await exceptional(f, authority: b)
        let first = Task { try await a.recoverDeparture(serviceID: f.service.runtimeID, ticket: da.id) }
        let second = Task { try await b.recoverDeparture(serviceID: f.service.runtimeID, ticket: db.id) }
        addTeardownBlock { first.cancel(); second.cancel(); await admission.release() }
        try await wait { await admission.entries == 2 }
        await admission.release()
        try await completed { try await first.value }; try await completed { try await second.value }
        let oldA = await a.observation, oldB = await b.observation
        XCTAssertEqual(oldA.targets, 0); XCTAssertEqual(oldB.targets, 0)
        XCTAssertEqual(oldA.recoverySubscriptions, 0); XCTAssertEqual(oldB.recoverySubscriptions, 0)
    }
    func testSameDepartureCallersShareOneAdmission() async throws {
        let f = try await fixture(), admission = RetirementSettlementGate()
        addTeardownBlock { await admission.release() }
        let backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeDepartureRetirementAdmission: { _ in await admission.wait() })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        let departure = try await exceptional(f, authority: authority)
        let first = Task { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { first.cancel(); await admission.release() }
        try await wait { await admission.entered }
        let second = Task { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { second.cancel(); await admission.release() }
        try await wait { await authority.observation.departureRecoveryParticipants == 2 }
        await admission.release()
        try await completed { try await first.value }; try await completed { try await second.value }
        let count = await admission.entries; XCTAssertEqual(count, 1)
        try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id)
        let after = await admission.entries; XCTAssertEqual(after, 1)
    }
    func testDepartureSuccessorReceivesCancelledPredecessorsCommittedReceipt() async throws {
        let f = try await fixture(), admission = RetirementSettlementGate()
        let backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeDepartureRetirementAdmission: { _ in await admission.wait() })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        let departure = try await exceptional(f, authority: authority)
        let first = Task { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { first.cancel(); await admission.release() }
        try await wait { await admission.entered }
        first.cancel()
        do { try await completed { try await first.value }; XCTFail("Cancelled participant succeeded") }
        catch is CancellationError {}

        let successor = Task { try await authority.recoverDeparture(serviceID: f.service.runtimeID, ticket: departure.id) }
        addTeardownBlock { successor.cancel(); await admission.release() }
        try await wait { await authority.observation.departureRecoverySuccessors == 1 }
        await admission.release()

        let committed = try await completed { try await successor.value }
        let entries = await admission.entries
        let observation = await authority.observation
        XCTAssertTrue(committed)
        XCTAssertEqual(entries, 1)
        XCTAssertEqual(observation.departureRecoverySuccessors, 0)
        XCTAssertEqual(observation.targets, 0)
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
    func testIntentFreeOutcomeFencesLaterRevocationAndAutomaticallyValidatesAfterAbandonment() async throws {
        let f = try await fixture(), hold = UUID()
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "Later", name: "Later", tokenHash: "old")]).encoded())
        let authority = backend.coordinator()
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        let local = try await f.service.trustedRecoveryOutcome(pass: hold, authority: authority.id)
        XCTAssertTrue(local.completed)
        let pending = await authority.observation; XCTAssertEqual(pending.pendingLocalOutcomes, 1)
        do { try await authority.revoke("Later", permit: binding.permit) { _ in }; XCTFail("Unaccepted local outcome applied") }
        catch { XCTAssertTrue(error.localizedDescription.contains("awaiting its trusted pass")) }
        let fenced = await authority.observation; XCTAssertEqual(fenced.obligations, 1); XCTAssertEqual(fenced.recoveryPasses, 0)
        let phases = await f.service.localRecoveryPhaseCount
        await f.service.finishTrustedRecovery(pass: hold)
        try await authority.revoke("Later", permit: binding.permit) { _ in }
        let done = await authority.observation
        XCTAssertEqual(done.pendingLocalOutcomes, 0); XCTAssertEqual(done.obligations, 0)
        XCTAssertEqual(done.recoveryPasses, 1); XCTAssertEqual(backend.writes, 2)
        let after = await f.service.localRecoveryPhaseCount; XCTAssertEqual(after, phases)
    }
    func testFailedAutomaticValidationRetainsFenceAndDoesNotSpin() async throws {
        let f = try await fixture(), hold = UUID()
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "Later", name: "Later", tokenHash: "old")]).encoded())
        let authority = backend.coordinator()
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        _ = try await f.service.trustedRecoveryOutcome(pass: hold, authority: authority.id)
        await f.service.finishTrustedRecovery(pass: hold)
        backend.failReads(true)
        do { try await authority.revoke("Later", permit: binding.permit) { _ in }; XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        let failed = await authority.observation
        XCTAssertEqual(failed.pendingLocalOutcomes, 1); XCTAssertEqual(failed.obligations, 1); XCTAssertEqual(failed.recoveryPasses, 1)
        backend.failReads(false)
        do { try await authority.revoke("Later", permit: binding.permit) { _ in }; XCTFail("Automatic validation spun again") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Choose Retry Recovery")) }
        let still = await authority.observation; XCTAssertEqual(still.recoveryPasses, 1)
        try await f.service.retryReconciliation()
        let done = await authority.observation; XCTAssertEqual(done.obligations, 0); XCTAssertEqual(done.pendingLocalOutcomes, 0)
    }
    func testLaterRevocationsJoinTheSameAutomaticValidation() async throws {
        let f = try await fixture(), hold = UUID(), sealing = RecoveryGate()
        addTeardownBlock { await sealing.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: ["B", "C"].map { .init(id: $0, name: $0, tokenHash: "old") }).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeRecoverySealing: { try await sealing.wait() })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        _ = try await f.service.trustedRecoveryOutcome(pass: hold, authority: authority.id)
        await f.service.finishTrustedRecovery(pass: hold)
        let first = Task { try await authority.revoke("B", permit: binding.permit) { _ in } }
        addTeardownBlock { first.cancel(); await sealing.release() }
        try await wait { await sealing.hasEntered }
        let second = Task { try await authority.revoke("C", permit: binding.permit) { _ in } }
        addTeardownBlock { second.cancel(); await sealing.release() }
        // Independent replay may already have finalized the first intent. Both
        // credential removals must be admitted before releasing shared validation.
        try await wait { (try? backend.read().map(TrustedTVApprovals.decode)?.approvals.isEmpty) == true }
        await sealing.release()
        try await completed { try await first.value }; try await completed { try await second.value }
        let done = await authority.observation
        XCTAssertEqual(done.recoveryPasses, 1); XCTAssertEqual(done.obligations, 0)
        XCTAssertEqual(backend.writes, 4)
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
    private(set) var entries = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entries += 1; entered = true; if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
#endif
