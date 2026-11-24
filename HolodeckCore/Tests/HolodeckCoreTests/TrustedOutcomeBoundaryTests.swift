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
    func makeRequest() throws -> ShaderRequest {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1, height: 1)
        return ShaderRequest(prompt: "Outcome boundary", context: context)
    }
    func submit(_ service: ShaderRequestService, device: String = "TV") async throws -> UUID {
        let request = try makeRequest()
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

    func testCommittedRemovalFinishesKnownTargetButRetainsUninspectedEvidence() async throws {
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
        do { try await authority.replay(); XCTFail("Uninspected evidence retired") }
        catch { XCTAssertTrue(error.localizedDescription.contains("proposed request service")) }
        let state = await authority.observation, jobs = await a.service.allJobs()
        XCTAssertEqual(state.obligations, 1); XCTAssertEqual(state.uninspectedTargets, 1)
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(backend.writes, 1) // Known target finalizes without rewriting removal.
        _ = try await submit(a.service)
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        try await authority.replay()
        let retired = await authority.observation
        XCTAssertEqual(retired.obligations, 0); XCTAssertEqual(backend.writes, 1)
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
        let completed = try await accepted(ticket)
        XCTAssertEqual(completed.permit.generation, ticket.generation)
        XCTAssertTrue(completed.permit.isCurrent)
        let final = await authority.observation
        XCTAssertEqual(final.acceptedGeneration, completed.permit.generation)
        XCTAssertFalse(prior.permit.isCurrent)
    }

    func testReplayRechecksWriteCertaintyAfterApplicationHooks() async throws {
        for mode in [OutcomeBackend.WriteFailure.unreadableAfter, .unreadableBefore] {
            let f = try await fixture(), job = try await submit(f.service, device: "A"), gate = RecoveryGate(), recorder = TrustedOwnerRecorder()
            addTeardownBlock { await gate.release() }
            let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
            let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [intent]).encoded())
            let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeReplayApplication: { _ in try await gate.wait() })
            let binding = try await accepted(authority.register(recorder.owner(service: f.service)))
            let result = OutcomeResult<Void>(), replay = Task { do { try await authority.replay(); result.value = .success(()) } catch { result.value = .failure(error) } }
            addTeardownBlock { replay.cancel(); await gate.release() }
            try await wait { await gate.hasEntered }
            backend.failWrites(mode)
            do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "B", name: "B", tokenHash: "new"), token: "new", eligibility: .init()) }; XCTFail("Unknown write accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
            let uncertain = await recorder.snapshot
            await gate.release()
            try await wait { result.value != nil }
            guard case .failure(let error) = try XCTUnwrap(result.value) else { return XCTFail("Uncertain replay succeeded") }
            XCTAssertTrue(error.localizedDescription.contains("unverified"))
            let jobs = await f.service.allJobs(), state = await authority.observation, after = await recorder.snapshot
            XCTAssertEqual(jobs.first { $0.id == job }?.stage, .queued)
            XCTAssertEqual(state.uncertainWrites, 1); XCTAssertEqual(state.obligations, 1)
            XCTAssertEqual(state.applicationRecoveryTargets, 0)
            XCTAssertEqual(after?.diagnostic, uncertain?.diagnostic); XCTAssertEqual(after?.diagnosticID, uncertain?.diagnosticID)
            XCTAssertEqual(backend.writes, mode == .unreadableAfter ? 1 : 0)
            backend.failReads(false); backend.failWrites(.none)
            try await f.service.retryReconciliation()
            let recovered = await f.service.allJobs(), clean = await authority.observation
            XCTAssertEqual(recovered.first { $0.id == job }?.stage, .cancelled)
            XCTAssertEqual(clean.uncertainWrites, 0); XCTAssertEqual(clean.obligations, 0)
            XCTAssertEqual(clean.applicationRecoveryTargets, 0)
        }
    }
    func testReplayApplicationAdmittedBeforeUncertaintyFinishesItsOutcome() async throws {
        let arm = OutcomeSwitch(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let f = try await fixture(beforeWrite: { url in if url.lastPathComponent == "journal.json", arm.take() { gate.wait() } })
        let job = try await submit(f.service, device: "A"), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [intent]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        arm.on = true
        let result = OutcomeResult<Void>(), replay = Task { do { try await authority.replay(); result.value = .success(()) } catch { result.value = .failure(error) } }
        addTeardownBlock { replay.cancel(); gate.release() }
        try await wait { gate.entered }
        backend.failWrites(.unreadableAfter)
        do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "B", name: "B", tokenHash: "new"), token: "new", eligibility: .init()) }; XCTFail("Unknown write accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        gate.release()
        try await wait { result.value != nil }
        guard case .failure(let error) = try XCTUnwrap(result.value) else { return XCTFail("Uncertain replay succeeded") }
        XCTAssertTrue(error.localizedDescription.contains("unverified"))
        let jobs = await f.service.allJobs(), pending = await authority.observation
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(pending.obligations, 1); XCTAssertEqual(pending.uncertainWrites, 1)
        backend.failReads(false); backend.failWrites(.none)
        try await f.service.retryReconciliation()
        let clean = await authority.observation
        XCTAssertEqual(clean.obligations, 0); XCTAssertEqual(clean.uncertainWrites, 0)
        XCTAssertEqual(backend.writes, 2) // Confirmed B approval and one removal of A.
    }

    func testUncertainRevocationKeepsCredentialButFencesEveryRequestMutation() async throws {
        for mode in [OutcomeBackend.WriteFailure.unreadableAfter, .unreadableBefore] {
            let f = try await fixture(), request = try makeRequest(), job = request.id
            _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
            let original = try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()
            let backend = OutcomeBackend(original), authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
            let server = LocalCatalogServer(catalog: DirectoryCatalog(directory: f.root.appendingPathComponent("catalog")),
                testingNamespace: "pr58-authorization-" + UUID().uuidString, trustedApprovals: authority)
            addTeardownBlock { let receipt = await server.shutdownReceipt(); try? await receipt.value() }
            await server.setRequestService(f.service)
            let authorization = try await server.requestAuthorization(for: "TV")
            backend.failWrites(mode)
            do { try await server.revoke("TV"); XCTFail("Unknown revocation accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
            let continued = try await server.requestAuthorization(for: "TV"), state = await server.currentState
            XCTAssertTrue(continued === authorization); XCTAssertTrue(authorization.isCurrent)
            XCTAssertEqual(state.approved.map(\.id), ["TV"])
            for operation in ["requestSubmit", "requestAnswer", "requestActivated", "requestDelivery"] {
                do {
                    _ = try await f.service.control(operation: operation,
                        payload: .init(request: request, requestID: job, answer: UUID().uuidString, sourceHash: request.context.sourceHash),
                        deviceID: "TV", authorization: authorization)
                    XCTFail("Uncertain revocation admitted " + operation)
                } catch { XCTAssertTrue(error.localizedDescription.contains("TV approval inspection requires recovery"), operation + ": " + error.localizedDescription) }
            }
            let status = try await f.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV", authorization: authorization)
            XCTAssertFalse(status.enabled); XCTAssertEqual(status.jobs.map(\.id), [job])
            let blocked = await f.service.allJobs(); XCTAssertEqual(blocked.map(\.id), [job])
            backend.failReads(false); backend.failWrites(.none)
            try await f.service.retryReconciliation()
            if mode == .unreadableAfter {
                XCTAssertFalse(authorization.isCurrent)
                do { _ = try await server.requestAuthorization(for: "TV"); XCTFail("Confirmed revocation retained access") }
                catch { XCTAssertTrue(error.localizedDescription.contains("revoked")) }
            } else {
                let restored = try await server.requestAuthorization(for: "TV")
                XCTAssertTrue(restored === authorization); XCTAssertTrue(restored.isCurrent)
                XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).approvals.first?.tokenHash, "old")
                _ = try await f.service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV", authorization: restored)
            }
        }
    }

    func testReplacingFailedProposalRetiresOnlySupersededCleanupDiagnostic() async throws {
        let broken = OutcomeSwitch(), retained = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        let a = try await fixture(reconcile: { _ in if broken.on { throw POSIXError(.EIO) } }), b = try await fixture()
        let backend = OutcomeBackend(try TrustedTVApprovals().encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, retainEvidence: { _, value in retained.on = value })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true)
        let first = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(first)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = true; first.eligibility.invalidate()
        await authority.withdraw(serverID: first.serverID, eligibility: first.eligibility)
        try await wait { let state = await authority.observation; return state.uninspectedTargets == 1 && state.uninspectedCleanupTasks == 0 }
        try await wait { await recorder.snapshot?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true }
        let failed = await recorder.snapshot
        XCTAssertTrue(failed?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service))); XCTFail("Replacement inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        let replaced = await recorder.snapshot
        XCTAssertFalse(replaced?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        XCTAssertTrue(replaced?.diagnostic?.contains(POSIXError(.EACCES).localizedDescription) == true)
        broken.on = false; backend.failReads(false)
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        let state = await authority.observation, snapshot = await recorder.snapshot
        XCTAssertNil(snapshot?.diagnostic); XCTAssertEqual(state.recoveryDiagnostics, 0)
        XCTAssertEqual(state.uninspectedTargets, 0); XCTAssertEqual(state.uninspectedCleanupTasks, 0)
        // A real reconciliation entry still pins the service independently.
        XCTAssertTrue(retained.on)
        try await a.service.retryReconciliation()
        try await wait { !retained.on }
        XCTAssertEqual(backend.writes, 0)
    }

    func testObsoleteCleanupCompletionCannotReplaceSuccessorFailure() async throws {
        let broken = OutcomeSwitch(), arm = OutcomeSwitch(), retained = OutcomeSwitch(), completed = OutcomePaths(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let recorder = TrustedOwnerRecorder(), backend = OutcomeBackend(try TrustedTVApprovals().encoded())
        let a = try await fixture(reconcile: { _ in if broken.on { throw POSIXError(.EIO) } }), b = try await fixture()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            retainEvidence: { _, value in retained.on = value }, cleanupCheckpoint: { id, point in
                if point == .willPublish, arm.take() { try? await gate.wait() }
                if point == .didPublish { completed.add(id.uuidString) }
            })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true)
        let first = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(first)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = true; arm.on = true; first.eligibility.invalidate()
        await authority.withdraw(serverID: first.serverID, eligibility: first.eligibility)
        try await wait { await gate.hasEntered }
        backend.failReads(true)
        let second = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(second)); XCTFail("Successor inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); second.eligibility.invalidate()
        await authority.withdraw(serverID: second.serverID, eligibility: second.eligibility)
        try await wait { completed.count == 1 }
        let successor = await recorder.snapshot, before = await authority.observation
        XCTAssertTrue(successor?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        await gate.release()
        try await wait { completed.count == 2 }
        let after = await recorder.snapshot, state = await authority.observation
        XCTAssertEqual(after?.diagnostic, successor?.diagnostic); XCTAssertEqual(after?.diagnosticID, successor?.diagnosticID)
        XCTAssertEqual(state.recoveryDiagnostics, before.recoveryDiagnostics)
        XCTAssertEqual(state.uninspectedTargets, 1); XCTAssertEqual(state.uninspectedCleanupTasks, 0); XCTAssertTrue(retained.on)
        broken.on = false
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        let repaired = await recorder.snapshot, clean = await authority.observation
        XCTAssertNil(repaired?.diagnostic); XCTAssertEqual(clean.recoveryDiagnostics, 0)
        XCTAssertTrue(retained.on)
        try await a.service.retryReconciliation()
        try await wait { !retained.on }
    }

    func testResolvedCleanupWithoutIntentClearsOnlyItsOwnErrorAndAuthorityPin() async throws {
        let broken = OutcomeSwitch(), retained = OutcomeSwitch()
        let a = try await fixture(reconcile: { _ in if broken.on { throw POSIXError(.EIO) } }), b = try await fixture(), backend = OutcomeBackend(try TrustedTVApprovals().encoded()), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, retainEvidence: { _, value in retained.on = value })
        let proposal = TrustedOwnerRecorder().owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let value = await authority.observation; return value.uninspectedTargets == 1 && value.uninspectedCleanupTasks == 0 }
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        let before = await recorder.snapshot
        XCTAssertTrue(before?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        broken.on = false; try await b.service.retryReconciliation()
        try await wait { let state = await authority.observation; return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 }
        let after = await recorder.snapshot, state = await authority.observation
        XCTAssertNil(after?.diagnostic); XCTAssertEqual(state.recoveryDiagnostics, 0)
        XCTAssertEqual(state.uninspectedTargets, 0); XCTAssertEqual(state.uninspectedCleanupTasks, 0)
        XCTAssertEqual(backend.writes, 0); XCTAssertFalse(retained.on)
    }
    func testCleanupAndApprovalPreserveExactUnresolvedInspectionOrigin() async throws {
        let a = try await fixture(), b = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder(), broken = OutcomeSwitch(), retained = OutcomeSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, retainEvidence: { _, value in retained.on = value }, beforeTargetInspection: { id in
            if id == b.service.runtimeID && broken.on { throw POSIXError(.ENOSPC) }
        })
        let binding = try await accepted(authority.register(recorder.owner(service: b.service))), proposal = TrustedOwnerRecorder().owner(service: a.service)
        backend.failReads(true)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed initial read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let value = await authority.observation; return value.uninspectedTargets == 0 && value.uninspectedCleanupTasks == 0 }
        let failed = await recorder.snapshot
        XCTAssertTrue(failed?.diagnostic?.contains(POSIXError(.ENOSPC).localizedDescription) == true)
        let reads = backend.reads
        _ = try await authority.approve(binding.permit) { .init(record: .init(id: "TV", name: "TV", tokenHash: "new"), token: "new", eligibility: .init()) }
        let afterWrite = await recorder.snapshot, state = await authority.observation
        XCTAssertEqual(backend.reads, reads)
        XCTAssertEqual(afterWrite?.diagnosticID, failed?.diagnosticID)
        XCTAssertTrue(afterWrite?.diagnostic?.contains(POSIXError(.ENOSPC).localizedDescription) == true)
        XCTAssertEqual(state.recoveryDiagnostics, 1); XCTAssertTrue(retained.on)
        let status = try await b.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
        XCTAssertFalse(status.enabled)
        broken.on = false; try await b.service.retryReconciliation()
        let repaired = await recorder.snapshot
        XCTAssertNil(repaired?.diagnostic); XCTAssertFalse(retained.on)
    }
    func testAcceptedRegistrationInspectionErrorSurvivesUnrelatedApproval() async throws {
        let a = try await fixture(), b = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder(), broken = OutcomeSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeTargetInspection: { id in
            if id == a.service.runtimeID && broken.on { throw POSIXError(.ENOSPC) }
        })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        broken.on = true
        let binding = try await accepted(authority.register(recorder.owner(service: b.service))), failed = await recorder.snapshot, reads = backend.reads
        _ = try await authority.approve(binding.permit) { .init(record: .init(id: "TV", name: "TV", tokenHash: "new"), token: "new", eligibility: .init()) }
        let after = await recorder.snapshot
        XCTAssertEqual(after?.diagnosticID, failed?.diagnosticID)
        XCTAssertTrue(after?.diagnostic?.contains(POSIXError(.ENOSPC).localizedDescription) == true)
        XCTAssertEqual(backend.reads, reads)
        broken.on = false; try await b.service.retryReconciliation()
        let repaired = await recorder.snapshot; XCTAssertNil(repaired?.diagnostic)
    }
    func testRejectedWritesKeepBoundedHistoryWithoutRetainingAuthority() async throws {
        let retained = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        let original = try TrustedTVApprovals(approvals: (0..<12).map { .init(id: "TV-" + String($0), name: "TV", tokenHash: "old") }).encoded()
        let backend = OutcomeBackend(original)
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { _ in throw ShaderRequestError.unavailable(String(repeating: "λ", count: 5000)) }, retainEvidence: { _, value in retained.on = value })
        let binding = try await accepted(authority.register(recorder.owner()))
        for i in 0..<12 {
            do { try await authority.revoke("TV-" + String(i), permit: binding.permit) { _ in }; XCTFail("Rejected write accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("λ")) }
        }
        let state = await authority.observation, snapshot = await recorder.snapshot, diagnostic = try XCTUnwrap(snapshot?.diagnostic)
        XCTAssertEqual(state.historicalDiagnostics, 8); XCTAssertEqual(state.recoveryDiagnostics, 0)
        XCTAssertEqual(state.writeReadbacks, 12); XCTAssertEqual(backend.bytes, original)
        XCTAssertLessThanOrEqual(diagnostic.utf8.count, 8192 + 8 * (2048 + 32))
        XCTAssertFalse(diagnostic.contains("�")); XCTAssertFalse(retained.on)
    }
    func testRecoveredApprovalCommitPreservesCredentialAndRequiresPairingAgain() async throws {
        let f = try await fixture(), backend = OutcomeBackend(try TrustedTVApprovals().encoded()), recorder = TrustedOwnerRecorder(), retained = OutcomeSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, retainEvidence: { _, value in retained.on = value })
        let binding = try await accepted(authority.register(recorder.owner(service: f.service))), eligibility = TrustedApprovalEligibility()
        backend.failWrites(.unreadableAfter)
        do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "TV", name: "TV", tokenHash: "new"), token: "new", eligibility: eligibility) }; XCTFail("Unknown approval accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        backend.failReads(false); backend.failWrites(.none)
        try await f.service.retryReconciliation()
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).approvals.map(\.tokenHash), ["new"])
        XCTAssertFalse(eligibility.canIssue)
        XCTAssertThrowsError(try eligibility.check()) { error in XCTAssertTrue(error.localizedDescription.contains("saved during recovery")) }
        let snapshot = await recorder.snapshot, state = await authority.observation
        XCTAssertTrue(snapshot?.diagnostic?.contains("Pair this TV again") == true)
        XCTAssertEqual(state.recoveryDiagnostics, 0); XCTAssertFalse(retained.on)
        XCTAssertEqual(backend.writes, 1)
    }

    func testBeforeBackendFailurePerformsNoUncertaintyReadback() async throws {
        let f = try await fixture(), backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()), fail = OutcomeSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeTrustedWrite: { if fail.on { throw POSIXError(.EIO) } })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service))), reads = backend.reads
        fail.on = true
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Before-backend failure accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        let state = await authority.observation
        XCTAssertEqual(state.writeReadbacks, 0); XCTAssertEqual(state.uncertainWrites, 0)
        XCTAssertEqual(backend.reads, reads); XCTAssertEqual(backend.writes, 0)
        _ = try await submit(f.service)
    }
    func testConflictingRecoveryPreservesActualBytesUntilExplicitManualRepair() async throws {
        let f = try await fixture(), original = try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()
        let backend = OutcomeBackend(original), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: f.service)))
        backend.failWrites(.conflict)
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Conflicting write accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("manual repair")) }
        let conflicting = backend.bytes
        backend.failWrites(.none)
        do { try await f.service.retryReconciliation(); XCTFail("Conflicting bytes silently accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("manual repair")) }
        XCTAssertEqual(backend.bytes, conflicting)
        let blocked = await authority.observation; XCTAssertEqual(blocked.uncertainWrites, 1)
        try backend.write(original) // Explicit fixture-side manual restoration, never a compensating host write.
        try await f.service.retryReconciliation()
        let repaired = await authority.observation, snapshot = await recorder.snapshot
        XCTAssertEqual(repaired.uncertainWrites, 0); XCTAssertEqual(repaired.recoveryDiagnostics, 0)
        XCTAssertFalse(snapshot?.diagnostic?.contains("unverified") == true)
        XCTAssertTrue(snapshot?.diagnostic?.contains("did not commit") == true)
        XCTAssertEqual(backend.bytes, original)
    }
    func testCancellationCannotAbandonAdmittedReadbackOrDurableCompletion() async throws {
        let f = try await fixture(), job = try await submit(f.service), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: f.service)))
        backend.arm(gate); backend.failWrites(.after)
        let result = OutcomeResult<Void>(), task = Task { do { try await authority.revoke("TV", permit: binding.permit) { _ in }; result.value = .success(()) } catch { result.value = .failure(error) } }
        addTeardownBlock { task.cancel(); gate.release() }
        try await wait { gate.entered }
        task.cancel()
        XCTAssertEqual(backend.writes, 1)
        let active = await authority.observation; XCTAssertTrue(active.transitionActive)
        backend.arm(nil); gate.release()
        try await wait { let value = await authority.observation; return result.value != nil && value.obligations == 0 && value.revocationCompletionTasks == 0 }
        if case .failure(let error) = result.value { XCTAssertTrue(error is CancellationError) }
        let state = await authority.observation, jobs = await f.service.allJobs(), bytes = try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes))
        XCTAssertEqual(state.writeReadbacks, 2); XCTAssertEqual(state.uncertainWrites, 0)
        XCTAssertTrue(bytes.approvals.isEmpty); XCTAssertTrue(bytes.revocations.isEmpty)
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
    }

    func testCommittedRemovalRetainsUninspectedCancellationEvidence() async throws {
        try await retainedRemovalTarget(withdraw: false)
    }
    func testWithdrawnTargetCancelsCommittedRemovalBeforeRetirement() async throws {
        try await retainedRemovalTarget(withdraw: true)
    }
    private func retainedRemovalTarget(withdraw: Bool) async throws {
        let a = try await fixture(), b = try await fixture(), job = try await submit(b.service)
        let broken = OutcomeSwitch(), finalized = OutcomePaths(), recorder = TrustedOwnerRecorder()
        broken.on = true
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeRemovalFinalization: { _, target in
                if broken.on { throw POSIXError(.EIO) }
                finalized.add(target.uuidString)
            })
        let binding = try await accepted(authority.register(recorder.owner(service: a.service)))
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Finalization failure hidden") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let committed = backend.bytes
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(committed)).revocations.isEmpty)
        backend.failReads(true)
        let proposal = TrustedOwnerRecorder().owner(service: b.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Uninspected target accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = false
        if withdraw {
            proposal.eligibility.invalidate()
            await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
            try await wait { let state = await authority.observation; return state.uninspectedCleanupTasks == 0 && state.uninspectedTargets == 0 }
        } else {
            for _ in 0..<2 {
                do { try await authority.replay(); XCTFail("Uninspected obligation forgotten") }
                catch { XCTAssertTrue(error.localizedDescription.contains("proposed request service")) }
            }
            let pending = await authority.observation
            XCTAssertEqual(pending.obligations, 1)
            XCTAssertEqual(finalized.count, 1, "Known target finalized more than once")
            _ = try await accepted(authority.register(recorder.owner(service: b.service)))
            try await authority.replay()
        }
        let jobs = await b.service.allJobs(), final = await authority.observation
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(final.obligations, 0); XCTAssertEqual(final.uninspectedTargets, 0)
        XCTAssertEqual(backend.bytes, committed, "Already-committed removal rewritten")
        XCTAssertEqual(backend.writes, 2)
    }

    func testHealthyRecoveryDoesNotWaitForUnrelatedWithdrawnCleanup() async throws {
        let blocked = OutcomeSwitch(), gate = RecoveryGate(), backend = OutcomeBackend()
        let a = try await fixture(reconcile: { _ in if blocked.on { try await gate.wait() } }), b = try await fixture()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        backend.failReads(true)
        let proposal = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); blocked.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await gate.hasEntered }
        let result = OutcomeResult<Void>(), retry = Task {
            do { try await b.service.retryReconciliation(); result.value = .success(()) }
            catch { result.value = .failure(error) }
        }
        addTeardownBlock { retry.cancel(); await gate.release() }
        try await wait { result.value != nil }
        try XCTUnwrap(result.value).get()
        let pending = await authority.observation
        XCTAssertEqual(pending.uninspectedCleanupTasks, 1)
        blocked.on = false; await gate.release()
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        let guidance = await a.service.recoveryStatuses()
        XCTAssertTrue(guidance.contains { $0.message.contains("Register a local catalog server") })
    }
    func testHealthyRecoveryKeepsUnrelatedCleanupFailureSeparate() async throws {
        let broken = OutcomeSwitch(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let a = try await fixture(reconcile: { _ in if broken.on { throw POSIXError(.EIO) } }), b = try await fixture()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true); let proposal = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); broken.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        try await b.service.retryReconciliation()
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        let snapshot = await recorder.snapshot
        XCTAssertTrue(snapshot?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        do { try await a.service.retryReconciliation(); XCTFail("Failed participant reported complete") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Withdrawn proposal"))
            XCTAssertFalse(error.localizedDescription.contains("Explicitly register its intended server"))
        }
    }
    func testFailedWithdrawnCleanupStillReplaysFreshAcceptedTargetIntents() async throws {
        let broken = OutcomeSwitch(), armRead = OutcomeSwitch(), backend = OutcomeBackend()
        let a = try await fixture(), b = try await fixture(beforeWrite: { url in
            if broken.on && url.lastPathComponent == "journal.json" { throw POSIXError(.EIO) }
        })
        let job = try await submit(a.service); _ = try await submit(b.service)
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeInspectionRead: { if armRead.take() { broken.on = true } })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        backend.failReads(true); let proposal = TrustedOwnerRecorder().owner(service: b.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false)
        try backend.write(TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        armRead.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait {
            let jobs = await a.service.allJobs(), state = await authority.observation
            return state.uninspectedCleanupTasks == 0 && jobs.first { $0.id == job }?.stage == .cancelled
        }
        let retained = await authority.observation
        XCTAssertEqual(retained.uninspectedTargets, 1); XCTAssertEqual(retained.obligations, 1)
    }
    func testRecoveryRetriesLiveFailedCrossAuthorityProposal() async throws {
        let a = try await fixture(), b = try await fixture(), sourceStore = OutcomeBackend(), destinationStore = OutcomeBackend()
        let source = TrustedApprovalsCoordinator(read: { try sourceStore.read() }, write: { try sourceStore.write($0) })
        let destination = TrustedApprovalsCoordinator(read: { try destinationStore.read() }, write: { try destinationStore.write($0) })
        let old = try await accepted(source.register(TrustedOwnerRecorder().owner(service: a.service)))
        _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: b.service)))
        destinationStore.failReads(true)
        let recorder = TrustedOwnerRecorder(), proposal = recorder.owner(service: a.service)
        do { _ = try await accepted(destination.register(proposal)); XCTFail("Failed destination accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        let before = await destination.observation
        XCTAssertTrue(old.permit.isCurrent)
        destinationStore.failReads(false); try await b.service.retryReconciliation()
        let after = await destination.observation
        XCTAssertGreaterThan(after.requestedGeneration, before.requestedGeneration)
        let moved = await recorder.binding, retired = await source.observation
        XCTAssertEqual(moved?.permit.authority, destination.id)
        XCTAssertTrue(moved?.permit.isCurrent == true); XCTAssertEqual(retired.targets, 0)
    }
    func testOtherAuthorityWaitsForExactWithdrawnRetirement() async throws {
        let blocked = OutcomeSwitch(), gate = RecoveryGate(), backend = OutcomeBackend()
        let a = try await fixture(reconcile: { _ in if blocked.on { try await gate.wait() } }), b = try await fixture()
        addTeardownBlock { await gate.release() }
        let old = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(old.register(TrustedOwnerRecorder().owner(service: b.service)))
        backend.failReads(true); let proposal = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(old.register(proposal)); XCTFail("Failed read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false); blocked.on = true; proposal.eligibility.invalidate()
        await old.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await gate.hasEntered }
        let new = TrustedApprovalsCoordinator(read: { nil }, write: { _ in })
        let registration = try await new.register(TrustedOwnerRecorder().owner(service: a.service))
        addTeardownBlock { registration.completion.cancel(); await gate.release() }
        try await wait { await new.observation.preparingGeneration == registration.generation }
        XCTAssertFalse(registration.completion.hasStarted)
        blocked.on = false; await gate.release()
        let binding = try await accepted(registration)
        XCTAssertTrue(binding.permit.isCurrent)
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
