#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedDepartureTests: XCTestCase {
    private struct Fixture { let root: URL; let service: ShaderRequestService }
    private func fixture(fault: DepartureStorageFault? = nil) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pr47-departure-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in },
            beforePersistenceReplacement: { if $0.lastPathComponent == "journal.json", fault?.enabled == true { throw POSIXError(.EIO) } })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, service: service)
    }
    private func submit(_ service: ShaderRequestService, device: String = "B") async throws {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader,
            screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4),
            animationTime: 1, width: 1920, height: 1080)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: ShaderRequest(prompt: "Handoff regression", context: context)), deviceID: device)
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Departure test backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testQueuedRevocationUsesTargetsAfterSuccessfulAndCancelledHandoff() async throws {
        for cancel in [false, true] {
            let a = try await fixture(), b = try await fixture(); try await submit(a.service); try await submit(b.service)
            let bytes = try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()
            let backend = TrustedBackendFixture(bytes), old = backend.coordinator()
            _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
            let binding = try await accept(old.register(TrustedOwnerRecorder().owner(service: b.service)))
            let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
            addTeardownBlock { gate.release() }
            let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
            try await wait { gate.entered }
            let revoking = Task { try await old.revoke("B", permit: binding.permit) { _ in } }
            addTeardownBlock { revoking.cancel(); gate.release(); _ = try? await revoking.value }
            try await wait { await old.observation.queuedRevocations == 1 }
            let reads = backend.reads, started = ProcessInfo.processInfo.systemUptime
            let queries = ProcessInfo.processInfo.environment["HOLODECK_TRUSTED_PROFILE"] == "1" ? 128 : 4
            for _ in 0..<queries {
                let reply = try await b.service.control(operation: "requestStatus", payload: .init(), deviceID: "unrelated")
                XCTAssertTrue(reply.enabled)
            }
            XCTAssertEqual(backend.reads, reads)
            XCTAssertEqual(backend.read(), bytes); XCTAssertEqual(backend.writes, 0)
            let waiting = await old.observation; XCTAssertEqual(waiting.encodings, 0)
            if queries == 128 { print("HANDOFF_PROFILE queries=\(queries) elapsed=\(ProcessInfo.processInfo.systemUptime - started) trustedWrites=\(backend.writes) encodings=\(waiting.encodings)") }
            if cancel { ticket.completion.cancel() }
            gate.release()
            if cancel { do { _ = try await ticket.value(); XCTFail("Cancelled transfer activated") } catch is CancellationError {} }
            else { _ = try await accept(ticket) }
            try await revoking.value
            let first = await a.service.allJobs(), second = await b.service.allJobs()
            XCTAssertEqual(first.first?.stage, cancel ? .cancelled : .queued)
            XCTAssertEqual(second.first?.stage, .cancelled)
            let stored = try TrustedTVApprovals.decode(XCTUnwrap(backend.read()))
            XCTAssertTrue(stored.approvals.isEmpty); XCTAssertTrue(stored.revocations.isEmpty)
            XCTAssertEqual(backend.writes, 2)
            let final = await old.observation; XCTAssertEqual(final.queuedRevocations, 0); XCTAssertEqual(final.departures, 0)
        }
    }
    func testDuplicateQueuedRevocationsHaveIndependentCancellationAndOneWritePair() async throws {
        let a = try await fixture(), b = try await fixture()
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()), old = backend.coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
        let binding = try await accept(old.register(TrustedOwnerRecorder().owner(service: b.service)))
        let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
        try await wait { gate.entered }
        let first = Task { try await old.revoke("B", permit: binding.permit) { _ in } }
        let cancelled = Task { try await old.revoke("B", permit: binding.permit) { _ in } }
        let second = Task { try await old.revoke("B", permit: binding.permit) { _ in } }
        addTeardownBlock { first.cancel(); second.cancel(); cancelled.cancel(); gate.release(); _ = try? await first.value; _ = try? await second.value }
        try await wait { await old.observation.queuedRevocations == 3 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled waiter executed") } catch is CancellationError {}
        try await wait { await old.observation.queuedRevocations == 2 }
        XCTAssertEqual(backend.writes, 0)
        gate.release(); _ = try await accept(ticket); try await first.value; try await second.value
        XCTAssertEqual(backend.writes, 2)
        let final = await old.observation; XCTAssertEqual(final.encodings, 2); XCTAssertEqual(final.queuedRevocations, 0)
    }
    func testCancelledDepartureCannotClearFailedInspectionUsingCachedEnvelope() async throws {
        let a = try await fixture(), b = try await fixture(), backend = TrustedBackendFixture(nil), old = backend.coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: b.service)))
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
        let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
        try await wait { gate.entered }; backend.failReads(true)
        do { try await b.service.retryReconciliation(); XCTFail("Failed trusted read accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        ticket.completion.cancel(); gate.release()
        do { _ = try await ticket.value(); XCTFail("Cancelled transfer accepted") } catch is CancellationError {}
        try await wait { await next.observation.preparingGeneration == nil }
        let reply = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "B")
        XCTAssertFalse(reply.enabled); XCTAssertTrue(reply.message.contains("inspection")); XCTAssertTrue(reply.message.contains(POSIXError(.EACCES).localizedDescription))
        backend.failReads(false); try await a.service.retryReconciliation()
        let recovered = try await a.service.control(operation: "requestStatus", payload: .init(), deviceID: "B")
        XCTAssertTrue(recovered.enabled)
    }
    func testFreshInspectionInvalidatesPreparedDepartureAndRetainsNewObligations() async throws {
        let a = try await fixture(), b = try await fixture(); try await submit(a.service); try await submit(b.service)
        let backend = TrustedBackendFixture(nil), old = backend.coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
        let prior = try await accept(old.register(TrustedOwnerRecorder().owner(service: b.service)))
        let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
        try await wait { gate.entered }
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "B")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        try await b.service.retryReconciliation()
        let first = await a.service.allJobs(), second = await b.service.allJobs()
        XCTAssertEqual(first.first?.stage, .cancelled); XCTAssertEqual(second.first?.stage, .cancelled)
        gate.release()
        do { _ = try await ticket.value(); XCTFail("Invalidated departure activated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("inspection changed during handoff")) }
        XCTAssertTrue(prior.permit.isCurrent)
        let final = await old.observation; XCTAssertEqual(final.departures, 0); XCTAssertEqual(final.obligations, 0)
    }
    func testCancelledTransferWakesEligibleQueueWithoutAnotherClientMutation() async throws {
        let a = try await fixture(); try await submit(a.service)
        let jobs = await a.service.allJobs()
        let job = a.root.appendingPathComponent(try XCTUnwrap(jobs.first?.id).uuidString)
        let script = a.root.appendingPathComponent("unused.py")
        try """
        import json,sys,time
        from pathlib import Path
        job=Path(sys.argv[3]);(job/'started').touch()
        while not (job/'release').exists():time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try await a.service.retryReconciliation() // Complete startup before the fence can mask a wakeup.
        let old = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
        let backend = TrustedBackendFixture(nil), gate = TrustedReadGate(); backend.gateReads(gate)
        addTeardownBlock { gate.release(); try? Data().write(to: job.appendingPathComponent("release")) }
        let next = backend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
        try await wait { gate.entered }; await a.service.activateScheduling(); await a.service.resume()
        let waiting = await a.service.allJobs(); XCTAssertEqual(waiting.first?.stage, .queued)
        ticket.completion.cancel(); gate.release()
        do { _ = try await ticket.value(); XCTFail("Cancelled handoff activated") } catch is CancellationError {}
        try await wait { FileManager.default.fileExists(atPath: job.appendingPathComponent("started").path) }
        try Data().write(to: job.appendingPathComponent("release")); await a.service.suspend()
    }
    func testPreparingCrossAuthorityRegistrationReturnsSupersededInsteadOfCancellation() async throws {
        let fixture = try await fixture(), old = TrustedBackendFixture(nil).coordinator()
        let prior = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let backend = TrustedBackendFixture(nil), gate = TrustedReadGate(); backend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = backend.coordinator(), first = try await next.register(TrustedOwnerRecorder().owner(service: fixture.service))
        try await wait { gate.entered }
        let latest = try await Task(priority: .background) { try await next.register(TrustedOwnerRecorder().owner()) }.value
        let admitted = await next.observation; XCTAssertEqual(admitted.queuedGeneration, latest.generation)
        gate.release()
        guard case .superseded = try await first.value() else { return XCTFail("Older preparation activated") }
        _ = try await accept(latest)
        let previous = await old.observation; XCTAssertEqual(previous.departures, 0); XCTAssertTrue(prior.permit.isCurrent)
    }
    func testTransferredServiceCannotRepinItsOldAuthorityOnALaterFault() async throws {
        let fault = DepartureStorageFault(), fixture = try await fixture(fault: fault)
        let old = TrustedBackendFixture(nil).coordinator(), next = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        _ = try await accept(next.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        try await wait { await old.observation.departures == 0 }
        fault.enabled = true
        do { try await submit(fixture.service); XCTFail("Fixture storage fault missing") } catch is RequestPersistence.Fault {}
        try await wait { await next.observation.recoveryPins == 1 }
        let obsolete = await old.observation
        XCTAssertEqual(obsolete.targets, 0); XCTAssertEqual(obsolete.recoverySubscriptions, 0); XCTAssertEqual(obsolete.recoveryPins, 0)
        let current = await next.observation; XCTAssertEqual(current.recoverySubscriptions, 1)
    }
    func testAbandonedDepartureCanBeClosedByIdentityWithoutItsService() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/pr47-abandon-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var service: ShaderRequestService? = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
        let weakService = WeakRequestService(service), authority = TrustedBackendFixture(nil).coordinator()
        let departure: TrustedAuthorityDeparture
        do {
            let target = try XCTUnwrap(service)
            await target.suspend(); try await target.initialize(configuration: .init(repository: root.path))
            _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: target)))
            departure = try await authority.prepareDeparture(target, ticket: UUID())
        }
        service = nil
        try await wait { weakService.value == nil }
        await authority.cancelDeparture(serviceID: departure.serviceID, ticket: departure.id)
        let retired = await authority.observation
        XCTAssertEqual(retired.departures, 0); XCTAssertEqual(retired.recoveryPins, 0); XCTAssertEqual(retired.recoverySubscriptions, 0)
    }
    func testAllCancelledQueuedRevocationsLeaveApprovalsAndBytesUnchanged() async throws {
        let fixture = try await fixture(), bytes = try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()
        let backend = TrustedBackendFixture(bytes), old = backend.coordinator()
        let binding = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: fixture.service))
        try await wait { gate.entered }
        let calls = (0..<2).map { _ in Task { try await old.revoke("B", permit: binding.permit) { _ in } } }
        addTeardownBlock { calls.forEach { $0.cancel() }; gate.release(); for call in calls { _ = try? await call.value } }
        try await wait { await old.observation.queuedRevocations == 2 }
        for call in calls { call.cancel(); do { try await call.value; XCTFail("Cancelled revocation ran") } catch is CancellationError {} }
        try await wait { await old.observation.queuedRevocations == 0 }
        gate.release(); _ = try await accept(ticket)
        XCTAssertEqual(backend.read(), bytes); XCTAssertEqual(backend.writes, 0)
        let final = await old.observation; XCTAssertEqual(final.encodings, 0)
    }
    func testRetiredQueuedCallerEncodesNothingAfterHandoffSettles() async throws {
        let fixture = try await fixture(), bytes = try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()
        let backend = TrustedBackendFixture(bytes), old = backend.coordinator()
        let binding = try await accept(old.register(TrustedOwnerRecorder().owner(service: fixture.service)))
        let nextBackend = TrustedBackendFixture(nil), gate = TrustedReadGate(); nextBackend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let next = nextBackend.coordinator(), ticket = try await next.register(TrustedOwnerRecorder().owner(service: fixture.service))
        try await wait { gate.entered }
        let revoking = Task { try await old.revoke("B", permit: binding.permit) { _ in } }
        addTeardownBlock { revoking.cancel(); gate.release(); _ = try? await revoking.value }
        try await wait { await old.observation.queuedRevocations == 1 }
        _ = try await accept(old.register(TrustedOwnerRecorder().owner()))
        gate.release()
        do { _ = try await ticket.value(); XCTFail("Stale prepared transfer activated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("inspection changed during handoff")) }
        do { try await revoking.value; XCTFail("Retired queued caller wrote approvals") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        XCTAssertEqual(backend.read(), bytes); XCTAssertEqual(backend.writes, 0)
        let final = await old.observation; XCTAssertEqual(final.encodings, 0)
    }
    func testWaitingRevocationIsAdmittedBeforeALaterDeparture() async throws {
        let a = try await fixture(), b = try await fixture(), c = try await fixture(); try await submit(b.service)
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "B", name: "B", tokenHash: "old")]).encoded()), old = backend.coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service)))
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: b.service)))
        let binding = try await accept(old.register(TrustedOwnerRecorder().owner(service: c.service)))
        let firstBackend = TrustedBackendFixture(nil), firstGate = TrustedReadGate(); firstBackend.gateReads(firstGate)
        let secondBackend = TrustedBackendFixture(nil), secondGate = TrustedReadGate(); secondBackend.gateReads(secondGate)
        let commit = RecoveryGate()
        addTeardownBlock { firstGate.release(); secondGate.release(); await commit.release() }
        let first = firstBackend.coordinator(), second = secondBackend.coordinator()
        let one = try await first.register(TrustedOwnerRecorder().owner(service: a.service)); try await wait { firstGate.entered }
        let revoking = Task { try await old.revoke("B", permit: binding.permit) { _ in try await commit.wait() } }
        addTeardownBlock { revoking.cancel(); firstGate.release(); secondGate.release(); await commit.release(); _ = try? await revoking.value }
        try await wait { await old.observation.queuedRevocations == 1 }
        let two = try await second.register(TrustedOwnerRecorder().owner(service: b.service))
        try await wait { (try? await b.service.control(operation: "requestStatus", payload: .init(), deviceID: "B"))?.message.contains("handoff is pending") == true }
        firstGate.release(); _ = try await accept(one)
        try await wait { await commit.hasEntered }
        let admitted = await old.observation
        XCTAssertEqual(admitted.departures, 0); XCTAssertFalse(secondGate.entered); XCTAssertEqual(backend.writes, 0)
        await commit.release(); try await revoking.value
        try await wait { secondGate.entered }; secondGate.release(); _ = try await accept(two)
        let cancelled = await b.service.allJobs(); XCTAssertEqual(cancelled.first?.stage, .cancelled)
        XCTAssertEqual(backend.writes, 2)
    }
    func testOpposingTransfersAndPendingReplacementsCannotBlockDepartureCleanup() async throws {
        let a = try await fixture(), b = try await fixture(), replay = RecoveryGate(), read = TrustedReadGate()
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "B")
        let oldBackend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), old = oldBackend.coordinator()
        let next = TrustedBackendFixture(nil).coordinator()
        let oldBinding = try await accept(old.register(TrustedOwnerRecorder().owner(service: a.service, beforeReplay: { _ in try await replay.wait() })))
        let nextBinding = try await accept(next.register(TrustedOwnerRecorder().owner(service: b.service)))
        addTeardownBlock { read.release(); await replay.release() }
        let movingA = try await next.register(TrustedOwnerRecorder().owner(service: a.service))
        addTeardownBlock { movingA.completion.cancel(); read.release(); await replay.release() }
        try await wait { await replay.hasEntered }
        let latestNext = try await next.register(TrustedOwnerRecorder().owner())
        addTeardownBlock { latestNext.completion.cancel() }
        let nextQueue = await next.observation; XCTAssertEqual(nextQueue.queuedGeneration, latestNext.generation)
        oldBackend.gateReads(read)
        let movingB = try await old.register(TrustedOwnerRecorder().owner(service: b.service))
        addTeardownBlock { movingB.completion.cancel(); read.release(); await replay.release() }
        try await wait { read.entered } // B's preparation passed the pending replacement on its source authority.
        let latestOld = try await old.register(TrustedOwnerRecorder().owner())
        addTeardownBlock { latestOld.completion.cancel() }
        let oldQueue = await old.observation; XCTAssertEqual(oldQueue.queuedGeneration, latestOld.generation)
        XCTAssertEqual(oldQueue.acceptedGeneration, oldBinding.permit.generation)
        let heldNext = await next.observation; XCTAssertEqual(heldNext.acceptedGeneration, nextBinding.permit.generation)
        let backstop = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { [movingA, movingB, latestNext, latestOld].forEach { $0.completion.cancel() } }
        }
        defer { backstop.cancel() }
        read.release(); await replay.release()
        guard case .superseded = try await movingA.value() else { return XCTFail("Older A transfer activated") }
        guard case .superseded = try await movingB.value() else { return XCTFail("Older B transfer activated") }
        _ = try await accept(latestNext); _ = try await accept(latestOld)
        try await wait { await old.observation.departures == 0 }
        try await wait { await next.observation.departures == 0 }
    }
    func testDepartureAdmissionCannotActivateAfterInspectionInvalidation() throws {
        let departure = TrustedAuthorityDeparture(id: UUID(), serviceID: UUID(), registrationID: UUID())
        departure.prepared(); departure.invalidatePreparation()
        var applied = false
        XCTAssertThrowsError(try departure.activate { applied = true }); XCTAssertFalse(applied)
        departure.prepared(); try departure.activate { applied = true }; XCTAssertTrue(applied)
        departure.invalidatePreparation(); XCTAssertTrue(departure.activated)
        departure.close(); XCTAssertThrowsError(try departure.activate {})
    }
}
private final class DepartureStorageFault: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var enabled: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
