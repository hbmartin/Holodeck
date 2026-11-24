#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

private final class OutcomeBackend: @unchecked Sendable {
    enum WriteFailure { case none, before, after, conflict, unreadableBefore, unreadableAfter }
    private let lock = NSLock()
    private var data: Data?
    private var gate: TrustedReadGate?
    private var failure: WriteFailure = .none
    private var readFailure = false
    private var readCount = 0, writeCount = 0
    init(_ data: Data? = nil) { self.data = data }
    func arm(_ gate: TrustedReadGate?) { lock.withLock { self.gate = gate } }
    func failWrites(_ value: WriteFailure) { lock.withLock { failure = value } }
    func failReads(_ value: Bool) { lock.withLock { readFailure = value } }
    func read() throws -> Data? {
        let captured = lock.withLock { readCount += 1; return (data, gate, readFailure) }
        captured.1?.wait()
        if captured.2 { throw POSIXError(.EACCES) }
        return captured.0
    }
    func write(_ value: Data) throws {
        try lock.withLock {
            if failure == .unreadableBefore { readFailure = true; throw POSIXError(.EIO) }
            if failure == .before { throw POSIXError(.EIO) }
            data = failure == .conflict ? Data("conflicting bytes".utf8) : value
            writeCount += 1
            if failure == .unreadableAfter { readFailure = true }
            if failure != .none { throw POSIXError(.EIO) }
        }
    }
    var bytes: Data? { lock.withLock { data } }
    var reads: Int { lock.withLock { readCount } }
    var writes: Int { lock.withLock { writeCount } }
}

@MainActor final class TrustedOutcomeBoundaryTests: XCTestCase {
    struct Fixture { let root: URL; let service: ShaderRequestService }
    func fixture(beforeWrite: @escaping @Sendable (URL) throws -> Void = { _ in },
                 reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pr56-outcomes-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile, beforePersistenceReplacement: beforeWrite)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, service: service)
    }
    func wait(timeout: Duration = .seconds(8), _ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Outcome boundary backstop") }
            try await Task.sleep(for: .milliseconds(3))
        }
    }
    func accepted(_ ticket: TrustedApprovalsCoordinator.Registration, timeout: Duration = .seconds(8)) async throws -> TrustedApprovalsCoordinator.Binding {
        let result = OutcomeResult<TrustedApprovalsCoordinator.BindingOutcome>()
        let probe = Task { do { result.value = .success(try await ticket.value()) } catch { result.value = .failure(error) } }
        addTeardownBlock { ticket.completion.cancel(); probe.cancel() }
        defer { probe.cancel() }
        // An independent probe can time out without joining an admitted owner.
        try await wait(timeout: timeout) { result.value != nil }
        guard case .accepted(let binding) = try XCTUnwrap(result.value).get() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    func submit(_ service: ShaderRequestService, device: String = "TV") async throws -> UUID {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1, height: 1)
        let request = ShaderRequest(prompt: "Outcome boundary", context: context)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: device)
        return request.id
    }
    func testUncertainApprovalRequiresPostAttemptReadEvenWithCancelledInspection() async throws {
        for mode in [OutcomeBackend.WriteFailure.after, .before, .conflict] {
            let backend = OutcomeBackend(try TrustedTVApprovals().encoded()), gate = TrustedReadGate()
            addTeardownBlock { gate.release() }
            let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
            let first = try await accepted(authority.register(TrustedOwnerRecorder().owner())), reads = backend.reads
            backend.arm(gate)
            let cancelled = try await authority.register(TrustedOwnerRecorder().owner())
            addTeardownBlock { cancelled.completion.cancel() }
            try await wait { gate.entered }; cancelled.completion.cancel()
            do { _ = try await cancelled.value(); XCTFail("Cancelled inspection accepted") } catch is CancellationError { }
            try await wait { await authority.observation.preparingGeneration == nil }
            backend.failWrites(mode)
            let eligibility = TrustedApprovalEligibility(), result = OutcomeResult<TrustedApprovalsCoordinator.Approval?>()
            let task = Task {
                do { result.value = .success(try await authority.approve(first.permit) {
                    .init(record: .init(id: "TV", name: "TV", tokenHash: "new"), token: "new", eligibility: eligibility)
                }) } catch { result.value = .failure(error) }
            }
            addTeardownBlock { task.cancel(); gate.release() }
            try await wait { await authority.observation.rawReadSubscribers == 1 }
            backend.arm(nil); gate.release()
            try await wait { result.value != nil }
            let outcome = try XCTUnwrap(result.value)
            XCTAssertEqual(backend.reads, reads + 2)
            switch mode {
            case .after:
                _ = try outcome.get(); XCTAssertTrue(eligibility.canIssue)
                XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).approvals.map(\.tokenHash), ["new"])
            case .before:
                guard case .failure(let error) = outcome else { return XCTFail("Failed write accepted") }
                XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription))
                XCTAssertNoThrow(try eligibility.check()); XCTAssertFalse(eligibility.canIssue)
            case .conflict:
                guard case .failure = outcome else { return XCTFail("Conflicting outcome accepted") }
                XCTAssertThrowsError(try eligibility.check())
            case .none, .unreadableBefore, .unreadableAfter: XCTFail("Unexpected fixture mode")
            }
            let state = await authority.observation
            XCTAssertEqual(state.rawReadFlights, 0); XCTAssertEqual(state.rawReadSubscribers, 0)
        }
    }
    func testPendingInitialAuthorityIsRecheckedAtInstallAndCannotBeOverwrittenByFailure() async throws {
        for failSecond in [false, true] {
            let f = try await fixture(), aStore = OutcomeBackend(), bStore = OutcomeBackend(), read = TrustedReadGate(), activation = RecoveryGate()
            addTeardownBlock { read.release(); await activation.release() }
            let a = TrustedApprovalsCoordinator(read: { try aStore.read() }, write: { try aStore.write($0) })
            let b = TrustedApprovalsCoordinator(read: { try bStore.read() }, write: { try bStore.write($0) }, beforeTargetActivation: { _ in
                try await activation.wait()
                if failSecond { throw POSIXError(.EIO) }
            })
            aStore.failReads(true); aStore.arm(read)
            let ar = try await a.register(TrustedOwnerRecorder().owner(service: f.service))
            addTeardownBlock { ar.completion.cancel() }
            try await wait { read.entered }
            let br = try await b.register(TrustedOwnerRecorder().owner(service: f.service))
            addTeardownBlock { br.completion.cancel() }
            try await wait { await activation.hasEntered }
            aStore.arm(nil); read.release()
            do { _ = try await ar.value(); XCTFail("Failed initial read accepted") } catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
            await activation.release()
            do { _ = try await br.value(); XCTFail("Competing authority replaced pending A") }
            catch { XCTAssertTrue(error.localizedDescription.contains(failSecond ? POSIXError(.EIO).localizedDescription : "earlier TV authority")) }
            do { _ = try await f.service.prepareTrustedAuthority(id: b.id); XCTFail("Pending route was overwritten") }
            catch { XCTAssertTrue(error.localizedDescription.contains("earlier TV authority")) }
            let bState = await b.observation; XCTAssertNil(bState.acceptedGeneration); XCTAssertEqual(bState.uninspectedTargets, 0)
            aStore.failReads(false)
            _ = try await accepted(a.register(TrustedOwnerRecorder().owner(service: f.service)))
        }
    }
    func testOlderAdmittedInspectionFailureCannotRestoreObsoleteRetryCandidate() async throws {
        let a = try await fixture(), b = try await fixture(), backend = OutcomeBackend(), gate = RecoveryGate(), armed = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeTargetInspection: { id in
            if id == a.service.runtimeID && armed.take() { try await gate.wait(); throw POSIXError(.EIO) }
        })
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        armed.on = true
        let old = try await authority.register(recorder.owner(service: a.service))
        addTeardownBlock { old.completion.cancel() }
        try await wait { await gate.hasEntered }
        XCTAssertTrue(old.completion.hasStarted)
        let newer = try await authority.register(recorder.owner(service: b.service))
        addTeardownBlock { newer.completion.cancel() }
        await gate.release()
        _ = try await accepted(old)
        let binding = try await accepted(newer)
        try await b.service.retryReconciliation()
        let state = await authority.observation, current = await recorder.binding
        XCTAssertEqual(state.requestedGeneration, newer.generation)
        XCTAssertTrue(current?.service === b.service); XCTAssertTrue(binding.permit.isCurrent)
        let snapshot = await recorder.snapshot; XCTAssertNil(snapshot?.diagnostic)
    }
    func testAcceptedReplacementReplaysHealthyTargetAfterOtherInspectionFails() async throws {
        let a = try await fixture(), b = try await fixture(), job = try await submit(b.service), backend = OutcomeBackend(), armed = OutcomeSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeTargetInspection: { id in
            if id == a.service.runtimeID && armed.take() { throw POSIXError(.EIO) }
        })
        let catalog = DirectoryCatalog(directory: b.root.appendingPathComponent("catalog"))
        let old = LocalCatalogServer(catalog: catalog, testingNamespace: "outcome-old-" + UUID().uuidString, trustedApprovals: authority)
        let next = LocalCatalogServer(catalog: catalog, testingNamespace: "outcome-next-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { try await next.shutdownReceipt().value(); try await old.shutdownReceipt().value() }
        await old.setRequestService(a.service)
        try backend.write(TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        armed.on = true; await next.setRequestService(b.service)
        let state = await authority.observation, jobs = await b.service.allJobs()
        XCTAssertEqual(state.acceptedGeneration, 2)
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertFalse(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
        // Failed target evidence remains until explicit inspection/recovery.
        try await b.service.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
    }
    func testWithdrawnInitialProposalCancelsExactJobsWithoutReactivation() async throws {
        let a = try await fixture(), b = try await fixture()
        let revoked = try await submit(a.service), retained = try await submit(a.service, device: "OTHER")
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [intent]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }), owner = TrustedOwnerRecorder(), proposal = owner.owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let state = await authority.observation; return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 }
        let state = await authority.observation, jobs = await a.service.allJobs(), activated = await owner.binding
        XCTAssertNil(state.acceptedGeneration); XCTAssertNil(activated)
        XCTAssertEqual(jobs.first { $0.id == revoked }?.stage, .cancelled)
        XCTAssertEqual(jobs.first { $0.id == retained }?.stage, .queued)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: a.root.appendingPathComponent("journal.json"))) as! [[String: Any]]
        let row = try XCTUnwrap(saved.first { ($0["status"] as? [String: Any])?["id"] as? String == revoked.uuidString })
        XCTAssertEqual((row["status"] as? [String: Any])?["stage"] as? String, "cancelled")
        XCTAssertEqual(backend.writes, 0)
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        try await authority.replay()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
    }
    func testWithdrawnCleanupFailureRetainsExactRouteAndRetriesWithoutActivation() async throws {
        let fail = OutcomeSwitch(), a = try await fixture(beforeWrite: { url in
            if url.lastPathComponent == "journal.json" && fail.on { throw POSIXError(.EIO) }
        }), b = try await fixture(), revoked = try await submit(a.service)
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }), owner = TrustedOwnerRecorder(), proposal = owner.owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") } catch { }
        backend.failReads(false); fail.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let state = await authority.observation; return state.uninspectedCleanupTasks == 0 && state.uninspectedTargets == 1 }
        let failures = await a.service.recoveryStatuses()
        XCTAssertTrue(failures.contains { $0.message.contains(POSIXError(.EIO).localizedDescription) })
        XCTAssertFalse(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
        let reads = backend.reads
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        let repeated = await authority.observation
        XCTAssertEqual(repeated.uninspectedCleanupTasks, 0); XCTAssertEqual(backend.reads, reads)
        fail.on = false
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        try await b.service.retryReconciliation()
        let done = await authority.observation, activated = await owner.binding, jobs = await a.service.allJobs()
        XCTAssertNil(activated); XCTAssertEqual(done.uninspectedTargets, 0); XCTAssertEqual(done.uninspectedCleanupTasks, 0)
        XCTAssertEqual(jobs.first { $0.id == revoked }?.stage, .cancelled)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
    }

    func testWithdrawnCleanupSharesOneAttemptAndBlocksBindingUntilItsReadSettles() async throws {
        let f = try await fixture(), backend = OutcomeBackend(), read = TrustedReadGate(), owner = TrustedOwnerRecorder()
        addTeardownBlock { read.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }), proposal = owner.owner(service: f.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); backend.arm(read); proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { read.entered }
        let repeated = Task { await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility) }
        addTeardownBlock { repeated.cancel(); read.release() }
        try await wait { await authority.observation.progressWaiters > 0 }
        let held = await authority.observation
        XCTAssertNil(held.acceptedGeneration); XCTAssertEqual(held.uninspectedCleanupTasks, 1)
        let replacement = try await authority.register(TrustedOwnerRecorder().owner(service: f.service))
        addTeardownBlock { replacement.completion.cancel() }
        XCTAssertFalse(replacement.completion.hasStarted)
        backend.arm(nil); read.release()
        await repeated.value
        _ = try await accepted(replacement)
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        let after = await authority.observation, old = await owner.binding
        XCTAssertNil(old); XCTAssertEqual(after.uninspectedTargets, 0)
        XCTAssertEqual(after.acceptedGeneration, replacement.generation)
    }

    func testCommittedRemovalFinalizesDespiteUnrelatedUninspectedProposal() async throws {
        let a = try await fixture(), b = try await fixture(), job = try await submit(a.service), fail = OutcomeSwitch()
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        fail.on = true
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeRemovalFinalization: { _, _ in
            if fail.on { throw POSIXError(.EIO) }
        })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        // Inject exact committed-removal recovery evidence; no normal producer
        // of every exceptional finalization state is claimed by this fixture.
        do { try await authority.replay(); XCTFail("Finalization failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 1)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service))); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); fail.on = false
        try await authority.replay()
        let state = await authority.observation, jobs = await a.service.allJobs()
        XCTAssertEqual(state.obligations, 0); XCTAssertEqual(state.uninspectedTargets, 1)
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(backend.writes, 1) // Finalization consumes the original receipt; no second write.
        _ = try await submit(a.service)
    }
    func testRecoverySaveFaultStopsRetirementBeforeNextJournalAndRetryDrainsIt() async throws {
        let seed = try await fixture(), first = try await submit(seed.service, device: "A"), second = try await submit(seed.service, device: "B")
        let journal = seed.root.appendingPathComponent("journal.json"), marker = seed.root.appendingPathComponent("active.json")
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]]
        for index in rows.indices {
            let operation = UUID()
            rows[index]["executionID"] = operation.uuidString
            rows[index]["dispatch"] = ["executionID": operation.uuidString, "priorStage": "queued", "launched": false, "retirementPending": true]
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: journal)
        try JSONEncoder().encode(second).write(to: marker)
        let observed = OutcomePaths(), fail = OutcomeSwitch()
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: seed.root.appendingPathComponent("catalog")), directory: seed.root,
            workerScript: seed.root.appendingPathComponent("unused.py"), reconcileWorker: { path in
                observed.add(path.lastPathComponent)
                if observed.count == 1 { fail.on = true; throw RequestWorkerEvidenceError(cause: "Original retirement observation failure") }
            }, beforePersistenceReplacement: { path in
                if path.lastPathComponent == "recovery.json" && fail.on { throw POSIXError(.EIO) }
            })
        addTeardownBlock { await service.suspend() }
        await service.suspend(); try await service.initialize(configuration: .init(repository: seed.root.path, enabled: true))
        XCTAssertEqual(observed.count, 1)
        XCTAssertTrue(RequestProcessIdentity.evidenceExists(marker))
        let blockers = await service.recoveryStatuses()
        XCTAssertTrue(blockers.contains { $0.message.contains("Original retirement observation failure") })
        XCTAssertTrue(blockers.contains { $0.message.contains(POSIXError(.EIO).localizedDescription) })
        fail.on = false; try await service.retryReconciliation()
        XCTAssertGreaterThanOrEqual(observed.count, 3)
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(marker))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]]
        for id in [first, second] {
            let row = try XCTUnwrap(saved.first { ($0["status"] as? [String: Any])?["id"] as? String == id.uuidString })
            XCTAssertNil(row["dispatch"])
        }
    }

    func testWithdrawnCleanupFreshReadAlsoFencesAndCancelsAcceptedTargets() async throws {
        let a = try await fixture(), b = try await fixture(), aJob = try await submit(a.service), bJob = try await submit(b.service)
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        let proposal = TrustedOwnerRecorder().owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false)
        try backend.write(TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let state = await authority.observation; return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 }
        let aJobs = await a.service.allJobs(), bJobs = await b.service.allJobs()
        XCTAssertEqual(aJobs.first { $0.id == aJob }?.stage, .cancelled)
        XCTAssertEqual(bJobs.first { $0.id == bJob }?.stage, .cancelled)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
    }

    func testUnacceptedRetirementCannotFinalizeDuringConcurrentLocalInspection() async throws {
        let armed = OutcomeSwitch(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let f = try await fixture(reconcile: { _ in if armed.on { try await gate.wait() } }), authority = UUID()
        await f.service.failedTrustedRegistration(POSIXError(.EIO), authority: authority) { _ in .init(completedServices: []) }
        let preparation = try await f.service.prepareUnacceptedTargetRetirement(authority: authority, proposal: UUID())
        addTeardownBlock { await f.service.endUnacceptedTargetRetirement(preparation); await gate.release() }
        armed.on = true
        let repair = Task { try await f.service.recoverDepartureLocal() }
        addTeardownBlock { repair.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        do { try await f.service.completeUnacceptedTargetRetirement(preparation); XCTFail("Unfinished local inspection certified retirement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("verified metadata")) }
        armed.on = false; await gate.release()
        let repaired = try await repair.value; XCTAssertTrue(repaired.completed)
        try await f.service.completeUnacceptedTargetRetirement(preparation)
        _ = try await f.service.prepareTrustedAuthority(id: UUID())
    }

    func testCommittedRevocationAndRemovalWriteErrorsContinueTheirActualOutcome() async throws {
        let f = try await fixture(), job = try await submit(f.service)
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        backend.failWrites(.after)
        try await authority.revoke("TV", permit: binding.permit) { _ in }
        let bytes = try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)), state = await authority.observation, jobs = await f.service.allJobs()
        XCTAssertTrue(bytes.approvals.isEmpty); XCTAssertTrue(bytes.revocations.isEmpty)
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(backend.writes, 2); XCTAssertEqual(state.encodings, 2)
        XCTAssertEqual(state.writeReadbacks, 2); XCTAssertEqual(state.uncertainWrites, 0)
    }
    func testAmbiguousRevocationKeepsFencesAndResolvesOnlyThroughRecovery() async throws {
        for mode in [OutcomeBackend.WriteFailure.unreadableAfter, .unreadableBefore] {
            let f = try await fixture(), job = try await submit(f.service)
            let original = try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()
            let backend = OutcomeBackend(original), authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
            let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
            backend.failWrites(mode)
            do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Ambiguous write accepted") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription))
                XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription))
            }
            let before = await authority.observation
            XCTAssertEqual(before.uncertainWrites, 1); XCTAssertEqual(before.writeReadbacks, 1)
            do { _ = try await submit(f.service); XCTFail("Uncertain device fence lifted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("recovery")) }
            do {
                _ = try await authority.approve(binding.permit) { XCTFail("Blocked proposal prepared"); return nil }
                XCTFail("Uncertain write admitted another mutation")
            } catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
            let blocked = await authority.observation; XCTAssertEqual(blocked.encodings, before.encodings)
            backend.failReads(false); backend.failWrites(.none)
            try await f.service.retryReconciliation()
            let done = await authority.observation, jobs = await f.service.allJobs()
            XCTAssertEqual(done.uncertainWrites, 0); XCTAssertEqual(done.obligations, 0)
            if mode == .unreadableAfter {
                XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
                XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).approvals.isEmpty)
            } else {
                XCTAssertEqual(jobs.first { $0.id == job }?.stage, .queued)
                XCTAssertEqual(backend.bytes, original)
            }
        }
    }
    func testUnknownRemovalKeepsExactApplicationsAcrossLocalRepair() async throws {
        for mode in [OutcomeBackend.WriteFailure.unreadableAfter, .unreadableBefore] {
            let f = try await fixture(), job = try await submit(f.service)
            let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
            let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
            _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
            backend.failWrites(mode)
            do { try await authority.replay(); XCTFail("Uncertain removal accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
            let before = await authority.observation; XCTAssertEqual(before.uncertainWrites, 1); XCTAssertEqual(before.obligations, 1)
            backend.failReads(false); backend.failWrites(.none)
            try await f.service.retryReconciliation()
            let after = await authority.observation, jobs = await f.service.allJobs()
            XCTAssertEqual(after.uncertainWrites, 0); XCTAssertEqual(after.obligations, 0)
            XCTAssertEqual(after.pendingLocalOutcomes, 0); XCTAssertEqual(after.writeReadbacks, 1)
            XCTAssertEqual(backend.writes, 1) // A proven committed removal is never rewritten.
            XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
            XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
        }
    }
    func testUnknownApprovalNoncommitRestoresOnlyTheSameLivePairing() async throws {
        for closed in [false, true] {
            let f = try await fixture(), backend = OutcomeBackend(try TrustedTVApprovals().encoded())
            let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
            let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service))), eligibility = TrustedApprovalEligibility()
            backend.failWrites(.unreadableBefore)
            do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "TV", name: "TV", tokenHash: "new"), token: "new", eligibility: eligibility) }; XCTFail("Unknown approval accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
            XCTAssertThrowsError(try eligibility.check())
            if closed { eligibility.close() }
            backend.failReads(false); backend.failWrites(.none)
            try await f.service.retryReconciliation()
            if closed { XCTAssertThrowsError(try eligibility.check()) } else { XCTAssertNoThrow(try eligibility.check()) }
        }
    }
    func testCleanupReprocessesRevocationCommittedDespiteWriteError() async throws {
        let arm = OutcomeSwitch(), inspecting = OutcomeSwitch(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let a = try await fixture(beforeWrite: { url in if url.lastPathComponent == "journal.json" && arm.take() { gate.wait() } }), b = try await fixture()
        _ = try await submit(a.service, device: "OLD"); let job = try await submit(a.service)
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")], revocations: [.init(operationID: UUID(), deviceID: "OLD")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeInspectionRead: { if inspecting.on { arm.on = true } })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service))), proposal = TrustedOwnerRecorder().owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed initial read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); inspecting.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { gate.entered }
        backend.failWrites(.after)
        let result = OutcomeResult<Void>(), revoke = Task {
            do { try await authority.revoke("TV", permit: binding.permit) { _ in }; result.value = .success(()) }
            catch { result.value = .failure(error) }
        }
        addTeardownBlock { revoke.cancel(); gate.release() }
        try await wait { backend.writes > 0 }
        inspecting.on = false; gate.release()
        try await wait { let value = await authority.observation; return value.uninspectedTargets == 0 && value.uninspectedCleanupTasks == 0 && result.value != nil }
        if case .failure(let error) = result.value { XCTAssertTrue(error.localizedDescription.contains("proposed request service")) }
        let jobs = await a.service.allJobs(), bytes = try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes))
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertTrue(bytes.approvals.isEmpty); XCTAssertTrue(bytes.revocations.isEmpty)
    }

    func testCompatibilityBindingRechecksRetirementAfterLocalPreparationWait() async throws {
        let armed = OutcomeSwitch(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let f = try await fixture(reconcile: { _ in if armed.on { try await gate.wait() } })
        let backend = OutcomeBackend(), authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        await f.service.failedTrustedRegistration(POSIXError(.EIO), authority: authority.id) { _ in .init(completedServices: []) }
        armed.on = true
        let local = Task { try await f.service.recoverDepartureLocal() }
        addTeardownBlock { local.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let result = OutcomeResult<UUID>(), binding = Task { result.value = .success(await f.service.registerRevocationCoordinator(id: authority.id) {}) }
        addTeardownBlock { binding.cancel(); await gate.release() }
        try await wait { await f.service.localPreparationWaiters == 1 }
        let retirement = try await f.service.prepareUnacceptedTargetRetirement(authority: authority.id, proposal: UUID())
        addTeardownBlock { await f.service.endUnacceptedTargetRetirement(retirement) }
        do { _ = try await f.service.installRevocationCoordinator(authority: authority, recovery: { _ in .init(completedServices: []) }); XCTFail("Production guard ignored retirement") }
        catch is TrustedLocalPreparationPending { }
        armed.on = false; await gate.release()
        let outcome = try await local.value; XCTAssertTrue(outcome.completed)
        try await wait { retirement.waiterCount == 1 }
        XCTAssertNil(result.value)
        try await f.service.completeUnacceptedTargetRetirement(retirement)
        try await wait { result.value != nil }
        let registration = try XCTUnwrap(result.value).get()
        let repeated = await f.service.registerRevocationCoordinator(id: authority.id) {}
        XCTAssertEqual(registration, repeated)
    }
    func testRegistrationCompletionBackstopDoesNotAbandonAdmittedActivation() async throws {
        let f = try await fixture(), gate = RecoveryGate(), armed = OutcomeSwitch(), backend = OutcomeBackend()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, afterTargetActivation: { _ in
            if armed.on { try? await gate.wait() }
        })
        let prior = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        armed.on = true
        let ticket = try await authority.register(TrustedOwnerRecorder().owner(service: f.service))
        addTeardownBlock { ticket.completion.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        XCTAssertTrue(ticket.completion.hasStarted)
        let result = OutcomeResult<TrustedApprovalsCoordinator.Binding>()
        let timed = Task { do { result.value = .success(try await self.accepted(ticket, timeout: .milliseconds(30))) } catch { result.value = .failure(error) } }
        addTeardownBlock { timed.cancel(); await gate.release() }
        // This outer bound also makes a regression in accepted's own timeout fail.
        try await wait { result.value != nil }
        guard case .failure(let error) = try XCTUnwrap(result.value) else { return XCTFail("Held registration finished") }
        XCTAssertTrue(error.localizedDescription.contains("Outcome boundary backstop"))
        XCTAssertTrue(prior.permit.isCurrent)
        armed.on = false; await gate.release()
        try await wait { await authority.observation.acceptedGeneration == ticket.generation }
        XCTAssertFalse(prior.permit.isCurrent)
    }

}
private final class OutcomePaths: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}
private final class OutcomeSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    func take() -> Bool { lock.withLock { let result = value; value = false; return result } }
}
@MainActor private final class OutcomeResult<Value: Sendable> { var value: Result<Value, Error>? }
#endif
