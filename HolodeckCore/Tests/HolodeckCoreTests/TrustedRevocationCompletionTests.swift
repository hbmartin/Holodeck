#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRevocationCompletionTests: XCTestCase {
    private func fixture() async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr55-replay-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Revocation completion backstop") }
            try await Task.sleep(for: .milliseconds(3))
        }
    }
    private func accepted(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await ticket.value() else { throw ShaderRequestError.invalidRequest }; return binding
    }
    private func submit(_ service: ShaderRequestService, device: String) async throws -> UUID {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1, height: 1)
        let request = ShaderRequest(prompt: "Independent cancellation", context: context)
        _ = try await service.control(operation: "requestSubmit", payload: .init(request: request), deviceID: device)
        return request.id
    }
    func testHealthyTargetCancelsWhileOtherValidationIsHeld() async throws {
        let a = try await fixture(), b = try await fixture(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let id = try await submit(b, device: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeRecoverySealing: { try await gate.wait() })
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: b))), hold = UUID()
        _ = try await a.trustedRecoveryOutcome(pass: hold, authority: authority.id); await a.finishTrustedRecovery(pass: hold)
        let first = Task { try await authority.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        try await wait { await b.allJobs().first { $0.id == id }?.stage == .cancelled }
        await gate.release(); try await first.value
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 2)
    }
    func testFailedValidationStillCancelsOtherTargetsAndRecordsAdmissionRejection() async throws {
        let a = try await fixture(), b = try await fixture(), id = try await submit(b, device: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded()), authority = backend.coordinator(), owner = TrustedOwnerRecorder()
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let binding = try await accepted(authority.register(owner.owner(service: b))), hold = UUID()
        _ = try await a.trustedRecoveryOutcome(pass: hold, authority: authority.id); await a.finishTrustedRecovery(pass: hold)
        backend.failReads(true)
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Failed validation accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription)) }
        let stage = await b.allJobs().first { $0.id == id }?.stage; XCTAssertEqual(stage, .cancelled)
        backend.failReads(false)
        do { try await authority.revoke("TV", permit: binding.permit) { _ in }; XCTFail("Automatic validation repeated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Choose Retry Recovery")) }
        let diagnostic = await owner.snapshot?.diagnostic
        XCTAssertTrue(diagnostic?.contains("Automatic trusted validation did not complete") == true)
        try await a.retryReconciliation()
    }
    func testCancelledCompletionSubscriberDoesNotAbandonOtherSubscriberOrDurableWork() async throws {
        let service = try await fixture(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeRecoverySealing: { try await gate.wait() })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))), hold = UUID()
        _ = try await service.trustedRecoveryOutcome(pass: hold, authority: authority.id); await service.finishTrustedRecovery(pass: hold)
        let result = CompletionResult(), first = Task { try await authority.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let other = Task { do { try await authority.revoke("TV", permit: binding.permit) { _ in }; result.done = true } catch { result.error = error; result.done = true } }
        addTeardownBlock { other.cancel() }
        try await wait { await authority.observation.revocationCompletionSubscribers == 2 }
        first.cancel()
        let cancelled = CompletionResult()
        let waiter = Task { do { try await first.value; cancelled.error = ShaderRequestError.invalidRequest } catch { cancelled.error = error }; cancelled.done = true }
        addTeardownBlock { waiter.cancel() }
        try await wait { cancelled.done }
        XCTAssertTrue(cancelled.error is CancellationError)
        await gate.release(); await other.value
        XCTAssertNil(result.error); XCTAssertTrue(result.done)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        let observation = await authority.observation; XCTAssertEqual(observation.recoveryPasses, 1)
    }
    func testLoneCancelledSubscriberDoesNotAbandonDurableCompletion() async throws {
        let service = try await fixture(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeRecoverySealing: { try await gate.wait() })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))), hold = UUID()
        _ = try await service.trustedRecoveryOutcome(pass: hold, authority: authority.id); await service.finishTrustedRecovery(pass: hold)
        let task = Task { try await authority.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { task.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        try await wait { await authority.observation.revocationCompletionSubscribers == 1 }
        task.cancel()
        let cancelled = CompletionResult()
        let probe = Task { do { try await task.value } catch { cancelled.error = error }; cancelled.done = true }
        addTeardownBlock { probe.cancel(); await gate.release() }
        try await wait { cancelled.done }
        XCTAssertTrue(cancelled.error is CancellationError)
        await gate.release()
        try await wait { let state = await authority.observation; return state.revocationCompletionTasks == 0 && state.automaticValidationTasks == 0 }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 2)
    }
    func testRefreshedObsoleteOutcomeDoesNotResetAutomaticAttempt() async throws {
        let service = try await fixture(), armed = ReplaySwitch(), fault = ReplaySwitch(), gate = RecoveryGate()
        addTeardownBlock { await gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeAuthorityPreparation: { _ in
            if fault.on { throw POSIXError(.EIO) }; if armed.on { try await gate.wait() }
        })
        let binding = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))), hold = UUID()
        _ = try await service.trustedRecoveryOutcome(pass: hold, authority: authority.id); await service.finishTrustedRecovery(pass: hold)
        _ = try await submit(service, device: "Other")
        fault.on = true
        let failed = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        do { _ = try await failed.value(); XCTFail("Injected registration failed to fail") } catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        fault.on = false; armed.on = true
        let first = Task { try await authority.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { first.cancel() }
        try await wait { await gate.hasEntered }
        _ = try await submit(service, device: "Other2")
        armed.on = false; await gate.release()
        do { try await first.value; XCTFail("Obsolete receipt accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("evidence changed")) }
        let before = await authority.observation
        let current = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service)))
        do { try await authority.revoke("TV", permit: current.permit) { _ in }; XCTFail("Automatic validation repeated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Choose Retry Recovery")) }
        let after = await authority.observation; XCTAssertEqual(after.recoveryPasses, before.recoveryPasses)
        try await service.retryReconciliation()
    }
}
@MainActor private final class CompletionResult { var done = false; var error: Error? }
private final class ReplaySwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
