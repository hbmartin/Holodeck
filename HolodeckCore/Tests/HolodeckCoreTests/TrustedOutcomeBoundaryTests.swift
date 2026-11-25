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
    func coordinator() -> TrustedApprovalsCoordinator { .init(read: { try self.read() }, write: { try self.write($0) }) }
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
    private struct RegistrationObservation {
        let ticket: RequestPersistence.CommitTicket<TrustedApprovalsCoordinator.BindingOutcome>
        let result: OutcomeResult<TrustedApprovalsCoordinator.BindingOutcome>
        let relay: Task<Void, Never>
    }
    private var registrationObservations: [ObjectIdentifier: RegistrationObservation] = [:]
    override func tearDown() async throws {
        // XCTest runs gate-release teardown blocks first. One owner cancellation
        // per ticket then drains its sole relay; observers never cancel owners.
        for value in registrationObservations.values { value.ticket.cancel(); value.relay.cancel() }
        try await wait { self.registrationObservations.values.allSatisfy { $0.result.value != nil } }
        registrationObservations.removeAll()
        try await super.tearDown()
    }
    func accepted(_ ticket: TrustedApprovalsCoordinator.Registration, timeout: Duration = .seconds(8)) async throws -> TrustedApprovalsCoordinator.Binding {
        let key = ObjectIdentifier(ticket.completion)
        let result: OutcomeResult<TrustedApprovalsCoordinator.BindingOutcome>
        if let observation = registrationObservations[key] { result = observation.result }
        else {
            result = OutcomeResult()
            let relay = Task {
                do { result.value = .success(try await ticket.completion.value(cancellable: false)) }
                catch { result.value = .failure(error) }
            }
            registrationObservations[key] = .init(ticket: ticket.completion, result: result, relay: relay)
        }
        // Repeated/concurrent observers share the one completion subscription.
        // Poll cancellation and timeout affect only this caller's observation.
        try await wait(timeout: timeout) { result.value != nil }
        try Task.checkCancellation()
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
        XCTAssertEqual(state.obligations, 0); XCTAssertEqual(state.uninspectedTargets, 1)
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
        if case .failure(let error) = result.value { XCTAssertTrue(error.localizedDescription.contains("Withdrawn TV proposal cleanup")) }
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
            XCTAssertEqual((error as? any TrustedReportedDiagnostic)?.diagnosticID, uncertain?.diagnosticID)
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
        try await wait { await authority.observation.uninspectedCleanupTasks == 2 }
        XCTAssertEqual(completed.count, 0, "Successor bypassed the predecessor's physical completion")
        let before = await recorder.snapshot
        XCTAssertFalse(before?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        await gate.release()
        try await wait { completed.count == 2 }
        let after = await recorder.snapshot, state = await authority.observation
        XCTAssertTrue(after?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        XCTAssertFalse(after?.diagnostic?.contains("ownership changed") == true)
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
        XCTAssertNil(snapshot?.diagnostic) // Successful recovery clears settled write history.
        XCTAssertEqual(state.recoveryDiagnostics, 0); XCTAssertTrue(retained.on)
        let notice = try XCTUnwrap(snapshot?.notices.first)
        XCTAssertTrue(notice.message.contains("Pair this TV again"))
        try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision, permit: binding.permit)
        XCTAssertFalse(retained.on)
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
        XCTAssertNil(snapshot?.diagnostic)
        XCTAssertEqual(snapshot?.notices.count, 1)
        XCTAssertTrue(snapshot?.notices.first?.message.contains("remains approved") == true)
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
            XCTAssertEqual(pending.obligations, 0)
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
        let unrelated = await destination.observation
        XCTAssertEqual(unrelated.requestedGeneration, before.requestedGeneration)
        let unmoved = await recorder.binding; XCTAssertNil(unmoved)
        try await a.service.retryReconciliation()
        let after = await destination.observation
        XCTAssertGreaterThan(after.requestedGeneration, before.requestedGeneration)
        try await wait { await source.observation.targets == 0 }
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
        let destinationStore = OutcomeBackend(), new = TrustedApprovalsCoordinator(read: { try destinationStore.read() }, write: { try destinationStore.write($0) })
        let current = try await accepted(new.register(TrustedOwnerRecorder().owner()))
        let registration = try await new.register(TrustedOwnerRecorder().owner(service: a.service))
        addTeardownBlock { registration.completion.cancel(); await gate.release() }
        try await wait { await new.observation.preparingGeneration == registration.generation }
        XCTAssertFalse(registration.completion.hasStarted)
        _ = try await new.approve(current.permit) { .init(record: .init(id: "DESTINATION", name: "Destination TV", tokenHash: "new"), token: "new", eligibility: .init()) }
        XCTAssertEqual(destinationStore.writes, 1)
        XCTAssertTrue(current.permit.isCurrent)
        blocked.on = false; await gate.release()
        let binding = try await accepted(registration)
        XCTAssertTrue(binding.permit.isCurrent)
    }

    func testSettledWriteHistoryClearsOnSuccessfulWriteAndRecovery() async throws {
        let f = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: f.service)))
        for recover in [false, true] {
            backend.failWrites(.before)
            do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "OLD", name: "OLD", tokenHash: "h"), token: "t", eligibility: .init()) }; XCTFail("Rejected write accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
            let rejected = await authority.observation; XCTAssertEqual(rejected.historicalDiagnostics, 1)
            backend.failWrites(.none)
            if recover { try await f.service.retryReconciliation() }
            else { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "NEW", name: "NEW", tokenHash: "h"), token: "t", eligibility: .init()) } }
            let clean = await authority.observation, snapshot = await recorder.snapshot
            XCTAssertEqual(clean.historicalDiagnostics, 0); XCTAssertNil(snapshot?.diagnostic)
        }
    }
    func testLiveRecoveryDiagnosticPrecedesRejectedWriteHistory() async throws {
        let a = try await fixture(), b = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: a.service)))
        backend.failWrites(.before)
        do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "OLD", name: "OLD", tokenHash: "h"), token: "t", eligibility: .init()) }; XCTFail("Rejected write accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let old = await recorder.snapshot
        backend.failReads(true)
        do { _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b.service))); XCTFail("Read failure accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        let current = await recorder.snapshot
        XCTAssertNotEqual(current?.diagnosticID, old?.diagnosticID)
        XCTAssertTrue(current?.diagnostic?.contains("Trusted TV storage inspection") == true)
    }
    func testCancelledSuccessorCannotEvadeWriteHistoryBound() async throws {
        let reject = OutcomeSwitch(), cancel = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { nil }, write: { _ in }, beforeTrustedWrite: {
            if cancel.on { throw CancellationError() }; if reject.on { throw POSIXError(.EIO) }
        })
        let binding = try await accepted(authority.register(recorder.owner()))
        reject.on = true
        for index in 0..<12 {
            let device = "TV-" + String(index)
            do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: device, name: device, tokenHash: "h"), token: "t", eligibility: .init()) }; XCTFail("Rejected write accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
            cancel.on = true
            do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: device, name: device, tokenHash: "h"), token: "t", eligibility: .init()) }; XCTFail("Cancelled write accepted") }
            catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
            cancel.on = false
        }
        let state = await authority.observation
        XCTAssertEqual(state.historicalDiagnostics, 8); XCTAssertEqual(state.recoveryDiagnostics, 0)
        XCTAssertEqual(state.encodings, 24); XCTAssertEqual(state.writes, 0)
    }
    func testCancelledRecoveryReadDoesNotAppendStorageFailure() async throws {
        let f = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: f.service)))
        backend.failWrites(.unreadableAfter)
        do { _ = try await authority.approve(binding.permit) { .init(record: .init(id: "TV", name: "TV", tokenHash: "h"), token: "t", eligibility: .init()) }; XCTFail("Unknown write accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        let original = await recorder.snapshot
        backend.failReads(false); backend.failWrites(.none); backend.arm(gate)
        let retry = Task { try await f.service.retryReconciliation() }
        addTeardownBlock { retry.cancel(); gate.release() }
        try await wait { gate.entered }
        retry.cancel()
        do { try await retry.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
        try await wait { let state = await authority.observation; return state.recoveryParticipants == 0 && state.rawReadSubscribers == 0 }
        let current = await recorder.snapshot, state = await authority.observation
        XCTAssertEqual(current?.diagnostic, original?.diagnostic); XCTAssertEqual(current?.diagnosticID, original?.diagnosticID)
        XCTAssertEqual(state.uncertainWrites, 1)
        backend.arm(nil); gate.release()
        try await f.service.retryReconciliation()
    }
    func testUncertainRemovalStopsReplayWithoutPerIntentFailures() async throws {
        let f = try await fixture(), a = try await submit(f.service, device: "A"), b = try await submit(f.service, device: "B")
        let first = RequestRevocationIntent(operationID: UUID(), deviceID: "A"), second = RequestRevocationIntent(operationID: UUID(), deviceID: "B")
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [first, second]).encoded()), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(authority.register(recorder.owner(service: f.service)))
        backend.failWrites(.unreadableAfter)
        do { try await authority.replay(); XCTFail("Uncertain removal accepted") }
        catch { XCTAssertEqual((error as? any TrustedReportedDiagnostic)?.diagnosticID, first.operationID) }
        let snapshot = await recorder.snapshot, jobs = await f.service.allJobs(), pending = await authority.observation
        XCTAssertFalse(snapshot?.diagnostic?.contains("Trusted TV intent") == true)
        XCTAssertEqual(jobs.first { $0.id == a }?.stage, .cancelled)
        XCTAssertEqual(jobs.first { $0.id == b }?.stage, .queued)
        XCTAssertEqual(pending.applicationRecoveryTargets, 0); XCTAssertEqual(pending.obligations, 2)
        backend.failReads(false); backend.failWrites(.none)
        try await f.service.retryReconciliation()
        let done = await f.service.allJobs(), clean = await authority.observation
        XCTAssertEqual(done.first { $0.id == b }?.stage, .cancelled)
        XCTAssertEqual(clean.obligations, 0); XCTAssertEqual(clean.uncertainWrites, 0)
    }
    func testRecoveredApprovalNotificationIsExactAndAtMostOnce() async throws {
        let callbacks = OutcomePaths(), eligibility = TrustedApprovalEligibility(recovered: { callbacks.add($0.uuidString) })
        try eligibility.beginWrite()
        await eligibility.recoveredWithoutDelivery(); await eligibility.recoveredWithoutDelivery()
        XCTAssertEqual(callbacks.count, 1); XCTAssertFalse(eligibility.canIssue)
        let closed = TrustedApprovalEligibility(recovered: { callbacks.add($0.uuidString) })
        try closed.beginWrite(); closed.close(); await closed.recoveredWithoutDelivery()
        XCTAssertEqual(callbacks.count, 1)
    }

    func testPreAdmissionObservationTimeoutCannotCancelRegistration() async throws {
        let f = try await fixture(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { nil }, write: { _ in }, beforeTargetActivation: { _ in try await gate.wait() })
        let ticket = try await authority.register(TrustedOwnerRecorder().owner(service: f.service))
        addTeardownBlock { ticket.completion.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        do { _ = try await accepted(ticket, timeout: .milliseconds(20)); XCTFail("Held registration completed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Outcome boundary backstop")) }
        XCTAssertFalse(ticket.completion.hasStarted)
        let cancelled = Task { try await self.accepted(ticket) }
        await Task.yield(); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Observer ignored cancellation") } catch is CancellationError {}
        let first = Task { try await self.accepted(ticket) }, second = Task { try await self.accepted(ticket) }
        addTeardownBlock { first.cancel(); second.cancel(); await gate.release() }
        await gate.release()
        let a = try await first.value, b = try await second.value
        XCTAssertTrue(a.permit === b.permit); XCTAssertTrue(a.permit.isCurrent)
        XCTAssertEqual(registrationObservations.count, 1)
    }

    func testCleanupCompletionRescansAnAlreadyAttemptedRemoval() async throws {
        let read = OutcomeSwitch(), armWrite = OutcomeSwitch(), write = TrustedReadGate(), publication = RecoveryGate(), incorrectAdvice = OutcomeSwitch()
        let a = try await fixture(beforeWrite: { url in if url.lastPathComponent == "journal.json", armWrite.take() { write.wait() } }), b = try await fixture()
        addTeardownBlock { write.release(); await publication.release(); XCTAssertFalse(write.timedOut, "Writer barrier expired instead of being released") }
        _ = try await submit(a.service); let job = try await submit(b.service)
        let backend = OutcomeBackend(), server = UUID()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeInspectionRead: { if read.take() { armWrite.on = true } })
        let owner = TrustedApprovalsCoordinator.Owner(serverID: server, service: b.service, changed: { snapshot, _ in
            if snapshot.diagnostic?.contains("Withdrawn TV proposal cleanup") == true {
                incorrectAdvice.on = snapshot.diagnostic?.contains("Explicitly register") == true
                try? await publication.wait()
            }
        }, retired: {}, beforeReplay: { _ in })
        _ = try await accepted(authority.register(owner))
        backend.failReads(true); let proposal = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed inspection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        backend.failReads(false)
        try backend.write(TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        read.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let notified = await publication.hasEntered; return write.entered && notified }
        XCTAssertFalse(incorrectAdvice.on)
        // The old replay has rejected removal but still owns its notification.
        // Let cleanup queue its exact completion before releasing that lane.
        write.release()
        try await wait { await authority.observation.progressWaiters > 0 }
        await publication.release()
        try await wait {
            let state = await authority.observation
            return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 && state.obligations == 0
        }
        let jobs = await b.service.allJobs()
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 2) // One fixture-side insertion and one removal.
    }

    func testStaleCleanupAdmissionCannotReplaceSuccessorTask() async throws {
        let gate = RecoveryGate(), arm = OutcomeSwitch(), completed = OutcomePaths(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let a = try await fixture(), b = try await fixture()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, cleanupCheckpoint: { id, point in
            if point == .willAdmit, arm.take() { try? await gate.wait() }
            if point == .didPublish { completed.add(id.uuidString) }
        })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true); let first = recorder.owner(service: a.service)
        do { _ = try await accepted(authority.register(first)); XCTFail("Inspection accepted") } catch { XCTAssertTrue(error is POSIXError) }
        backend.failReads(false); arm.on = true; first.eligibility.invalidate()
        await authority.withdraw(serverID: first.serverID, eligibility: first.eligibility)
        try await wait { await gate.hasEntered }
        backend.failReads(true); let successor = recorder.owner(service: a.service)
        do { _ = try await accepted(authority.register(successor)); XCTFail("Inspection accepted") } catch { XCTAssertTrue(error is POSIXError) }
        backend.failReads(false); successor.eligibility.invalidate()
        await authority.withdraw(serverID: successor.serverID, eligibility: successor.eligibility)
        let held = await authority.observation
        XCTAssertEqual(held.uninspectedCleanupTasks, 2)
        await gate.release()
        try await wait { let state = await authority.observation; return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 }
        XCTAssertEqual(completed.count, 1, "The stale proposal must never admit service work")
        let snapshot = await recorder.snapshot
        XCTAssertNil(snapshot?.diagnostic)
    }

    func testLateParticipantWithdrawalCannotEscapeCleanupFailure() async throws {
        let sealing = RecoveryGate(), cleanup = RecoveryGate(), backend = OutcomeBackend(), a = try await fixture(), b = try await fixture()
        addTeardownBlock { await sealing.release(); await cleanup.release() }
        let recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeRecoverySealing: { try await sealing.wait() }, cleanupCheckpoint: { _, point in
                if point == .willPublish { try? await cleanup.wait() }
            })
        let owner = recorder.owner(service: b.service)
        _ = try await accepted(authority.register(owner))
        backend.failReads(true); let proposal = recorder.owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Inspection accepted") } catch { XCTAssertTrue(error is POSIXError) }
        backend.failReads(false); _ = try await accepted(authority.register(owner))
        let first = OutcomeResult<Void>(), second = OutcomeResult<Void>()
        let one = Task { do { try await b.service.retryReconciliation(); first.value = .success(()) } catch { first.value = .failure(error) } }
        addTeardownBlock { one.cancel(); await sealing.release(); await cleanup.release() }
        try await wait { await sealing.hasEntered }
        let two = Task { do { try await a.service.retryReconciliation(); second.value = .success(()) } catch { second.value = .failure(error) } }
        addTeardownBlock { two.cancel(); await sealing.release(); await cleanup.release() }
        try await wait { await authority.observation.recoveryParticipants == 2 }
        backend.failReads(true); proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await cleanup.hasEntered }
        await sealing.release()
        // Admission is witnessed: the sealed pass subscribes to this exact cleanup.
        try await wait { await authority.observation.recoveryCleanupWaiters > 0 }
        XCTAssertNil(first.value); XCTAssertNil(second.value)
        await cleanup.release()
        try await wait { first.value != nil && second.value != nil }
        for result in [first.value, second.value] {
            guard case .failure(let error) = result else { XCTFail("Participant cleanup failure was reported as success"); continue }
            XCTAssertTrue(error.localizedDescription.contains("Withdrawn proposal"))
        }
    }

    func testFinalizedTargetCanDepartWhileUninspectedEvidenceRemains() async throws {
        let a = try await fixture(), b = try await fixture(), job = try await submit(b.service), fail = OutcomeSwitch()
        let backend = OutcomeBackend(try TrustedTVApprovals(revocations: [.init(operationID: UUID(), deviceID: "TV")]).encoded())
        fail.on = true
        let source = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeRemovalFinalization: { _, _ in if fail.on { throw POSIXError(.EIO) } })
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: a.service)))
        do { try await source.replay(); XCTFail("Finalization fault ignored") } catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        backend.failReads(true); let proposal = TrustedOwnerRecorder().owner(service: b.service)
        do { _ = try await accepted(source.register(proposal)); XCTFail("Inspection accepted") } catch { XCTAssertTrue(error is POSIXError) }
        backend.failReads(false); fail.on = false
        do { try await source.replay(); XCTFail("Unknown target forgotten") } catch { XCTAssertTrue(error.localizedDescription.contains("proposed request service")) }
        let settled = await source.observation; XCTAssertEqual(settled.obligations, 0); XCTAssertEqual(settled.uninspectedTargets, 1)
        let destination = TrustedApprovalsCoordinator(read: { nil }, write: { _ in })
        let binding = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: a.service)))
        XCTAssertEqual(binding.permit.authority, destination.id)
        proposal.eligibility.invalidate(); await source.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { let state = await source.observation; return state.uninspectedTargets == 0 && state.uninspectedCleanupTasks == 0 }
        let jobs = await b.service.allJobs(); XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(backend.writes, 1)
    }

    @discardableResult private func recoveredApprovalNotice(_ service: ShaderRequestService, authority: TrustedApprovalsCoordinator,
        backend: OutcomeBackend, permit: TrustedOwnerPermit, device: String) async throws -> UUID {
        let eligibility = TrustedApprovalEligibility()
        backend.failWrites(.unreadableAfter)
        do { _ = try await authority.approve(permit) { .init(record: .init(id: device, name: device, tokenHash: eligibility.id.uuidString), token: "lost", eligibility: eligibility) }; XCTFail("Unknown approval accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        backend.failReads(false); backend.failWrites(.none)
        try await service.retryReconciliation()
        return eligibility.id
    }
    func testRecoveredNoncommitNoticeRequiresExactExplicitDismissal() async throws {
        let a = try await fixture(), backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: a.service)))
        backend.failWrites(.unreadableBefore)
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Unknown revocation accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        backend.failReads(false); backend.failWrites(.none)
        try await a.service.retryReconciliation()
        let recovered = await recorder.snapshot, notice = try XCTUnwrap(recovered?.notices.first)
        XCTAssertEqual(recovered?.approvals["TV"]?.tokenHash, "old")
        XCTAssertTrue(notice.message.contains("remains approved")); XCTAssertNil(recovered?.diagnostic)
        try await a.service.retryReconciliation()
        _ = try await authority.approve(binding.permit) { .init(record: .init(id: "OTHER", name: "Other", tokenHash: "h"), token: "t", eligibility: .init()) }
        let saved = await recorder.snapshot; XCTAssertEqual(saved?.notices.first, notice)
        let before = await authority.observation
        try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision + 1, permit: binding.permit)
        let stale = await recorder.snapshot; XCTAssertEqual(stale?.notices.first, notice)
        try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision, permit: binding.permit)
        let after = await authority.observation, dismissed = await recorder.snapshot
        XCTAssertTrue(dismissed?.notices.isEmpty == true)
        XCTAssertEqual(after.encodings, before.encodings); XCTAssertEqual(after.writes, before.writes)
    }
    func testRecoveryNoticesSurviveReplacementAndRejectRetiredDismissal() async throws {
        let a = try await fixture(), backend = OutcomeBackend(), first = TrustedOwnerRecorder(), second = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let old = try await accepted(authority.register(first.owner(service: a.service)))
        let operation = try await recoveredApprovalNotice(a.service, authority: authority, backend: backend, permit: old.permit, device: "A")
        let firstSnapshot = await first.snapshot
        let original = try XCTUnwrap(firstSnapshot?.notices.first)
        let next = try await accepted(authority.register(second.owner(service: a.service)))
        let current = await second.snapshot
        XCTAssertEqual(current?.notices.first?.id, operation); XCTAssertEqual(current?.notices.first, original)
        do { try await authority.dismissRecoveryNotice(original.id, revision: original.revision, permit: old.permit); XCTFail("Retired permit dismissed notice") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        try await authority.dismissRecoveryNotice(original.id, revision: original.revision, permit: next.permit)
        let cleared = await second.snapshot; XCTAssertTrue(cleared?.notices.isEmpty == true)
    }
    func testNoticeOverflowKeepsBoundedExplicitlyDismissibleSummary() async throws {
        let a = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: a.service)))
        for index in 0..<10 {
            try await recoveredApprovalNotice(a.service, authority: authority, backend: backend, permit: binding.permit, device: "TV-" + String(index))
            if index == 7 {
                let snapshot = await recorder.snapshot
                XCTAssertTrue(snapshot?.notices.contains { $0.deviceID == nil && $0.message.contains("1 saved approval without token delivery") } == true)
            }
        }
        let before = await recorder.snapshot, summary = try XCTUnwrap(before?.notices.first { $0.deviceID == nil })
        XCTAssertEqual(before?.notices.count, 8); XCTAssertTrue(summary.message.contains("3 saved approvals"))
        try await recoveredApprovalNotice(a.service, authority: authority, backend: backend, permit: binding.permit, device: "LATEST")
        try await authority.dismissRecoveryNotice(summary.id, revision: summary.revision, permit: binding.permit)
        let updated = await recorder.snapshot
        XCTAssertTrue(updated?.notices.contains { $0.id == summary.id && $0.message.contains("4 saved approvals") } == true)
        for notice in updated?.notices ?? [] { try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision, permit: binding.permit) }
        let empty = await recorder.snapshot; XCTAssertTrue(empty?.notices.isEmpty == true)
        XCTAssertEqual(backend.writes, 11)
    }
    func testNoticeRetentionDoesNotPinAnIdleRequestService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notice-release-" + UUID().uuidString), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder(), retained = OutcomeSwitch()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, retainEvidence: { _, flag in retained.on = flag })
        func create() async throws -> (WeakRequestService, TrustedOwnerPermit) {
            let target = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root)
            await target.suspend(); try await target.initialize(configuration: .init(repository: root.path))
            let binding = try await accepted(authority.register(recorder.owner(service: target)))
            try await recoveredApprovalNotice(target, authority: authority, backend: backend, permit: binding.permit, device: "TV")
            return (.init(target), binding.permit)
        }
        let (weak, permit) = try await create()
        try await wait { weak.value == nil }
        let state = await authority.observation; XCTAssertEqual(state.recoveryPins, 0); XCTAssertTrue(retained.on)
        let snapshot = await recorder.snapshot
        for notice in snapshot?.notices ?? [] { try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision, permit: permit) }
        XCTAssertFalse(retained.on)
    }

    func testInitialRegistrationShowsInspectionProgressWithoutAnotherRegistrationPrompt() async throws {
        let a = try await fixture(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { nil }, write: { _ in }, beforeInspectionRead: { try await gate.wait() })
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: a.service))
        addTeardownBlock { registration.completion.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let reply = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
        XCTAssertTrue(reply.message.contains("registration is inspecting"))
        XCTAssertFalse(reply.message.contains("Register a local catalog server"))
        await gate.release(); _ = try await accepted(registration)
    }

    func testSupersedingFailedRegistrationRetiresOnlyItsExactRecoveryRoute() async throws {
        let a = try await fixture(), b = try await fixture(), sourceStore = OutcomeBackend(), destinationStore = OutcomeBackend()
        let source = TrustedApprovalsCoordinator(read: { try sourceStore.read() }, write: { try sourceStore.write($0) })
        let destination = TrustedApprovalsCoordinator(read: { try destinationStore.read() }, write: { try destinationStore.write($0) })
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: a.service)))
        _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: b.service)))
        destinationStore.failReads(true)
        do { _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: a.service))); XCTFail("Failed destination accepted") }
        catch { XCTAssertTrue(error is POSIXError) }
        let pending = await a.service.recoveryStatuses(); XCTAssertTrue(pending.contains { $0.id == destination.id && !$0.blocksCheckoutWork })
        destinationStore.failReads(false)
        _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: b.service)))
        try await wait { await !a.service.recoveryStatuses().contains { $0.id == destination.id } }
        let before = await destination.observation.requestedGeneration
        try await a.service.retryReconciliation()
        let after = await destination.observation.requestedGeneration; XCTAssertEqual(before, after)
    }

    func testOneRecoveryPassDoesNotRestartCompletedUnrelatedCleanup() async throws {
        let broken = OutcomeSwitch(), attempts = OutcomePaths(), sealing = RecoveryGate(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let a = try await fixture(reconcile: { _ in if broken.on { attempts.add("cleanup"); throw POSIXError(.EIO) } }), b = try await fixture()
        addTeardownBlock { await sealing.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) }, beforeRecoverySealing: { try await sealing.wait() })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true); let proposal = recorder.owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Inspection accepted") } catch { XCTAssertTrue(error is POSIXError) }
        backend.failReads(false); broken.on = true; proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        let before = attempts.count, retry = Task { try await b.service.retryReconciliation() }
        addTeardownBlock { retry.cancel(); await sealing.release() }
        try await wait { await sealing.hasEntered }
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        await sealing.release(); try await retry.value
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        XCTAssertEqual(attempts.count - before, 1)
    }

    func testDismissingAnOlderNoticeCannotClearLiveWriteUncertainty() async throws {
        let a = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let binding = try await accepted(authority.register(recorder.owner(service: a.service)))
        let prior = try await recoveredApprovalNotice(a.service, authority: authority, backend: backend, permit: binding.permit, device: "TV")
        let saved = await recorder.snapshot, notice = try XCTUnwrap(saved?.notices.first { $0.id == prior })
        backend.failWrites(.unreadableBefore)
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Unknown revoke accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified")) }
        let before = await authority.observation
        try await authority.dismissRecoveryNotice(notice.id, revision: notice.revision, permit: binding.permit)
        let pending = await recorder.snapshot, state = await authority.observation
        XCTAssertTrue(pending?.notices.isEmpty == true); XCTAssertTrue(pending?.diagnostic?.contains("unverified") == true)
        XCTAssertEqual(state.uncertainWrites, 1); XCTAssertEqual(state.writes, before.writes); XCTAssertEqual(state.encodings, before.encodings)
        let reply = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
        XCTAssertFalse(reply.enabled)
        backend.failReads(false); backend.failWrites(.none); try await a.service.retryReconciliation()
        let recovered = await recorder.snapshot; XCTAssertTrue(recovered?.notices.first?.message.contains("remains approved") == true)
    }

    func testDelayedFailedRegistrationCleanupCannotClearNewerAttempt() async throws {
        let a = try await fixture(), authority = UUID(), server = UUID(), lifetime = TrustedOwnerLifetime()
        let first = TrustedFailedRegistration(authority: authority, generation: 1, server: server, lifetime: lifetime)
        let second = TrustedFailedRegistration(authority: authority, generation: 2, server: server, lifetime: lifetime)
        await a.service.rememberFailedRegistration(first, error: ShaderRequestError.unavailable("old attempt")) { _ in .init(completedServices: []) }
        first.invalidate()
        await a.service.rememberFailedRegistration(second, error: ShaderRequestError.unavailable("new attempt")) { _ in .init(completedServices: []) }
        await a.service.forgetFailedRegistration(first)
        await a.service.rememberFailedRegistration(first, error: ShaderRequestError.unavailable("late old attempt")) { _ in .init(completedServices: []) }
        let current = await a.service.recoveryStatuses()
        XCTAssertTrue(current.contains { $0.id == authority && $0.message.contains("new attempt") })
        await a.service.forgetFailedRegistration(second)
        await a.service.rememberFailedRegistration(first, error: ShaderRequestError.unavailable("late old attempt")) { _ in .init(completedServices: []) }
        let retired = await a.service.recoveryStatuses()
        XCTAssertFalse(retired.contains { $0.id == authority })
    }

    func testFailureSuspendedBeforeRoutePublicationCannotRestoreSupersededRoute() async throws {
        let a = try await fixture(), b = try await fixture(), destinationStore = OutcomeBackend(), publication = RecoveryGate()
        addTeardownBlock { await publication.release() }
        let source = TrustedApprovalsCoordinator(read: { nil }, write: { _ in })
        let destination = TrustedApprovalsCoordinator(read: { try destinationStore.read() }, write: { try destinationStore.write($0) },
            beforeFailedRegistrationRoute: { try? await publication.wait() })
        let original = try await accepted(source.register(TrustedOwnerRecorder().owner(service: a.service)))
        _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: b.service)))
        destinationStore.failReads(true)
        let failed = try await destination.register(TrustedOwnerRecorder().owner(service: a.service))
        addTeardownBlock { failed.completion.cancel() }
        try await wait { await publication.hasEntered }
        destinationStore.failReads(false)
        let replacement = try await destination.register(TrustedOwnerRecorder().owner(service: b.service))
        addTeardownBlock { replacement.completion.cancel() }
        await publication.release()
        do { _ = try await accepted(failed); XCTFail("Failed registration accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        _ = try await accepted(replacement)
        let statuses = await a.service.recoveryStatuses()
        XCTAssertFalse(statuses.contains { $0.id == destination.id })
        try await a.service.retryReconciliation()
        let current = await destination.observation
        XCTAssertEqual(current.requestedGeneration, replacement.generation)
        XCTAssertTrue(original.permit.isCurrent)
    }

    func testSameAuthorityRetryAttemptsFailedRegistrationOnlyOnce() async throws {
        let a = try await fixture(), backend = OutcomeBackend(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        backend.failReads(true)
        do { _ = try await accepted(authority.register(recorder.owner(service: a.service))); XCTFail("Failed inspection accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        let before = await authority.observation, reads = backend.reads
        do { try await a.service.retryReconciliation(); XCTFail("Failed retry reported success") }
        catch let error as TrustedPartialRecovery {
            XCTAssertEqual(error.remaining.filter { $0.hasPrefix("Registration:") }.count, 1)
        }
        let after = await authority.observation
        XCTAssertEqual(after.requestedGeneration, before.requestedGeneration + 1)
        XCTAssertEqual(backend.reads - reads, 2)
        backend.failReads(false)
        try await a.service.retryReconciliation()
        let recovered = await authority.observation
        XCTAssertEqual(recovered.requestedGeneration, after.requestedGeneration + 1)
    }

    func testStandaloneServerRegistrationHasExactExplicitRetry() async throws {
        let a = try await fixture(), backend = OutcomeBackend()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let old = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        let server = LocalCatalogServer(catalog: DirectoryCatalog(directory: a.root.appendingPathComponent("catalog")),
            testingNamespace: "standalone-registration-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { await server.shutdown() }
        backend.failReads(true)
        do { try await server.start(); XCTFail("Failed server registration started") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        let failed = await server.currentState, before = await authority.observation
        let retry = try XCTUnwrap(failed.registrationRecovery)
        XCTAssertTrue(old.permit.isCurrent)
        backend.failReads(false)
        try await a.service.retryReconciliation()
        let unrelated = await authority.observation
        XCTAssertEqual(unrelated.requestedGeneration, before.requestedGeneration)
        try await server.retryRegistration(retry.id)
        let accepted = await authority.observation, current = await server.currentState
        let port = await server.listeningPort
        XCTAssertEqual(accepted.acceptedGeneration, before.requestedGeneration + 1)
        XCTAssertFalse(old.permit.isCurrent); XCTAssertNil(current.registrationRecovery); XCTAssertNil(port)
        let reads = backend.reads
        try await server.retryRegistration(retry.id)
        XCTAssertEqual(backend.reads, reads); XCTAssertEqual(backend.writes, 0)
    }

    func testWithdrawnStandaloneRetryCannotReplaceAcceptedOwner() async throws {
        let a = try await fixture(), backend = OutcomeBackend()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) })
        let old = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        let server = LocalCatalogServer(catalog: DirectoryCatalog(directory: a.root.appendingPathComponent("catalog")),
            testingNamespace: "withdrawn-registration-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { await server.shutdown() }
        backend.failReads(true)
        do { try await server.start(); XCTFail("Failed server registration started") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        let failed = await server.currentState, retry = try XCTUnwrap(failed.registrationRecovery)
        try await server.shutdownReceipt().value()
        backend.failReads(false)
        let before = await authority.observation, reads = backend.reads
        try await server.retryRegistration(retry.id)
        let result = await authority.observation, current = await server.currentState
        XCTAssertEqual(result.requestedGeneration, before.requestedGeneration)
        XCTAssertEqual(backend.reads, reads); XCTAssertTrue(old.permit.isCurrent); XCTAssertNil(current.registrationRecovery)
    }

    func testFailedDepartureRecoveryRetriesOnlyItsDependentProposal() async throws {
        let original = try await fixture(), moving = try await fixture(), unrelated = try await fixture()
        let backend = OutcomeBackend(), refuse = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        let destination = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeDepartureRetirementAdmission: { _ in if refuse.on { throw POSIXError(.EIO) } })
        let source = TrustedApprovalsCoordinator(read: { nil }, write: { _ in })
        _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: original.service)))
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: moving.service)))
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: unrelated.service)))
        let departure = try await destination.prepareDeparture(original.service, ticket: UUID())
        // Defensive injection. This test does not posit a normal producer.
        try departure.activate {}
        await destination.retainDepartureRecovery(serviceID: original.service.runtimeID, ticket: departure.id)
        let proposal = try await destination.register(recorder.owner(service: moving.service))
        do { _ = try await accepted(proposal); XCTFail("Unresolved departure did not block registration") }
        catch let error as TrustedDepartureRecoveryError { XCTAssertEqual(error.diagnosticID, departure.id) }
        refuse.on = true
        try await unrelated.service.retryReconciliation()
        do { try await moving.service.retryReconciliation(); XCTFail("Unresolved dependency accepted") }
        catch let error as TrustedPartialRecovery {
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
        }
        let retained = await destination.observation, unaccepted = await recorder.binding
        XCTAssertEqual(retained.requestedGeneration, proposal.generation); XCTAssertNil(unaccepted)
        refuse.on = false
        try await moving.service.retryReconciliation()
        let after = await destination.observation, accepted = await recorder.binding
        XCTAssertEqual(after.requestedGeneration, proposal.generation + 1)
        XCTAssertTrue(accepted?.service === moving.service); XCTAssertEqual(backend.writes, 0)
    }

    func testSealedPassReplaysHealthyTargetWhileUnrelatedRecoveryIsSettling() async throws {
        let aArmed = OutcomeSwitch(), replayFails = OutcomeSwitch(), sealing = RecoveryGate()
        let aEntered = TrustedCompletionSignal(), releaseA = TrustedCompletionSignal()
        let a = try await fixture(reconcile: { _ in
            if aArmed.on {
                aEntered.finish()
                try await releaseA.wait(cancellable: false)
            }
        }), b = try await fixture()
        addTeardownBlock { releaseA.finish(); await sealing.release() }
        let backend = OutcomeBackend(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeRecoverySealing: { try await sealing.wait() })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        let owner = TrustedApprovalsCoordinator.Owner(serverID: UUID(), service: b.service, changed: { _, _ in },
            retired: {}, beforeReplay: { _ in if replayFails.on { throw POSIXError(.EIO) } })
        let binding = try await accepted(authority.register(owner))
        let job = try await submit(b.service)
        replayFails.on = true
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Replay fault ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        replayFails.on = false
        backend.failReads(true)
        do { _ = try await accepted(authority.register(owner)); XCTFail("Failed registration accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        backend.failReads(false)

        aArmed.on = true
        let abandoned = Task { try await a.service.trustedRecoveryOutcome() }
        addTeardownBlock { abandoned.cancel(); releaseA.finish() }
        try await wait { aEntered.isFinished }
        abandoned.cancel()
        _ = await abandoned.result
        let result = OutcomeResult<Void>()
        let retry = Task { do { try await b.service.retryReconciliation(); result.value = .success(()) } catch { result.value = .failure(error) } }
        addTeardownBlock { retry.cancel(); await sealing.release() }
        try await wait { await sealing.hasEntered }
        await sealing.release()
        try await wait { result.value != nil }
        guard case .failure(let error as TrustedPartialRecovery) = result.value else {
            return XCTFail("Unapplied target did not produce partial recovery")
        }
        XCTAssertTrue(error.completedServices.contains(b.service.runtimeID))
        XCTAssertFalse(error.completedServices.contains(a.service.runtimeID))
        let jobs = await b.service.allJobs(), status = await authority.observation
        XCTAssertEqual(jobs.first { $0.id == job }?.stage, .cancelled)
        XCTAssertEqual(status.obligations, 1) // One intent still needs A; B is durably cancelled.
        XCTAssertEqual(status.applicationRecoveryTargets, 1)
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.bytes)).revocations.count, 1)
        aArmed.on = false
        releaseA.finish()
    }

    func testReportingStaleLocalRecoveryEvidenceIsIdempotent() async throws {
        let a = try await fixture(), original = try await a.service.trustedRecoveryOutcome()
        await a.service.registerRevocationCoordinator(id: UUID()) {}
        let invalid = await a.service.validateTrustedRecovery(original)
        let repeated = await a.service.validateTrustedRecovery(invalid)
        XCTAssertFalse(repeated.completed); XCTAssertNil(repeated.receipt)
        XCTAssertEqual(invalid.failure, repeated.failure)
        XCTAssertTrue(repeated.failure?.contains("Local recovery evidence changed") == true)
    }

    func testRecoveryJoinsWithdrawnCleanupThroughDiagnosticPublication() async throws {
        let aFails = OutcomeSwitch(), publication = RecoveryGate(), attempts = OutcomePaths(), backend = OutcomeBackend()
        let a = try await fixture(reconcile: { _ in if aFails.on { throw POSIXError(.EIO) } }), b = try await fixture()
        addTeardownBlock { await publication.release() }
        let recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            cleanupCheckpoint: { _, point in
                if point == .willAdmit { attempts.add("admission") }
                if point == .willPublishDiagnostic { try? await publication.wait() }
            })
        _ = try await accepted(authority.register(recorder.owner(service: b.service)))
        backend.failReads(true)
        let proposal = TrustedOwnerRecorder().owner(service: a.service)
        do { _ = try await accepted(authority.register(proposal)); XCTFail("Failed proposal accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        backend.failReads(false); aFails.on = true
        proposal.eligibility.invalidate()
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        try await wait { await publication.hasEntered }
        let result = OutcomeResult<Void>()
        let retry = Task { do { try await a.service.retryReconciliation(); result.value = .success(()) } catch { result.value = .failure(error) } }
        addTeardownBlock { retry.cancel(); await publication.release() }
        try await wait { await authority.observation.recoveryCleanupWaiters == 1 }
        let held = await authority.observation
        XCTAssertEqual(held.uninspectedCleanupTasks, 1); XCTAssertEqual(attempts.count, 1); XCTAssertNil(result.value)
        await publication.release()
        try await wait { result.value != nil }
        guard case .failure(let error) = result.value else { return XCTFail("Failed cleanup reported success") }
        XCTAssertTrue(error.localizedDescription.contains("Withdrawn proposal"))
        let current = await recorder.snapshot, state = await authority.observation
        XCTAssertTrue(current?.diagnostic?.contains("Withdrawn TV proposal cleanup") == true)
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(state.uninspectedCleanupTasks, 0)
    }

    func testEndingOneRegistrationKeepsOtherInspectionGuidance() async throws {
        let a = try await fixture(), earlier = UUID(), later = UUID()
        await a.service.beginTrustedRegistration(ticket: earlier)
        _ = try await a.service.prepareTrustedAuthority(id: UUID())
        await a.service.beginTrustedRegistration(ticket: later)
        await a.service.endTrustedRegistration(ticket: later)
        let pending = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
        XCTAssertTrue(pending.message.contains("registration is inspecting"))
        await a.service.endTrustedRegistration(ticket: earlier)
        let finished = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
        XCTAssertTrue(finished.message.contains("Register a local catalog server"))
    }

    func testFailedRegistrationStatusesUseStableAuthorityOrder() async throws {
        let a = try await fixture(), lifetime = TrustedOwnerLifetime()
        let authorities = (0..<12).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        for authority in authorities.reversed() {
            let identity = TrustedFailedRegistration(authority: authority, generation: 1, server: UUID(), lifetime: lifetime)
            await a.service.rememberFailedRegistration(identity, error: POSIXError(.EIO)) { _ in .init(completedServices: []) }
        }
        let statuses = await a.service.recoveryStatuses()
        XCTAssertEqual(statuses.map(\.id).filter { authorities.contains($0) }, authorities)
    }

    func testSameAuthorityActivationFailureKeepsVisibleRetryAction() async throws {
        let a = try await fixture(), backend = OutcomeBackend(), activationFails = OutcomeSwitch(), recorder = TrustedOwnerRecorder()
        let authority = TrustedApprovalsCoordinator(read: { try backend.read() }, write: { try backend.write($0) },
            beforeTargetActivation: { _ in if activationFails.on { throw POSIXError(.EIO) } })
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        activationFails.on = true
        do { _ = try await accepted(authority.register(recorder.owner(service: a.service))); XCTFail("Failed activation accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        let before = await authority.observation, statuses = await a.service.recoveryStatuses()
        XCTAssertTrue(statuses.contains { $0.id == authority.id && $0.message.contains(POSIXError(.EIO).localizedDescription) })
        activationFails.on = false
        try await a.service.retryReconciliation()
        let accepted = await authority.observation, current = await a.service.recoveryStatuses()
        XCTAssertEqual(accepted.acceptedGeneration, before.requestedGeneration + 1)
        XCTAssertFalse(current.contains { $0.id == authority.id })
    }

    func testSettledLocalRecoveryDoesNotFailAfterIndependentMetadataChange() async throws {
        let a = try await fixture(), sealing = RecoveryGate(), recorder = TrustedOwnerRecorder()
        addTeardownBlock { await sealing.release() }
        let authority = TrustedApprovalsCoordinator(read: { nil }, write: { _ in }, beforeRecoverySealing: { try await sealing.wait() })
        _ = try await accepted(authority.register(recorder.owner(service: a.service)))
        let result = OutcomeResult<Void>()
        let retry = Task {
            do { try await a.service.retryReconciliation(); result.value = .success(()) }
            catch { result.value = .failure(error) }
        }
        addTeardownBlock { retry.cancel(); await sealing.release() }
        try await wait { await sealing.hasEntered }
        // A completed local phase holds no maintenance lease. A later write
        // makes its receipt stale without reopening any cancellation obligation.
        try await a.service.disable()
        await sealing.release()
        try await wait { result.value != nil }
        try XCTUnwrap(result.value).get()
        let configuration = await a.service.configurationValue()
        XCTAssertFalse(configuration.enabled)
    }

    func testForeignDepartureSettlementPublishesToProposalRecipient() async throws {
        let original = try await fixture(), moving = try await fixture(), late = try await fixture()
        let source = OutcomeBackend().coordinator(), destination = OutcomeBackend().coordinator()
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: original.service)))
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: moving.service)))
        let departure = try await source.prepareDeparture(original.service, ticket: UUID())
        // Inject exceptional state without asserting a normal producer.
        try departure.activate {}
        await source.retainDepartureRecovery(serviceID: original.service.runtimeID, ticket: departure.id)
        let endpoint: TrustedAuthorityRecoveryEndpoint
        do {
            _ = try await accepted(destination.register(TrustedOwnerRecorder().owner(service: moving.service)))
            return XCTFail("Blocked handoff accepted")
        } catch let error as TrustedDepartureRecoveryError { endpoint = error.endpoint }

        let updates = await moving.service.localUpdates(), observed = OutcomeResult<Bool>()
        let observer = Task {
            for await state in updates {
                observed.value = .success(state.recoveries.contains { $0.id == departure.id })
            }
        }
        addTeardownBlock { observer.cancel() }
        try await wait { (try? observed.value?.get()) == true }
        try await endpoint.retry()
        try await wait { (try? observed.value?.get()) == false }
        XCTAssertFalse(endpoint.isCurrent)
        // A delayed attachment cannot resurrect the settled ticket.
        await endpoint.attach(to: late.service)
        let current = await late.service.recoveryStatuses()
        XCTAssertFalse(current.contains { $0.id == departure.id })
    }

    func testUnavailableOriginalStillHasOneCanonicalDepartureEndpoint() async throws {
        let target = try await fixture()
        // The fixture itself keeps its service alive. Use an independently
        // scoped optional service to exercise an unavailable original target.
        let folder = target.root.appendingPathComponent("unavailable")
        var original: ShaderRequestService? = ShaderRequestService(
            catalog: DirectoryCatalog(directory: folder.appendingPathComponent("catalog")), directory: folder)
        await original?.suspend()
        try await original?.initialize(configuration: .init(repository: folder.path))
        let source = OutcomeBackend().coordinator()
        let serviceID = try XCTUnwrap(original?.runtimeID), weak = WeakRequestService(original)
        _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: original)))
        let departure = try await source.prepareDeparture(XCTUnwrap(original), ticket: UUID())
        try departure.activate {}
        original = nil
        try await wait { weak.value == nil }
        await source.retainDepartureRecovery(serviceID: serviceID, ticket: departure.id)
        let endpoints = OutcomePaths()
        var first: TrustedAuthorityRecoveryEndpoint?
        for service in [nil, target.service, nil] {
            do {
                _ = try await accepted(source.register(TrustedOwnerRecorder().owner(service: service)))
                XCTFail("Missing departure evidence accepted")
            } catch let error as TrustedDepartureRecoveryError {
                if let first { XCTAssertTrue(first === error.endpoint) }
                else { first = error.endpoint }
                XCTAssertNil(error.endpoint.journal)
                endpoints.add(error.endpoint.ticketID.uuidString)
            }
        }
        XCTAssertEqual(endpoints.count, 3)
        do {
            try await XCTUnwrap(first).retry()
            XCTFail("Missing original service was inferred")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot access its original request service"))
        }
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
