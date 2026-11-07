#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedTargetRecoveryTests: XCTestCase {
    private struct Fixture { let root: URL; let service: ShaderRequestService }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: root.appendingPathComponent("unused.py"))
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
}
#endif
