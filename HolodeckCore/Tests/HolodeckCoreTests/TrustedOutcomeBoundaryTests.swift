#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

private final class OutcomeBackend: @unchecked Sendable {
    enum WriteFailure { case none, before, after, conflict }
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
            if failure == .before { throw POSIXError(.EIO) }
            data = failure == .conflict ? Data("conflicting bytes".utf8) : value
            writeCount += 1
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
    func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Outcome boundary backstop") }
            try await Task.sleep(for: .milliseconds(3))
        }
    }
    func accepted(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
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
            case .none: XCTFail("Unexpected fixture mode")
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
        await authority.withdraw(serverID: proposal.serverID, eligibility: proposal.eligibility)
        let held = await authority.observation
        XCTAssertNil(held.acceptedGeneration); XCTAssertEqual(held.uninspectedCleanupTasks, 1)
        let replacement = try await authority.register(TrustedOwnerRecorder().owner(service: f.service))
        addTeardownBlock { replacement.completion.cancel() }
        XCTAssertFalse(replacement.completion.hasStarted)
        backend.arm(nil); read.release()
        _ = try await accepted(replacement)
        try await wait { await authority.observation.uninspectedCleanupTasks == 0 }
        let after = await authority.observation, old = await owner.binding
        XCTAssertNil(old); XCTAssertEqual(after.uninspectedTargets, 0)
        XCTAssertEqual(after.acceptedGeneration, replacement.generation)
    }

}
private final class OutcomeSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    func take() -> Bool { lock.withLock { let result = value; value = false; return result } }
}
@MainActor private final class OutcomeResult<Value: Sendable> { var value: Result<Value, Error>? }
#endif
