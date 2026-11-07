#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

final class TrustedBackendFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var writeCount = 0
    private var fail = false
    private var readFailure = false
    init(_ data: Data?) { self.data = data }
    func read() -> Data? { lock.withLock { data } }
    func write(_ value: Data) throws {
        try lock.withLock { if fail { throw POSIXError(.EIO) }; data = value; writeCount += 1 }
    }
    func failReads(_ value: Bool) { lock.withLock { readFailure = value } }
    func checkedRead() throws -> Data? { try lock.withLock { if readFailure { throw POSIXError(.EACCES) }; return data } }
    func failWrites(_ value: Bool) { lock.withLock { fail = value } }
    var writes: Int { lock.withLock { writeCount } }
    func coordinator() -> TrustedApprovalsCoordinator { .init(read: { try self.checkedRead() }, write: { try self.write($0) }) }
}
actor TrustedOwnerRecorder {
    var binding: TrustedApprovalsCoordinator.Binding?
    var snapshot: TrustedApprovalsCoordinator.Snapshot?
    var retired = false
    nonisolated func owner(service: ShaderRequestService? = nil) -> TrustedApprovalsCoordinator.Owner {
        .init(serverID: UUID(), service: service, changed: { await self.accept($0, $1) }, retired: { await self.retire() }, beforeReplay: { _ in })
    }
    private func accept(_ snapshot: TrustedApprovalsCoordinator.Snapshot, _ binding: TrustedApprovalsCoordinator.Binding) {
        self.snapshot = snapshot; self.binding = binding
    }
    private func retire() { retired = true }
}
@MainActor final class TrustedApprovalsTests: XCTestCase {
    private func binding(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        switch try await registration.value() {
        case .accepted(let binding): return binding
        case .superseded: throw ShaderRequestError.unavailable("Unexpected superseded fixture binding")
        }
    }
    private func wait(_ test: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await test()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Trusted test backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testReservedRevokeFinishesBeforeReplacementAndCannotBeRestoredByStaleOwner() async throws {
        let backend = TrustedBackendFixture(try JSONEncoder().encode([ApprovedTV(id: "B", name: "B", tokenHash: "old-B"), ApprovedTV(id: "C", name: "C", tokenHash: "C")]))
        let coordinator = backend.coordinator(), old = TrustedOwnerRecorder(), replacement = TrustedOwnerRecorder(), gate = RecoveryGate()
        let accepted = try await binding(coordinator.register(old.owner()))
        let revoke = Task { try await coordinator.revoke("B", permit: accepted.permit) { _ in try await gate.wait() } }
        try await wait { await gate.hasEntered }
        let ticket = try await coordinator.register(replacement.owner())
        let queued = await coordinator.observation
        XCTAssertEqual(queued.queuedGeneration, ticket.generation)
        XCTAssertEqual(queued.acceptedGeneration, accepted.permit.generation)
        XCTAssertTrue(accepted.permit.isCurrent); XCTAssertEqual(backend.writes, 0)
        await gate.release(); try await revoke.value
        let current = try await binding(ticket)
        XCTAssertFalse(accepted.permit.isCurrent)
        let retired = await old.retired; XCTAssertTrue(retired)
        let before = await coordinator.observation
        do { try await coordinator.revoke("C", permit: accepted.permit) { _ in }; XCTFail("Retired writer accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
        let after = await coordinator.observation; XCTAssertEqual(after.encodings, before.encodings); XCTAssertEqual(after.writes, before.writes)
        try await coordinator.revoke("C", permit: current.permit) { _ in }
        let envelope = try TrustedTVApprovals.decode(XCTUnwrap(backend.read()))
        XCTAssertTrue(envelope.approvals.isEmpty); XCTAssertEqual(Set(envelope.revocations.map(\.deviceID)), ["B", "C"])
    }
    func testLatestAdmittedRegistrationWinsAndCancelledNewestDoesNotReviveOlder() async throws {
        for cancelNewest in [false, true] {
            let backend = TrustedBackendFixture(try JSONEncoder().encode([ApprovedTV(id: "A", name: "A", tokenHash: "A")]))
            let coordinator = backend.coordinator(), old = TrustedOwnerRecorder(), gate = RecoveryGate()
            let initial = try await binding(coordinator.register(old.owner()))
            let mutation = Task { try await coordinator.revoke("A", permit: initial.permit) { _ in try await gate.wait() } }
            try await wait { await gate.hasEntered }
            let earlier = try await coordinator.register(TrustedOwnerRecorder().owner())
            let later = try await coordinator.register(TrustedOwnerRecorder().owner())
            let witnessed = await coordinator.observation
            XCTAssertEqual(witnessed.queuedGeneration, later.generation); XCTAssertEqual(witnessed.acceptedGeneration, initial.permit.generation)
            if cancelNewest { later.completion.cancel() }
            await gate.release(); try await mutation.value
            if case .accepted = try await earlier.value() { XCTFail("Superseded registration activated") }
            if cancelNewest {
                do { _ = try await later.value(); XCTFail("Cancelled registration activated") } catch is CancellationError {}
                try await wait { let state = await coordinator.observation; return state.preparingGeneration == nil && state.queuedGeneration == nil }
                XCTAssertTrue(initial.permit.isCurrent)
            } else {
                let final = try await binding(later); XCTAssertEqual(final.permit.generation, later.generation)
                XCTAssertFalse(initial.permit.isCurrent)
            }
        }
    }
    func testFailedInitialInspectionCanBeRetriedWithoutPublishingAnUnacceptedBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = DirectoryCatalog(directory: root.appendingPathComponent("catalog"))
        let service = ShaderRequestService(catalog: catalog, directory: root, workerScript: root.appendingPathComponent("unused.py"))
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        let original = try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded()
        let backend = TrustedBackendFixture(original), authority = backend.coordinator()
        let server = LocalCatalogServer(catalog: catalog, testingNamespace: "inspection-retry", trustedApprovals: authority)
        backend.failReads(true); await server.setRequestService(service)
        do { _ = try await server.requestAuthorization(for: "A"); XCTFail("Unaccepted initial binding published") }
        catch { XCTAssertTrue(error.localizedDescription.contains("handoff is pending")) }
        let statuses = await service.recoveryStatuses(); XCTAssertTrue(statuses.contains { $0.message.contains(POSIXError(.EACCES).localizedDescription) })
        XCTAssertEqual(backend.read(), original); XCTAssertEqual(backend.writes, 0)
        backend.failReads(false); try await service.retryReconciliation()
        let authorization = try await server.requestAuthorization(for: "A"); XCTAssertTrue(authorization.isCurrent)
        let recovered = await service.recoveryStatuses(); XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(backend.read(), original); XCTAssertEqual(backend.writes, 0)
    }

    func testReplacementReadsFreshBackendAndPreservesNewTokens() async throws {
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "old")]).encoded())
        let coordinator = backend.coordinator(), first = TrustedOwnerRecorder(), next = TrustedOwnerRecorder()
        _ = try await binding(coordinator.register(first.owner()))
        let newer = try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "new")]).encoded()
        try backend.write(newer)
        let permit = try await binding(coordinator.register(next.owner())).permit
        let snapshot = await next.snapshot; XCTAssertEqual(snapshot?.approvals["A"]?.tokenHash, "new")
        let before = await coordinator.observation
        try await coordinator.revoke("missing", permit: permit) { _ in }
        let after = await coordinator.observation; XCTAssertEqual(before.encodings, after.encodings); XCTAssertEqual(backend.read(), newer)
    }
}
#endif
