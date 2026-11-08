#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedTargetRecoveryTests: XCTestCase {
    private struct Fixture { let root: URL; let service: ShaderRequestService }
    private func fixture(fault: TargetStorageFault? = nil, repair: TargetRepairCounter? = nil, repairFailure: TargetStorageFault? = nil) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("pr46-" + UUID().uuidString)
        if repair != nil {
            let journal = root.appendingPathComponent("own-entry")
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
            var recovery = RequestRecoveryStore(); recovery.legacyMigrationComplete = true
            recovery.entries[journal.path] = .init(journal: journal.path, disposition: .resume, message: "Own journal requires recovery")
            try recovery.encoded().write(to: root.appendingPathComponent("recovery.json"))
        }
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { if $0.lastPathComponent == "own-entry" { repair?.add(); if repairFailure?.enabled == true { throw POSIXError(.EIO) } } },
            beforePersistenceReplacement: { if $0.lastPathComponent == "journal.json", fault?.enabled == true { throw POSIXError(.EIO) } })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, service: service)
    }
    private func context() throws -> ShaderRequestContext {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        return .init(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1920, height: 1080)
    }
    private func submit(_ service: ShaderRequestService) async throws {
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: ShaderRequest(prompt: "Revocation regression", context: try context())), deviceID: "A")
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Target regression backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testPartialReservationUnwindsExactReceiptsWithoutChangingApprovalBytes() async throws {
        let a = try await fixture(), b = try await fixture()
        let last = [a.service.runtimeID, b.service.runtimeID].max(by: { $0.uuidString < $1.uuidString })!
        let bytes = try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded()
        let backend = TrustedBackendFixture(bytes)
        let authority = TrustedApprovalsCoordinator(read: { backend.read() }, write: { try backend.write($0) }, beforeReservation: { if $0 == last { throw POSIXError(.EIO) } })
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        let binding = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        do { try await authority.revoke("A", permit: binding.permit) { _ in }; XCTFail("Partial reservation accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertEqual(backend.read(), bytes); XCTAssertEqual(backend.writes, 0)
        try await submit(a.service); try await submit(b.service)
    }
    func testPartialCommitRetainsEveryRequiredTargetAndDurableIntent() async throws {
        let a = try await fixture(), b = try await fixture(); try await submit(a.service); try await submit(b.service)
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded())
        let authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a.service)))
        let binding = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b.service)))
        do {
            try await authority.revoke("A", permit: binding.permit) { _ in await b.service.registerRevocationCoordinator(id: UUID()) {} }
            XCTFail("Missing application accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("coordinator changed") || error.localizedDescription.contains("intent changed")) }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.count, 1)
        let one = await a.service.allJobs(), two = await b.service.allJobs()
        XCTAssertEqual(one.first?.stage, .cancelled); XCTAssertEqual(two.first?.stage, .queued)
        XCTAssertEqual(backend.writes, 1)
    }
    func testFailedInspectionCannotBeClearedByAnotherTargetsReplay() async throws {
        let a = try await fixture(), b = try await fixture(); try await submit(b.service)
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A"), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a.service, beforeReplay: { _ in try await gate.wait() })))
        let replay = Task { try await authority.replay() }; try await wait { await gate.hasEntered }
        backend.failReads(true)
        do { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b.service))); XCTFail("Failed inspection accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        await gate.release()
        do { try await replay.value; XCTFail("Uninspected target was omitted") } catch { }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        let reply = try await b.service.control(operation: "requestStatus", payload: .init(), deviceID: "A")
        XCTAssertFalse(reply.enabled); XCTAssertTrue(reply.message.contains("inspection"))
        let jobs = await b.service.allJobs(); XCTAssertEqual(jobs.first?.stage, .queued)
        backend.failReads(false); try await b.service.retryReconciliation()
        let cancelled = await b.service.allJobs(); XCTAssertEqual(cancelled.first?.stage, .cancelled)
    }
    func testCrossAuthoritySwitchDrainsOldIntentAndRetiresOldBroadcastTarget() async throws {
        let fixture = try await fixture(); try await submit(fixture.service)
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let oldBackend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "B")], revocations: [intent]).encoded())
        let old = oldBackend.coordinator(), next = TrustedBackendFixture(try TrustedTVApprovals().encoded()).coordinator()
        let prior = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        _ = try await accept(next.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let jobs = await fixture.service.allJobs(); XCTAssertEqual(jobs.first?.stage, .cancelled)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(oldBackend.read())).revocations.isEmpty)
        // Wait for the previous authority's nonblocking target retirement before its next mutation.
        try await wait { await old.observation.transitionActive == false }
        try await old.revoke("B", permit: prior.permit) { _ in }
        try await submit(fixture.service)
    }
    func testLocalJournalsRecoverBeforeAnUnrelatedTargetsFailureIsReported() async throws {
        let counter = TargetRepairCounter(), fault = TargetStorageFault()
        let own = try await fixture(repair: counter), other = try await fixture(fault: fault)
        fault.enabled = true
        do { try await submit(other.service); XCTFail("Storage failure accepted") } catch is RequestPersistence.Fault {}
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: own.service)))
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: other.service)))
        do { try await authority.replay(); XCTFail("Unresolved storage accepted") } catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let before = counter.value
        do { try await own.service.retryReconciliation(); XCTFail("Partial recovery reported full success") }
        catch let error as TrustedPartialRecovery {
            XCTAssertTrue(error.completedServices.contains(own.service.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
        }
        XCTAssertGreaterThan(counter.value, before)
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        fault.enabled = false; try await own.service.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testTrustedInspectionRecoversEvenWhenLocalJournalStillFails() async throws {
        let failure = TargetStorageFault(), counter = TargetRepairCounter()
        let own = try await fixture(repair: counter, repairFailure: failure)
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: own.service)))
        backend.failReads(true)
        do { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: own.service))); XCTFail("Failed inspection accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        failure.enabled = true
        let reads = backend.reads
        do { try await own.service.retryReconciliation(); XCTFail("Both recovery failures accepted") }
        catch let error as TrustedPartialRecovery {
            XCTAssertFalse(error.completedServices.contains(own.service.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EACCES).localizedDescription))
        }
        XCTAssertGreaterThan(backend.reads, reads)
        backend.failReads(false)
        let nextReads = backend.reads
        do { try await own.service.retryReconciliation(); XCTFail("Local recovery failure accepted") }
        catch let error as TrustedPartialRecovery {
            XCTAssertFalse(error.completedServices.contains(own.service.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
            XCTAssertFalse(error.remaining.joined().contains(POSIXError(.EACCES).localizedDescription))
        }
        XCTAssertGreaterThan(backend.reads, nextReads)
        let statuses = await own.service.recoveryStatuses()
        XCTAssertFalse(statuses.contains { $0.message.contains("TV approval inspection requires recovery") })
        failure.enabled = false; try await own.service.retryReconciliation()
        let restored = await own.service.recoveryStatuses(); XCTAssertTrue(restored.isEmpty)
    }
    func testFailedCandidateShutdownCannotReplaceTheLiveOwnerOnRetry() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(try TrustedTVApprovals().encoded()), authority = backend.coordinator()
        let catalog = DirectoryCatalog(directory: fixture.root.appendingPathComponent("catalog"))
        let live = LocalCatalogServer(catalog: catalog, testingNamespace: "live-owner-" + UUID().uuidString, trustedApprovals: authority)
        let candidate = LocalCatalogServer(catalog: catalog, testingNamespace: "dead-candidate-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { try await candidate.clearTestSecrets(); try await live.clearTestSecrets() }
        await live.setRequestService(fixture.service); try await live.start()
        try await wait { await (live.listeningPort ?? 0) > 0 }
        let owner = await authority.observation.acceptedGeneration
        backend.failReads(true); await candidate.setRequestService(fixture.service)
        await candidate.shutdown(); backend.failReads(false)
        try await fixture.service.retryReconciliation()
        let after = await authority.observation.acceptedGeneration, port = await live.listeningPort
        XCTAssertEqual(after, owner); XCTAssertNotNil(port)
    }

    func testOwnerlessPublicationReportsStorageRecoveryBeforeReconnectGuidance() async throws {
        let fault = TargetStorageFault(), fixture = try await fixture(fault: fault), owner = fixture.service.retainOwner()
        fault.enabled = true
        do { try await submit(fixture.service); XCTFail("Storage failure accepted") } catch is RequestPersistence.Fault {}
        owner.release()
        do { try await fixture.service.ensurePublication(); XCTFail("Recovery blocker ignored") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription))
            XCTAssertFalse(error.localizedDescription.contains("host reconnects"))
        }
    }
    func testFailedAuthorityDrainRetainsOldBindingAndCanBeRetried() async throws {
        let fault = TargetStorageFault(), fixture = try await fixture(fault: fault); try await submit(fixture.service)
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), old = backend.coordinator()
        let prior = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let next = TrustedBackendFixture(try TrustedTVApprovals().encoded()).coordinator()
        fault.enabled = true
        do { _ = try await accept(next.register(TrustedOwnerRecorder().owner(service: fixture.service))); XCTFail("Failed drain replaced authority") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        XCTAssertTrue(prior.permit.isCurrent)
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        fault.enabled = false; try await fixture.service.retryReconciliation()
        _ = try await accept(next.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let jobs = await fixture.service.allJobs(); XCTAssertEqual(jobs.first?.stage, .cancelled)
        try await submit(fixture.service)
    }
    func testCancelledAuthorityPreparationCannotReplaceOldRegistration() async throws {
        let fixture = try await fixture(), gate = RecoveryGate(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        addTeardownBlock { await gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), old = backend.coordinator()
        let prior = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service, beforeReplay: { _ in try await gate.wait() })))
        let next = TrustedBackendFixture(try TrustedTVApprovals().encoded()).coordinator()
        let ticket = try await next.register(TrustedOwnerRecorder().owner(service: fixture.service))
        try await wait { await gate.hasEntered }
        let conflicting = try await old.register(TrustedOwnerRecorder().owner(service: fixture.service))
        do { _ = try await conflicting.value(); XCTFail("Registration added obligations behind a frozen departure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("handoff pending")) }
        ticket.completion.cancel()
        do { _ = try await ticket.value(); XCTFail("Cancelled handoff accepted") } catch is CancellationError {}
        await gate.release()
        try await wait { await next.observation.preparingGeneration == nil }
        XCTAssertTrue(prior.permit.isCurrent)
        try await submit(fixture.service)
        let nextState = await next.observation; XCTAssertNil(nextState.acceptedGeneration)
    }
    func testRemovalReceiptRejectsDuplicateServiceKeysWithoutTrapping() throws {
        let service = UUID(), authority = UUID(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let one = TrustedRevocationApplication(serviceID: service, registrationID: UUID(), authority: authority, intent: intent)
        let two = TrustedRevocationApplication(serviceID: service, registrationID: UUID(), authority: authority, intent: intent)
        XCTAssertThrowsError(try TrustedRevocationRemoval.checked(authority: authority, intent: intent, proofs: [one, two]))
    }
    func testReplayFailureAndSnapshotCarryTheSameExplicitIdentity() async throws {
        let fixture = try await fixture(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator(), owner = TrustedOwnerRecorder()
        _ = try await accept(authority.register(owner.owner(service: fixture.service, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Failed replay accepted") }
        catch { XCTAssertEqual((error as? any TrustedReportedDiagnostic)?.diagnosticID, intent.operationID) }
        let snapshot = await owner.snapshot; XCTAssertEqual(snapshot?.diagnosticID, intent.operationID)
    }

}
private final class TargetStorageFault: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var enabled: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
private final class TargetRepairCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
#endif
