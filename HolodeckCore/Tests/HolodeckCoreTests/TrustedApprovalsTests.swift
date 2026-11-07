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
    private var readGate: TrustedReadGate?
    func gateReads(_ gate: TrustedReadGate?) { lock.withLock { readGate = gate } }
    init(_ data: Data?) { self.data = data }
    func read() -> Data? { lock.withLock { data } }
    func write(_ value: Data) throws {
        try lock.withLock { if fail { throw POSIXError(.EIO) }; data = value; writeCount += 1 }
    }
    func failReads(_ value: Bool) { lock.withLock { readFailure = value } }
    func checkedRead() throws -> Data? {
        lock.withLock { readGate }?.wait()
        return try lock.withLock { if readFailure { throw POSIXError(.EACCES) }; return data }
    }
    func failWrites(_ value: Bool) { lock.withLock { fail = value } }
    var writes: Int { lock.withLock { writeCount } }
    func coordinator() -> TrustedApprovalsCoordinator { .init(read: { try self.checkedRead() }, write: { try self.write($0) }) }
}
final class TrustedReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false, reached = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return reached }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        reached = true
        let limit = Date().addingTimeInterval(8)
        while !open { if !condition.wait(until: limit) { return } }
    }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
}
actor TrustedOwnerRecorder {
    nonisolated let serverID = UUID()
    var binding: TrustedApprovalsCoordinator.Binding?
    var snapshot: TrustedApprovalsCoordinator.Snapshot?
    var retired = false
    nonisolated func owner(service: ShaderRequestService? = nil,
                           beforeReplay: @escaping @Sendable (RequestRevocationIntent) async throws -> Void = { _ in }) -> TrustedApprovalsCoordinator.Owner {
        .init(serverID: serverID, service: service, changed: { await self.accept($0, $1) }, retired: { await self.retire() }, beforeReplay: beforeReplay)
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
            let firstPriority: TaskPriority = cancelNewest ? .userInitiated : .background
            let secondPriority: TaskPriority = cancelNewest ? .background : .userInitiated
            let earlier = try await Task(priority: firstPriority) { try await coordinator.register(TrustedOwnerRecorder().owner()) }.value
            let later = try await Task(priority: secondPriority) { try await coordinator.register(TrustedOwnerRecorder().owner()) }.value
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


    func testRegistrationPreparingAcrossAwaitCannotOvertakeNewerAdmission() async throws {
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        let initialOwner = TrustedOwnerRecorder(), overtakenOwner = TrustedOwnerRecorder(), latestOwner = TrustedOwnerRecorder()
        let initial = try await binding(authority.register(initialOwner.owner()))
        let gate = TrustedReadGate(); backend.gateReads(gate)
        defer { gate.release() }
        let overtaken = try await authority.register(overtakenOwner.owner())
        try await wait { gate.entered }
        let preparing = await authority.observation
        XCTAssertEqual(preparing.preparingGeneration, overtaken.generation)
        let latest = try await authority.register(latestOwner.owner())
        let admitted = await authority.observation
        XCTAssertEqual(admitted.queuedGeneration, latest.generation)
        XCTAssertEqual(admitted.acceptedGeneration, initial.permit.generation)
        gate.release()
        if case .accepted = try await overtaken.value() { XCTFail("Older preparing registration activated") }
        let accepted = try await binding(latest)
        let unexpected = await overtakenOwner.binding; XCTAssertNil(unexpected)
        XCTAssertFalse(initial.permit.isCurrent); XCTAssertTrue(accepted.permit.isCurrent)
        // A repeated explicit registration is another admission, without another trusted write.
        let repeated = try await binding(authority.register(latestOwner.owner()))
        XCTAssertGreaterThan(repeated.permit.generation, accepted.permit.generation)
        let work = await authority.observation; XCTAssertEqual(work.encodings, 0); XCTAssertEqual(work.writes, 0)
    }
    func testFailedReplacementLeavesAcceptedOwnerAndRetainsMutationDiagnostic() async throws {
        let original = try TrustedTVApprovals(approvals: [ApprovedTV(id: "A", name: "A", tokenHash: "A")]).encoded()
        let backend = TrustedBackendFixture(original), authority = backend.coordinator()
        let initialOwner = TrustedOwnerRecorder(), replacement = TrustedOwnerRecorder()
        let initial = try await binding(authority.register(initialOwner.owner()))
        backend.failReads(true)
        do { _ = try await binding(authority.register(replacement.owner())); XCTFail("Unreadable replacement accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EACCES) }
        XCTAssertTrue(initial.permit.isCurrent)
        let absent = await replacement.binding; XCTAssertNil(absent)
        backend.failReads(false); backend.failWrites(true)
        do { try await authority.revoke("A", permit: initial.permit) { _ in }; XCTFail("Failed write accepted") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertEqual(backend.read(), original)
        let before = await initialOwner.snapshot
        XCTAssertTrue(before?.diagnostic?.contains("TV revocation for A") == true)
        XCTAssertTrue(before?.diagnostic?.contains(POSIXError(.EIO).localizedDescription) == true)
        _ = try await binding(authority.register(replacement.owner()))
        let after = await replacement.snapshot; XCTAssertEqual(after?.diagnostic, before?.diagnostic)
        XCTAssertEqual(after?.approvals["A"]?.tokenHash, "A")
        let work = await authority.observation; XCTAssertEqual(work.writes, 0); XCTAssertEqual(work.encodings, 1)
    }

    func testIntentDiagnosticsKeepInitiatingFailureAcrossReplacementAndSecondaryFault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root, workerScript: root.appendingPathComponent("unused.py"))
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "A")
        let original = try TrustedTVApprovals(revocations: [intent]).encoded()
        let backend = TrustedBackendFixture(original), authority = backend.coordinator()
        _ = try await binding(authority.register(TrustedOwnerRecorder().owner(service: service, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Failed replay accepted") }
        catch { XCTAssertEqual(error.localizedDescription, POSIXError(.EIO).localizedDescription) }
        _ = try await binding(authority.register(TrustedOwnerRecorder().owner(service: service, beforeReplay: { _ in throw POSIXError(.EACCES) })))
        do { try await authority.replay(); XCTFail("Secondary replay fault accepted") }
        catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix(POSIXError(.EIO).localizedDescription))
            XCTAssertTrue(error.localizedDescription.contains("Additional trusted failure: " + POSIXError(.EACCES).localizedDescription))
        }
        let statuses = await service.recoveryStatuses()
        XCTAssertTrue(statuses.contains { $0.message.contains(POSIXError(.EIO).localizedDescription) && $0.message.contains(POSIXError(.EACCES).localizedDescription) })
        XCTAssertEqual(backend.read(), original)
        let work = await authority.observation; XCTAssertEqual(work.writes, 0); XCTAssertEqual(work.encodings, 0)
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
