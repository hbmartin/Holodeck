#if os(macOS)
import Foundation
import XCTest
import Network
import Clocks
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
    private func tls(_ server: LocalCatalogServer) async throws -> LocalConnection {
        try await wait { await (server.listeningPort ?? 0) > 0 }
        let port = await server.listeningPort
        let trust = LocalTrust()
        let connection = LocalConnection(NWConnection(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(port))!, using: NWParameters(tls: trust.options(expected: nil), tcp: .init())))
        try await connection.start(); addTeardownBlock { connection.cancel() }; return connection
    }
    private func authenticate(_ client: LocalConnection, device: String, token: String) async throws {
        var message = LocalMessage(operation: "authenticate"); message.deviceID = device; message.token = token
        let reply = try await client.exchange(LocalPacket(message: message)); XCTAssertNil(reply.message.error)
    }
    func testFailedInitialStartAndRejectedVacancyRegistrationRemainRetryable() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(try TrustedTVApprovals().encoded()), authority = backend.coordinator()
        let first = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "registration-retry-" + UUID().uuidString, trustedApprovals: authority)
        let second = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "vacancy-retry-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { try await first.clearTestSecrets(); try await second.clearTestSecrets() }
        backend.failReads(true)
        do { try await first.start(); XCTFail("Failed inspection accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        backend.failReads(false); try await first.start()
        try await wait { await (first.listeningPort ?? 0) > 0 }
        do { try await second.revoke("unapproved"); XCTFail("Vacancy-only registration displaced its owner") }
        catch { XCTAssertTrue(error.localizedDescription.contains("handoff is pending")) }
        try await second.start()
        let old = await first.listeningPort; XCTAssertNil(old)
        try await wait { await (second.listeningPort ?? 0) > 0 }
    }
    func testStopInvalidatesInitialStartAcrossInspectionAwait() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(nil), gate = TrustedWriteGate()
        let authority = TrustedApprovalsCoordinator(read: { _ = gate.wait(); return backend.read() }, write: { try backend.write($0) })
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "stop-start-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { gate.release(); try await server.clearTestSecrets() }
        gate.arm(); let start = Task { try await server.start() }
        try await wait { gate.entered }; await server.stop(); gate.release()
        do { try await start.value; XCTFail("Stopped start created a listener") } catch is CancellationError {}
        let stopped = await server.listeningPort; XCTAssertNil(stopped)
        try await server.start(); try await wait { await (server.listeningPort ?? 0) > 0 }
    }
    func testQueuedRevocationSurvivesSameServerRegistration() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A"), ApprovedTV(id: "B", name: "B", tokenHash: "B")]).encoded())
        let authority = backend.coordinator(), gate = RecoveryGate()
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "same-server", beforeTrustedCommit: { if $0.deviceID == "A" { try await gate.wait() } }, trustedApprovals: authority)
        await server.setRequestService(fixture.service)
        let first = Task { try await server.revoke("A") }; try await wait { await gate.hasEntered }
        let rebind = Task { await server.setRequestService(fixture.service) }; try await wait { await authority.observation.queuedGeneration != nil }
        let queued = Task { try await server.revoke("B") }; try await wait { await authority.observation.mutationWaiters > 0 }
        await gate.release(); try await first.value; await rebind.value; try await queued.value
        let value = try TrustedTVApprovals.decode(XCTUnwrap(backend.read()))
        XCTAssertTrue(value.approvals.isEmpty); XCTAssertTrue(value.revocations.isEmpty); XCTAssertEqual(backend.writes, 4)
    }
    func testRetiredLifetimeCannotUpgradeAfterExplicitReactivation() async throws {
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded()), authority = backend.coordinator(), owner = TrustedOwnerRecorder()
        let registration = try await authority.register(owner.owner())
        guard case .accepted(let first) = try await registration.value() else { return XCTFail("Initial registration superseded") }
        try await accept(authority.register(TrustedOwnerRecorder().owner()))
        try await accept(authority.register(owner.owner()))
        let before = await authority.observation
        do { try await authority.revoke("A", permit: first.permit) { _ in }; XCTFail("Retired operation upgraded to a new lifetime") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        let after = await authority.observation; XCTAssertEqual(before.encodings, after.encodings); XCTAssertEqual(after.writes, 0)
    }
    func testTLSHandoffClosesApprovedSessionWithoutPermanentRevocation() async throws {
        let fixture = try await fixture(), token = "retained-token", device = UUID().uuidString
        let original = try TrustedTVApprovals(approvals: [ApprovedTV(id: device, name: "TV", tokenHash: CatalogHash.sha256(Data(token.utf8)))]).encoded()
        let backend = TrustedBackendFixture(original), authority = backend.coordinator(), gate = RecoveryGate()
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "handoff-auth-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { await gate.release(); try await server.clearTestSecrets() }
        await server.setRequestService(fixture.service); try await server.start()
        let client = try await tls(server); try await authenticate(client, device: device, token: token)
        let replacement = try await authority.register(.init(serverID: UUID(), service: fixture.service, changed: { _, _ in try? await gate.wait() }, retired: {}, beforeReplay: { _ in }))
        try await wait { await gate.hasEntered }
        var asset = LocalMessage(operation: "asset"); asset.request = .head; asset.limit = 65536
        do { let reply = try await client.exchange(LocalPacket(message: asset)); XCTFail("Interrupted transport returned \(reply.message.error ?? "success")") }
        catch LocalCatalogError.disconnected {} catch is NWError {} catch { XCTFail("Unexpected interruption category: \(error)") }
        XCTAssertEqual(backend.read(), original)
        await gate.release(); try await accept(replacement)
    }
    func testLateAssetReplyUsesTransientInterruptionAcrossRebinding() async throws {
        let fixture = try await fixture(), token = "retained-token", device = UUID().uuidString, gate = RecoveryGate()
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: device, name: "TV", tokenHash: CatalogHash.sha256(Data(token.utf8)))]).encoded()), authority = backend.coordinator()
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "late-asset-" + UUID().uuidString, readAsset: { _, _, _ in try await gate.wait(); return Data("old reply".utf8) }, trustedApprovals: authority)
        addTeardownBlock { await gate.release(); try await server.clearTestSecrets() }
        await server.setRequestService(fixture.service); try await server.start()
        let client = try await tls(server); try await authenticate(client, device: device, token: token)
        let reply = Task { var message = LocalMessage(operation: "asset"); message.request = .head; message.limit = 65536; return try await client.exchange(LocalPacket(message: message)) }
        try await wait { await gate.hasEntered }; await server.setRequestService(fixture.service); await gate.release()
        do { _ = try await reply.value; XCTFail("An obsolete binding returned an asset") }
        catch LocalCatalogError.disconnected {} catch is NWError {} catch { XCTFail("Unexpected interruption category: \(error)") }
        let next = try await tls(server); try await authenticate(next, device: device, token: token)
    }

}
#endif
