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

private final class LifecycleCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class LifecycleClientSecrets: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]; private var endpoint: UInt16 = 0
    var port: UInt16 { get { lock.withLock { endpoint } } set { lock.withLock { endpoint = newValue } } }
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ value: Data, _ key: String) { lock.withLock { values[key] = value } }
    func remove(_ key: String) { lock.withLock { values[key] = nil } }
    func token(_ namespace: String) -> String? {
        guard let bytes = read(namespace + "-pairing"), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return value["token"] as? String
    }
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

    private func pair(_ server: LocalCatalogServer, client: LocalConnection, device: String = UUID().uuidString) async throws -> TVApproval {
        var message = LocalMessage(operation: "pair"); message.deviceID = device; message.name = "Lifecycle TV"
        let reply = try await client.exchange(LocalPacket(message: message)); XCTAssertEqual(reply.message.operation, "pending")
        try await wait { await !server.currentState.pending.isEmpty }
        let state = await server.currentState
        return try XCTUnwrap(state.pending.first)
    }
    func testAdmittedApprovalRetainsBytesWhenDeliveryBecomesImpossible() async throws {
        for ending in ["close", "expire", "decline", "retire"] {
            let fixture = try await fixture(), backend = TrustedBackendFixture(nil), gate = TrustedWriteGate(), clock = TestClock()
            let authority = TrustedApprovalsCoordinator(read: { backend.read() }, write: { _ = gate.wait(); try backend.write($0) })
            let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "pair-outcome-" + UUID().uuidString, clock: clock, trustedApprovals: authority)
            addTeardownBlock { gate.release(); try await server.clearTestSecrets() }
            try await server.start(); let client = try await tls(server), device = UUID().uuidString
            let proposal = try await pair(server, client: client, device: device)
            gate.arm(); let approval = Task { try await server.approve(proposal.id) }
            try await wait { gate.entered }
            switch ending {
            case "close": client.cancel(); try await wait { await server.sessionCount == 0 }
            case "expire": await clock.advance(by: .seconds(301)); try await wait { await server.sessionCount == 0 }
            case "decline": await server.decline(proposal.id)
            default:
                let replacement = try await authority.register(TrustedOwnerRecorder().owner())
                // Registration waits for the admitted write. Final teardown invalidates delivery immediately.
                let shutdown = Task { await server.shutdown() }
                try await wait { await server.sessionCount == 0 }
                gate.release(); await shutdown.value; try await accept(replacement)
            }
            gate.release()
            do { try await approval.value; XCTFail("Committed undeliverable approval reported success: \(ending)") }
            catch is CommittedApprovalDeliveryError {} catch { XCTFail("Incorrect approval outcome: \(error)") }
            let stored = try TrustedTVApprovals.decode(XCTUnwrap(backend.read()))
            XCTAssertEqual(stored.approvals.map(\.id), [device]); XCTAssertEqual(backend.writes, 1)
            if ending != "retire" {
                let next = try await tls(server), repeated = try await pair(server, client: next, device: device)
                try await server.approve(repeated.id)
                let issued = try await next.exchange(LocalPacket(message: .init(operation: "pairStatus")))
                XCTAssertNotNil(issued.message.token); XCTAssertEqual(backend.writes, 2)
            }
        }
    }
    func testIneligiblePairingDoesNotEncodeOrWrite() async throws {
        for ending in ["close", "expire", "decline", "retire"] {
            let fixture = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), clock = TestClock()
            let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "pair-ineligible-" + UUID().uuidString, clock: clock, trustedApprovals: authority)
            addTeardownBlock { try await server.clearTestSecrets() }
            try await server.start(); let client = try await tls(server), proposal = try await pair(server, client: client)
            switch ending {
            case "close": client.cancel(); try await wait { await server.sessionCount == 0 }
            case "expire": await clock.advance(by: .seconds(301)); try await wait { await server.sessionCount == 0 }
            case "decline": await server.decline(proposal.id)
            default: await server.shutdown()
            }
            let before = await authority.observation
            do { try await server.approve(proposal.id) }
            catch { XCTAssertEqual(ending, "retire"); XCTAssertTrue(error.localizedDescription.contains("replaced")) }
            let after = await authority.observation
            XCTAssertEqual(before.encodings, after.encodings); XCTAssertEqual(backend.writes, 0)
        }
    }
    func testShutdownCannotReviveRegistrationWaitingForInspection() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(nil), gate = TrustedWriteGate()
        let authority = TrustedApprovalsCoordinator(read: { _ = gate.wait(); return backend.read() }, write: { try backend.write($0) })
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "shutdown-register-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { gate.release(); try await server.clearTestSecrets() }
        gate.arm(); let setup = Task { await server.setRequestService(fixture.service) }
        try await wait { gate.entered }; await server.shutdown(); gate.release(); await setup.value
        do { try await server.start(); XCTFail("Final teardown allowed implicit registration") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        await server.setRequestService(fixture.service); try await server.start()
        try await wait { await (server.listeningPort ?? 0) > 0 }
    }
    func testLastOwnerPausesDispatchWhileActiveWorkFinishesAndWaitingJobsRemain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("owner-worker.py"), gate = root.appendingPathComponent("hold")
        try Data().write(to: gate)
        try """
        import json, sys, time
        from pathlib import Path
        job=Path(sys.argv[3]); root=job.parent
        if sys.argv[1]=='preflight': print(json.dumps(dict(event='preflight')),flush=True); sys.exit(0)
        (job/'started').touch()
        while (root/'hold').exists(): time.sleep(.005)
        print(json.dumps(dict(event='clarification',question='Choose',options=['A','B'])),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        var service: ShaderRequestService? = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: script)
        weak let released = service
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try XCTUnwrap(service).retainOwner()
        try await service!.start(configuration: .init(repository: root.path, enabled: true))
        let one = ShaderRequest(prompt: "First", context: try context()), two = ShaderRequest(prompt: "Second", context: try context())
        _ = try await service!.control(operation: "requestSubmit", payload: .init(request: one), deviceID: "A")
        _ = try await service!.control(operation: "requestSubmit", payload: .init(request: two), deviceID: "B")
        let first = root.appendingPathComponent(one.id.uuidString), second = root.appendingPathComponent(two.id.uuidString)
        try await wait { FileManager.default.fileExists(atPath: first.appendingPathComponent("started").path) }
        owner.release(); try FileManager.default.removeItem(at: gate)
        try await wait { await service!.allJobs().first(where: { $0.id == one.id })?.stage == .awaitingClarification }
        try await wait { await !service!.hasActiveCheckoutWork }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("started").path))
        let rows = await service!.allJobs(); XCTAssertEqual(rows.first(where: { $0.id == two.id })?.stage, .queued)
        // A newer lease makes an old repeated release harmless and resumes only queued work.
        let next = service!.retainOwner(); owner.release()
        try await wait { await service!.allJobs().first(where: { $0.id == two.id })?.stage == .awaitingClarification }
        try await wait { await !service!.hasActiveCheckoutWork }; next.release()
        service = nil
        try await wait { released == nil }
    }
    func testIdleAuthorityDoesNotRetainReleasedServiceAndAccountsShare() async throws {
        let namespace = "weak-host-" + UUID().uuidString
        let one = TrustedApprovalsCoordinator.keychain(namespace: namespace), two = TrustedApprovalsCoordinator.keychain(namespace: namespace)
        XCTAssertTrue(one === two)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var service: ShaderRequestService? = ShaderRequestService(catalog: DirectoryCatalog(directory: root), directory: root)
        weak let standalone = service
        let target = try await one.register(TrustedOwnerRecorder().owner(service: service))
        try await accept(target); service = nil
        try await wait { standalone == nil }
        await one.discardTestingCacheIfIdle()
    }

    func testSuccessfulMutationClearsTrustedDiagnosticAndUsesFreshRevision() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A"), ApprovedTV(id: "B", name: "B", tokenHash: "B")]).encoded())
        let reads = LifecycleCounter(), authority = TrustedApprovalsCoordinator(read: { reads.add(); return backend.read() }, write: { try backend.write($0) })
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "clear-trusted-" + UUID().uuidString, trustedApprovals: authority)
        addTeardownBlock { try await server.clearTestSecrets() }
        await server.setRequestService(fixture.service); try await server.start()
        try await wait { await server.currentState.message.contains("Serving") }
        XCTAssertEqual(reads.value, 1)
        backend.failWrites(true)
        do { try await server.revoke("A"); XCTFail("Failed write succeeded") } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        let failed = await server.currentState; XCTAssertTrue(failed.message.contains(POSIXError(.EIO).localizedDescription))
        backend.failWrites(false); try await server.revoke("A")
        let recovered = await server.currentState; XCTAssertEqual(recovered.message, "Serving shaders on the local network.")
        XCTAssertEqual(reads.value, 1); XCTAssertEqual(backend.writes, 2)
        let before = await authority.observation
        try await server.revoke("unapproved")
        let after = await authority.observation
        XCTAssertEqual(before.encodings, after.encodings); XCTAssertEqual(before.writes, after.writes)
        XCTAssertEqual(reads.value, 1)
    }
    func testAcceptedControlReplyInterruptedByRebindingRemainsDurable() async throws {
        let gate = TrustedWriteGate(), fixture = try await fixture(gate: gate), device = UUID().uuidString, token = "valid-token"
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: device, name: "TV", tokenHash: CatalogHash.sha256(Data(token.utf8)))]).encoded())
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "late-control-" + UUID().uuidString, trustedApprovals: backend.coordinator())
        addTeardownBlock { gate.release(); try await server.clearTestSecrets() }
        await server.setRequestService(fixture.service); try await server.start()
        let client = try await tls(server); try await authenticate(client, device: device, token: token)
        let request = ShaderRequest(prompt: "Accepted once", context: try context()), payload = try JSONEncoder().encode(ShaderRequestControl(request: request))
        gate.arm(); let reply = Task { try await client.exchange(LocalPacket(message: .init(operation: "requestSubmit"), payload: payload)) }
        try await wait { gate.entered }; await server.setRequestService(fixture.service); gate.release()
        do { _ = try await reply.value; XCTFail("Obsolete control reply returned") }
        catch LocalCatalogError.disconnected {} catch is NWError {} catch { XCTFail("Unexpected transport outcome: \(error)") }
        let jobs = await fixture.service.allJobs(); XCTAssertEqual(jobs.map(\.id), [request.id]); XCTAssertEqual(jobs.first?.stage, .queued)
        let next = try await tls(server); try await authenticate(next, device: device, token: token)
    }
    func testOwnerlessInternalAuthorizationRetainsExplicitInvalidation() {
        let authorization = TrustedRequestAuthorization(coordinator: UUID(), deviceID: "internal")
        XCTAssertTrue(authorization.isCurrent); authorization.invalidate(); XCTAssertFalse(authorization.isCurrent)
    }
    func testCommittedRemovalRetainsFailureAndRetriesExactFenceWithoutAnotherWrite() async throws {
        let fixture = try await fixture(), gate = TrustedWriteGate(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { backend.read() }, write: { _ = gate.wait(); try backend.write($0) })
        let owner = TrustedOwnerRecorder()
        try await accept(authority.register(owner.owner(service: fixture.service)))
        gate.arm(); let replay = Task { try await authority.replay() }
        try await wait { gate.entered }
        let replacement = UUID()
        await fixture.service.registerRevocationCoordinator(id: replacement) {}
        try await fixture.service.loadTrustedRevocations([intent], revision: .init(coordinator: replacement, sequence: 0))
        gate.release()
        do { try await replay.value; XCTFail("Stale removal appeared to release the fence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("service registration")) }
        XCTAssertEqual(backend.writes, 1); XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        do { try await submit(fixture); XCTFail("Stale completion cleared the replacement fence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("revocation")) }
        try await accept(authority.register(owner.owner(service: fixture.service)))
        try await authority.replay()
        XCTAssertEqual(backend.writes, 1) // Reuse the actual committed removal receipt.
        try await submit(fixture)
    }
    func testTLSClientKeepsSavedTokenThroughReplacementAndRejectsGenuineRevocation() async throws {
        let fixture = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), secrets = LifecycleClientSecrets()
        let namespace = "client-handoff-" + UUID().uuidString
        let first = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: namespace, trustedApprovals: authority)
        let second = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: namespace, trustedApprovals: authority)
        addTeardownBlock { try await first.clearTestSecrets(); try await second.clearTestSecrets() }
        await first.setRequestService(fixture.service); try await first.start()
        try await wait { await (first.listeningPort ?? 0) > 0 }
        let firstPort = await first.listeningPort; secrets.port = try XCTUnwrap(firstPort)
        let firstID = await first.serverID; let serverID = try XCTUnwrap(firstID)
        let mac = LocalMac(id: serverID, name: "TLS lifecycle Mac", endpoint: .service(name: "test", type: LocalProtocol.serviceType, domain: "local.", interface: nil), interface: nil, version: LocalProtocol.version)
        var dependencies = LocalClientDependencies()
        dependencies.usesSystemBrowser = false; dependencies.initialMacs = [mac]
        dependencies.readSecret = secrets.read; dependencies.writeSecret = secrets.write; dependencies.removeSecret = secrets.remove
        dependencies.resolve = { _ in ResolvedMac(address: "127.0.0.1", port: secrets.port) }
        let client = LocalCatalogClient(testingNamespace: namespace, dependencies: dependencies)
        addTeardownBlock { await client.stop() }
        await client.start()
        try await wait { await !first.currentState.pending.isEmpty }
        let proposed = await first.currentState.pending.first; let initial = try XCTUnwrap(proposed)
        try await first.approve(initial.id)
        try await wait { if case .connected = await client.currentState.status { return true }; return false }
        let original = try XCTUnwrap(secrets.token(namespace)), device = try XCTUnwrap(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).approvals.first?.id)
        await second.setRequestService(fixture.service); try await second.start()
        try await wait { await (second.listeningPort ?? 0) > 0 }
        let secondPort = await second.listeningPort; secrets.port = try XCTUnwrap(secondPort)
        try await wait { await first.listeningPort == nil }
        XCTAssertEqual(secrets.token(namespace), original)
        await client.stop(); await client.start()
        try await wait { if case .connected = await client.currentState.status { return true }; return false }
        XCTAssertEqual(secrets.token(namespace), original)
        let pending = await second.currentState.pending; XCTAssertTrue(pending.isEmpty)
        try await second.revoke(device)
        // Authentication with the actual old credential must now be permanently rejected.
        let stale = try await tls(second)
        var auth = LocalMessage(operation: "authenticate"); auth.deviceID = device; auth.token = original
        let rejection = try await stale.exchange(LocalPacket(message: auth)); XCTAssertEqual(rejection.message.error, "revoked")
        await client.stop(); await client.start()
        try await wait { secrets.token(namespace) == nil }
    }

    func testIdleAccountRegistryPrunesWeakAuthorities() {
        let registry = TrustedAuthorityRegistry.shared, before = TrustedAuthorityRegistry.shared.count
        for _ in 0..<100 {
            var authority: TrustedApprovalsCoordinator? = .keychain(namespace: "idle-account-" + UUID().uuidString)
            weak let released = authority
            XCTAssertNotNil(authority); authority = nil; XCTAssertNil(released)
        }
        XCTAssertEqual(registry.count, before)
    }
    func testAuthorityRetainsUnresolvedStorageRecoveryButReleasesHealthyIdleService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), gate = TrustedWriteGate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        var service: ShaderRequestService? = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: root.appendingPathComponent("unused.py"),
            beforePersistenceReplacement: { if $0.lastPathComponent == "journal.json", gate.wait() { throw POSIXError(.EIO) } })
        weak let retained = service
        await service!.suspend(); try await service!.initialize(configuration: .init(repository: root.path, enabled: true))
        let authority = TrustedBackendFixture(nil).coordinator(), owner = TrustedOwnerRecorder()
        try await accept(authority.register(owner.owner(service: service)))
        let request = ShaderRequest(prompt: "Rejected storage proposal", context: try context())
        gate.arm(); let submission = Task { [target = service!] in try await target.control(operation: "requestSubmit", payload: .init(request: request), deviceID: "A") }
        try await wait { gate.entered }; gate.release()
        do { _ = try await submission.value; XCTFail("Storage fault accepted") } catch is RequestPersistence.Fault {}
        try await wait { await authority.observation.recoveryPins == 1 }
        service = nil; XCTAssertNotNil(retained)
        // The authority's weak metadata would otherwise lose the writer's RAM before-images.
        try await retained!.retryReconciliation()
        try await wait { await authority.observation.recoveryPins == 0 }
        try await wait { retained == nil }
    }

    func testRetirementBeforeRevocationWriteAdmissionPreservesApprovals() async throws {
        let fixture = try await fixture(), gate = RecoveryGate()
        let original = try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded()
        let backend = TrustedBackendFixture(original), authority = backend.coordinator()
        let server = LocalCatalogServer(catalog: fixture.catalog, testingNamespace: "retire-write-" + UUID().uuidString,
            beforeTrustedCommit: { _ in try await gate.wait() }, trustedApprovals: authority)
        await server.setRequestService(fixture.service); try await server.start()
        let revoke = Task { try await server.revoke("A") }
        try await wait { await gate.hasEntered }
        let shutdown = Task { await server.shutdown() }
        try await wait { await server.listeningPort == nil }
        await gate.release()
        do { try await revoke.value; XCTFail("Retired lifetime started a trusted write") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        await shutdown.value
        XCTAssertEqual(backend.read(), original); XCTAssertEqual(backend.writes, 0)
        try await server.clearTestSecrets()
    }

    func testFailedReinspectionTransfersUnresolvedTargetPinToNewEpoch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var service: ShaderRequestService? = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root)
        weak let retained = service
        await service!.suspend(); try await service!.initialize(configuration: .init(repository: root.path, enabled: true))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator(), owner = TrustedOwnerRecorder()
        try await accept(authority.register(owner.owner(service: service)))
        await service!.registerRevocationCoordinator(id: UUID()) {}
        backend.failReads(true)
        do { try await accept(authority.register(owner.owner(service: service))); XCTFail("Failed reinspection accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        service = nil; XCTAssertNotNil(retained)
        backend.failReads(false)
        try await retained!.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        try await wait { retained == nil }
    }

}
#endif
