#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRecoveryBoundaryTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> (ShaderRequestService, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pr48-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("worker.py")
        try """
        import json,sys,time
        from pathlib import Path
        job=Path(sys.argv[3]);(job/'started').touch()
        while not (job/'release').exists():time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: script, reconcileWorker: reconcile)
        await service.suspend(); try await service.start(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return (service, root)
    }
    private func submit(_ service: ShaderRequestService, device: String = "B") async throws -> UUID {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader,
            screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4),
            animationTime: 1, width: 1920, height: 1080)
        let request = ShaderRequest(prompt: "Boundary regression", context: context)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: device)
        return request.id
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Recovery boundary backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testSupersededRecoveryRegistrationRequiresActualInspection() async throws {
        let (a, _) = try await fixture(), (b, _) = try await fixture()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        let binding = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b)))
        backend.failReads(true)
        do { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a))); XCTFail("Failed read accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        let gate = TrustedReadGate(); backend.failReads(false); backend.gateReads(gate)
        addTeardownBlock { gate.release() }
        let occupying = Task { try await authority.approve(binding.permit) { nil } }
        addTeardownBlock { occupying.cancel(); gate.release() }
        try await wait { gate.entered }
        let result = BoundaryOutcome(), recovery = Task {
            do { try await b.retryReconciliation(); result.finish(nil) } catch { result.finish(error) }
        }
        addTeardownBlock { recovery.cancel(); gate.release() }
        try await wait { await authority.observation.queuedGeneration != nil }
        let reads = backend.reads, latest = try await authority.register(TrustedOwnerRecorder().owner())
        addTeardownBlock { latest.completion.cancel() }
        try await wait { await authority.observation.progressWaiters > 0 }
        XCTAssertFalse(result.finished); XCTAssertEqual(backend.reads, reads)
        gate.release(); _ = try await occupying.value
        try await wait { result.finished }; try result.check(); _ = try await accept(latest)
        XCTAssertGreaterThan(backend.reads, reads)
        let status = try await a.control(operation: "requestStatus", payload: .init(), deviceID: "A")
        XCTAssertTrue(status.enabled); XCTAssertFalse(status.message.contains("inspection requires recovery"))
    }
    func testRequesterActiveWorkRefusesBothRecoveryPhases() async throws {
        let (service, root) = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: service)))
        let id = try await submit(service), job = root.appendingPathComponent(id.uuidString)
        addTeardownBlock { try? Data().write(to: job.appendingPathComponent("release")) }
        await service.resume(); try await wait { FileManager.default.fileExists(atPath: job.appendingPathComponent("started").path) }
        let reads = backend.reads
        do { try await service.retryReconciliation(); XCTFail("Active work admitted recovery") }
        catch is TrustedRecoveryAdmissionError {}
        XCTAssertEqual(backend.reads, reads)
        let jobs = await service.allJobs(); XCTAssertEqual(jobs.first?.stage, .implementing)
        try Data().write(to: job.appendingPathComponent("release")); await service.suspend()
    }
    func testOwnerlessNewPublicationWaiterFailsWhileExistingWorkFinishes() async throws {
        let (service, root) = try await fixture(), owner = service.retainOwner()
        let id = try await submit(service), job = root.appendingPathComponent(id.uuidString)
        addTeardownBlock { owner.release(); try? Data().write(to: job.appendingPathComponent("release")) }
        await service.resume(); try await wait { FileManager.default.fileExists(atPath: job.appendingPathComponent("started").path) }
        let result = BoundaryOutcome(), publication = Task {
            do { try await service.ensurePublication(force: true); result.finish(ShaderRequestError.invalidRequest) }
            catch { result.finish(error) }
        }
        addTeardownBlock { publication.cancel() }
        try await wait { await service.pendingPublicationWaiterCount == 1 }
        owner.release(); try await wait { result.finished }
        XCTAssertTrue(result.error?.localizedDescription.contains("local host reconnects") == true)
        let jobs = await service.allJobs(); XCTAssertEqual(jobs.first?.stage, .implementing)
        try Data().write(to: job.appendingPathComponent("release"))
        try await wait { await service.allJobs().first?.stage == .awaitingClarification }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("publication/started").path))
    }
    func testDetachLeaseLossIsPartialRecoveryAndDoesNotSkipTrustedInspection() async throws {
        let gate = RecoveryGate(), fault = BoundaryFailureSwitch()
        let (a, _) = try await fixture(reconcile: { _ in if fault.armed { try await gate.wait() } })
        let (b, _) = try await fixture()
        let requestID = try await submit(b, device: "A")
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Initial replay should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        // Same-service transport replacement keeps the target registration, and
        // removes the injected hook without clearing its failed application.
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b)))
        fault.armed = true
        addTeardownBlock { await gate.release() }
        let result = BoundaryOutcome(), retry = Task {
            do { try await b.retryReconciliation(); result.finish(nil) }
            catch { result.finish(error) }
        }
        addTeardownBlock { retry.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let reads = backend.reads, detach = Task { try await a.detachCheckout(.selectedCheckout) }
        addTeardownBlock { detach.cancel(); await gate.release() }
        try await wait { !(await a.configurationValue().enabled) }
        await gate.release()
        try await wait { result.finished }
        let partial = try XCTUnwrap(result.error as? TrustedPartialRecovery)
        XCTAssertTrue(partial.completedServices.contains(b.runtimeID)); XCTAssertFalse(partial.completedServices.contains(a.runtimeID))
        XCTAssertTrue(partial.remaining.joined().contains("ownership changed"))
        XCTAssertGreaterThan(backend.reads, reads)
        try await detach.value
        let jobs = await b.allJobs(); XCTAssertEqual(jobs.first { $0.id == requestID }?.stage, .cancelled)
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
    }
    func testActualRecoveryCancellationStopsRemainingPreparation() async throws {
        let gate = RecoveryGate(), (service, _) = try await fixture(reconcile: { _ in try await gate.wait() })
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: service)))
        let retry = Task { try await service.retryReconciliation() }
        addTeardownBlock { retry.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }; let reads = backend.reads
        retry.cancel(); await gate.release()
        do { try await retry.value; XCTFail("Cancelled recovery succeeded") } catch is CancellationError {}
        XCTAssertEqual(backend.reads, reads)
    }
}
@MainActor private final class BoundaryOutcome {
    private(set) var finished = false
    private(set) var error: Error?
    func finish(_ error: Error?) { self.error = error; finished = true }
    func check() throws { if let error { throw error } }
}
private final class BoundaryFailureSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var armed: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
