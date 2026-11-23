#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRetirementWaitTests: XCTestCase {
    private struct Pending {
        let service: ShaderRequestService
        let root: URL
        let oldBackend: TrustedBackendFixture
        let old: TrustedApprovalsCoordinator
        let next: TrustedApprovalsCoordinator
        let backend: TrustedBackendFixture
        let binding: TrustedApprovalsCoordinator.Binding
        let registration: TrustedApprovalsCoordinator.Registration
        let writing: TrustedReadGate
        let fail: RetirementWaitSwitch
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Retirement wait backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func result(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.BindingOutcome {
        let box = RetirementWaitResult()
        let task = Task { do { box.value = .success(try await registration.value()) } catch { box.value = .failure(error) } }
        addTeardownBlock { task.cancel(); registration.completion.cancel() }
        try await wait { box.value != nil }
        return try XCTUnwrap(box.value).get()
    }
    private func accepted(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await result(registration) else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func pending(launched: Bool = true, approvals: [ApprovedTV] = [], reconcile: @escaping @Sendable () async throws -> Void = {}) async throws -> Pending {
        let root = URL(fileURLWithPath: "/private/tmp/pr53-retirement-wait-" + UUID().uuidString)
        let writing = TrustedReadGate(), reading = TrustedReadGate(), dispatch = TrustedReadGate()
        let armed = RetirementWaitSwitch(), fail = RetirementWaitSwitch(), dispatching = RetirementWaitSwitch()
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("worker.py"), reconcileWorker: { _ in try await reconcile() },
            beforePersistenceReplacement: { url in
                if dispatching.on && url.lastPathComponent == "active.json" { dispatch.wait() }
                if armed.on && url.lastPathComponent == "journal.json" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("active.json").path) {
                    writing.wait()
                    if fail.on { throw POSIXError(.EIO) }
                }
            })
        addTeardownBlock {
            armed.on = false; dispatching.on = false; fail.on = false
            writing.release(); reading.release(); dispatch.release()
            if let rows = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [[String: Any]] {
                for row in rows { if let status = row["status"] as? [String: Any], let id = status["id"] as? String { try? Data().write(to: root.appendingPathComponent(id).appendingPathComponent("release")) } }
            }
            await service.suspend(); try? FileManager.default.removeItem(at: root)
        }
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        let fixture = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: fixture)).validated().initialShader
        let request = ShaderRequest(prompt: "Handoff retirement", context: .init(shader: shader,
            screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4),
            animationTime: 1, width: 1920, height: 1080))
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "TV")
        let job = root.appendingPathComponent(request.id.uuidString)
        addTeardownBlock { try? Data().write(to: job.appendingPathComponent("release")) }
        try """
        import json,sys,time
        from pathlib import Path
        p=Path(sys.argv[3]);(p/'started').touch()
        while not (p/'release').exists():time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
        """.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        try await service.retryReconciliation()
        let oldBackend = TrustedBackendFixture(try TrustedTVApprovals(approvals: approvals).encoded()), old = oldBackend.coordinator(), backend = TrustedBackendFixture(nil), next = backend.coordinator()
        let binding = try await accepted(old.register(TrustedOwnerRecorder().owner(service: service)))
        dispatching.on = !launched
        await service.activateScheduling(); await service.resume()
        if launched { try await wait { FileManager.default.fileExists(atPath: job.appendingPathComponent("started").path) } }
        else { try await wait { dispatch.entered } }
        backend.gateReads(reading)
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { registration.completion.cancel(); writing.release(); reading.release(); dispatch.release() }
        try await wait { reading.entered }
        armed.on = true
        if launched { try Data().write(to: job.appendingPathComponent("release")) }
        else { dispatching.on = false; dispatch.release() }
        try await wait { writing.entered }
        backend.gateReads(nil); reading.release()
        try await wait { await service.trustedRetirementWaiters > 0 }
        XCTAssertFalse(registration.completion.hasStarted)
        let before = await next.observation
        XCTAssertNil(before.acceptedGeneration); XCTAssertFalse(before.transitionActive)
        XCTAssertTrue(binding.permit.isCurrent)
        return .init(service: service, root: root, oldBackend: oldBackend, old: old, next: next, backend: backend,
                     binding: binding, registration: registration, writing: writing, fail: fail)
    }
    func testRevocationYieldsRetirementWaitAndHandoffResumes() async throws {
        let p = try await pending(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")])
        let revoked = RetirementDetachResult()
        let task = Task {
            do { try await p.old.revoke("TV", permit: p.binding.permit) { _ in }; revoked.value = .success(()) }
            catch { revoked.value = .failure(error) }
        }
        addTeardownBlock { task.cancel(); p.writing.release() }
        try await wait { (try? TrustedTVApprovals.decode(p.oldBackend.read()!).approvals.isEmpty) == true }
        XCTAssertTrue(p.writing.entered)
        XCTAssertFalse(p.registration.completion.hasStarted)
        let stored = try TrustedTVApprovals.decode(XCTUnwrap(p.oldBackend.read()))
        XCTAssertEqual(stored.revocations.map(\.deviceID), ["TV"])
        p.writing.release()
        try await wait { revoked.value != nil }; try XCTUnwrap(revoked.value).get()
        _ = try await accepted(p.registration)
        XCTAssertEqual(p.oldBackend.writes, 2)
        let done = await p.old.observation
        XCTAssertEqual(done.departures, 0); XCTAssertEqual(done.queuedRevocations, 0)
    }
    func testHealthyRetirementAutomaticallyCompletesHandoff() async throws {
        let p = try await pending()
        p.writing.release()
        _ = try await accepted(p.registration)
        let current = await p.service.prepareTargetInstallation(authority: p.next.id)
        XCTAssertEqual(current.predecessorAuthority, p.next.id)
        XCTAssertEqual(p.backend.writes, 0)
        let stages = await p.service.allJobs().map(\.stage); XCTAssertEqual(stages, [.awaitingClarification])
    }
    func testHandoffWaitsForItsNeverLaunchedDispatchRetirement() async throws {
        let p = try await pending(launched: false)
        let rows = await p.service.allJobs(); XCTAssertEqual(rows.first?.stage, .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.root.appendingPathComponent(rows[0].id.uuidString).appendingPathComponent("started").path))
        p.writing.release(); _ = try await accepted(p.registration)
    }
    func testWaitingRegistrationCancelsBeforeRetirementFinishes() async throws {
        let p = try await pending()
        p.registration.completion.cancel()
        do { _ = try await result(p.registration); XCTFail("Cancelled preparation activated") } catch is CancellationError {}
        try await wait { await p.service.trustedRetirementWaiters == 0 }
        XCTAssertTrue(p.binding.permit.isCurrent)
        let next = await p.next.observation; XCTAssertNil(next.acceptedGeneration)
    }
    func testNewerRegistrationSupersedesWaitingPreparation() async throws {
        let p = try await pending()
        let newest = try await p.next.register(TrustedOwnerRecorder().owner(service: p.service))
        addTeardownBlock { newest.completion.cancel(); p.writing.release() }
        guard case .superseded = try await result(p.registration) else { return XCTFail("Older preparation activated") }
        p.writing.release(); _ = try await accepted(newest)
        let next = await p.next.observation; XCTAssertEqual(next.acceptedGeneration, newest.generation)
    }
    func testDetachInterruptsWaitingActivationWithItsOwnDiagnostic() async throws {
        let armed = RetirementWaitSwitch(), settling = RecoveryGate()
        addTeardownBlock { await settling.release() }
        let p = try await pending(reconcile: { if armed.on { try await settling.wait() } })
        armed.on = true
        let outcome = RetirementDetachResult()
        let detach = Task {
            do { try await p.service.detachCheckout(.selectedCheckout); outcome.value = .success(()) }
            catch { outcome.value = .failure(error) }
        }
        addTeardownBlock { detach.cancel(); p.writing.release(); await settling.release() }
        try await wait { await p.service.recoveryStatuses().contains { $0.disposition == .detach } }
        p.writing.release()
        try await wait { await settling.hasEntered }
        do { _ = try await result(p.registration); XCTFail("Detach allowed binding activation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Detach")); XCTAssertFalse(error.localizedDescription.contains("needs receipt recovery")) }
        let next = await p.next.observation; XCTAssertNil(next.acceptedGeneration)
        armed.on = false; await settling.release()
        try await wait { outcome.value != nil }; try XCTUnwrap(outcome.value).get()
    }
    func testRetirementWriteFailureKeepsOldBindingAndExactDiagnostic() async throws {
        let p = try await pending()
        p.fail.on = true; p.writing.release()
        do { _ = try await result(p.registration); XCTFail("Failed retirement activated") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)); XCTAssertFalse(error.localizedDescription.contains("needs receipt recovery")) }
        XCTAssertTrue(p.binding.permit.isCurrent)
        let next = await p.next.observation; XCTAssertNil(next.acceptedGeneration)
    }
}
@MainActor private final class RetirementDetachResult { var value: Result<Void, Error>? }
@MainActor private final class RetirementWaitResult { var value: Result<TrustedApprovalsCoordinator.BindingOutcome, Error>? }
private final class RetirementWaitSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
