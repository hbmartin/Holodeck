#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

private final class TrustedWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false, open = false, reached = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return reached }
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard armed else { return false }; armed = false; reached = true
        let limit = Date().addingTimeInterval(10)
        while !open { if !condition.wait(until: limit) { return true } }
        return true
    }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
}

@MainActor final class TrustedLifecycleTests: XCTestCase {
    private struct Fixture { let root: URL; let catalog: DirectoryCatalog; let service: ShaderRequestService }
    private func fixture(gate: TrustedWriteGate? = nil, fail: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"))
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: root.appendingPathComponent("unused.py"), beforePersistenceReplacement: { url in
            if url.lastPathComponent == "journal.json", gate?.wait() == true, fail { throw POSIXError(.EIO) }
        })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, catalog: catalog, service: service)
    }
    private func context() throws -> ShaderRequestContext {
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        return .init(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1920, height: 1080)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Trusted lifecycle test backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func accept(_ ticket: TrustedApprovalsCoordinator.Registration) async throws {
        if case .superseded = try await ticket.value() { XCTFail("Unexpected superseded fixture registration") }
    }
    private func submit(_ fixture: Fixture, device: String = "A") async throws {
        _ = try await fixture.service.control(operation: "requestSubmit", payload: .init(request: ShaderRequest(prompt: "Retain cancellation across replacement", context: try context())), deviceID: device)
    }
    func testReplayServiceSwitchCancelsBothTargetsBeforeRemovingIntent() async throws {
        let gate = TrustedWriteGate(), old = try await fixture(gate: gate), next = try await fixture()
        defer { gate.release() }
        try await submit(old); try await submit(next)
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: old.service)))
        gate.arm(); let replay = Task { try await authority.replay() }
        try await wait { gate.entered }
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: next.service)))
        XCTAssertEqual(backend.writes, 0)
        let queued = await next.service.allJobs(); XCTAssertEqual(queued.first?.stage, .queued)
        gate.release(); try await replay.value
        let oldJobs = await old.service.allJobs(), newJobs = await next.service.allJobs()
        XCTAssertEqual(oldJobs.first?.stage, .cancelled); XCTAssertEqual(newJobs.first?.stage, .cancelled)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 1)
        try await submit(old); try await submit(next) // Both exact fences retired after the one trusted removal.
    }
    func testFailedOldApplicationStillAttemptsReplacementAndRetainsEvidenceUntilRecovery() async throws {
        let gate = TrustedWriteGate(), old = try await fixture(gate: gate, fail: true), next = try await fixture()
        defer { gate.release() }
        try await submit(old); try await submit(next)
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let bytes = try TrustedTVApprovals(revocations: [intent]).encoded()
        let backend = TrustedBackendFixture(bytes), authority = backend.coordinator()
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: old.service)))
        gate.arm(); let replay = Task { try await authority.replay() }
        try await wait { gate.entered }
        try await accept(authority.register(TrustedOwnerRecorder().owner(service: next.service)))
        gate.release()
        do { try await replay.value; XCTFail("Old target's uncommitted cancellation was forgotten") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let jobs = await next.service.allJobs(); XCTAssertEqual(jobs.first?.stage, .cancelled)
        XCTAssertEqual(backend.read(), bytes); XCTAssertEqual(backend.writes, 0)
        do { try await submit(next); XCTFail("Unresolved target released the device fence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("revocation")) }
        try await next.service.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        XCTAssertEqual(backend.writes, 1)
        try await submit(next)
    }
    func testLateRemovalCannotClearAnotherAuthorityRegistration() async throws {
        let fixture = try await fixture(), gate = TrustedWriteGate(), old = UUID(), next = UUID()
        defer { gate.release() }
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A"), service = fixture.service
        let revision = TrustedRevocationRevision(coordinator: old, sequence: 0)
        await service.registerRevocationCoordinator(id: old) {}
        try await service.loadTrustedRevocations([intent], revision: revision)
        try await service.applyTrustedRevocation(intent, revision: revision)
        gate.arm(); let removal = Task { try await service.acknowledgeTrustedRevocation(intent, revision: revision) { _ = gate.wait() } }
        try await wait { gate.entered }
        await service.registerRevocationCoordinator(id: next) {}
        try await service.loadTrustedRevocations([intent], revision: .init(coordinator: next, sequence: 0))
        gate.release()
        do { try await removal.value; XCTFail("Late removal cleared a newer registration") }
        catch { XCTAssertTrue(error.localizedDescription.contains("service registration")) }
        do { try await submit(fixture); XCTFail("New authority's fence disappeared") }
        catch { XCTAssertTrue(error.localizedDescription.contains("revocation")) }
    }
}
#endif
