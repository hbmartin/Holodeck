#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedInspectionAdmissionTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr55-inspection-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw ShaderRequestError.unavailable("Inspection admission backstop") }
            try await Task.sleep(for: .milliseconds(3))
        }
    }
    private func accepted(_ ticket: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        let result = InspectionResult<TrustedApprovalsCoordinator.BindingOutcome>()
        let task = Task { do { result.value = .success(try await ticket.value()) } catch { result.value = .failure(error) } }
        addTeardownBlock { task.cancel(); ticket.completion.cancel() }
        try await wait { result.value != nil }
        guard case .accepted(let binding) = try XCTUnwrap(result.value).get() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    func testShutdownDuringSameAuthorityReadRetainsAcceptedServer() async throws {
        let service = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let catalog = DirectoryCatalog(directory: URL(fileURLWithPath: "/private/tmp/unused-pr55-catalog"))
        let old = LocalCatalogServer(catalog: catalog, testingNamespace: "pr55-old", trustedApprovals: authority)
        let next = LocalCatalogServer(catalog: catalog, testingNamespace: "pr55-next", trustedApprovals: authority)
        addTeardownBlock { await old.shutdown(); await next.shutdown() }
        await old.setRequestService(service)
        let initial = await authority.observation
        backend.gateReads(gate)
        let proposal = Task { await next.setRequestService(service) }
        addTeardownBlock { proposal.cancel(); gate.release() }
        try await wait { gate.entered }
        let withdrawal = await next.shutdownReceipt()
        try await wait { await authority.observation.preparingGeneration == nil }
        let state = await authority.observation, oldState = await old.currentState
        XCTAssertEqual(state.acceptedGeneration, initial.acceptedGeneration)
        XCTAssertNotEqual(oldState.message, "This catalog server was replaced.")
        try await withdrawal.value()
        backend.gateReads(nil); gate.release(); await proposal.value
        let final = await authority.observation
        XCTAssertEqual(final.acceptedGeneration, initial.acceptedGeneration)
    }
    func testInitialWithdrawalAndSameAuthoritySupersessionArePreAdmission() async throws {
        for initial in [true, false] {
            let service = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), gate = TrustedReadGate()
            addTeardownBlock { gate.release() }
            if !initial { _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))) }
            backend.gateReads(gate)
            let owner = TrustedOwnerRecorder().owner(service: service), ticket = try await authority.register(owner)
            addTeardownBlock { ticket.completion.cancel() }
            try await wait { gate.entered }; XCTAssertFalse(ticket.completion.hasStarted)
            if initial {
                let status = try await service.control(operation: "requestStatus", payload: .init(), deviceID: "TV")
                XCTAssertFalse(status.enabled); XCTAssertTrue(status.message.contains("not been inspected"))
            }
            let withdrawal = Task { await authority.withdraw(serverID: owner.serverID, eligibility: owner.eligibility) }
            addTeardownBlock { withdrawal.cancel() }
            let result = InspectionResult<TrustedApprovalsCoordinator.BindingOutcome>()
            let completion = Task { do { result.value = .success(try await ticket.value()) } catch { result.value = .failure(error) } }
            addTeardownBlock { completion.cancel() }
            try await wait { result.value != nil }
            guard case .superseded = try XCTUnwrap(result.value).get() else { return XCTFail("Withdrawn candidate accepted") }
            backend.gateReads(nil); gate.release(); await withdrawal.value
        }
    }
    func testQueuedSourceRevocationYieldsDestinationReadBeforeItReturns() async throws {
        let service = try await fixture()
        let source = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let old = source.coordinator(), destination = TrustedBackendFixture(nil), next = destination.coordinator(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let binding = try await accepted(old.register(TrustedOwnerRecorder().owner(service: service)))
        destination.gateReads(gate)
        let proposal = try await next.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { proposal.completion.cancel() }
        try await wait { gate.entered }
        let revoke = Task { try await old.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { revoke.cancel(); gate.release() }
        try await wait { (try? source.read().map(TrustedTVApprovals.decode)?.approvals.isEmpty) == true }
        XCTAssertTrue(gate.entered); XCTAssertFalse(proposal.completion.hasStarted)
        try await revoke.value
        destination.gateReads(nil); gate.release()
        _ = try await accepted(proposal)
        XCTAssertEqual(source.writes, 2)
    }
    func testSupersessionDuringYieldCleanupRemainsTypedSupersession() async throws {
        let local = RecoveryGate(), inspection = RecoveryGate(), latestPreparation = RecoveryGate()
        let repairing = InspectionSwitch(), inspecting = InspectionSwitch(), latestWaiting = InspectionSwitch()
        addTeardownBlock { await local.release(); await inspection.release(); await latestPreparation.release() }
        let service = try await fixture(reconcile: { _ in if repairing.on { try await local.wait() } })
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let old = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeTargetInspection: { _ in
            if inspecting.on { try await inspection.wait() }
        })
        let destination = TrustedBackendFixture(nil)
        let next = TrustedApprovalsCoordinator(read: { try destination.checkedRead() }, write: { try destination.write($0) }, beforeAuthorityPreparation: { _ in
            if latestWaiting.on { try await latestPreparation.wait() }
        })
        let binding = try await accepted(old.register(TrustedOwnerRecorder().owner(service: service)))
        repairing.on = true
        let repair = Task { try await service.trustedRecoveryOutcome() }
        addTeardownBlock { repair.cancel(); await local.release() }
        try await wait { await local.hasEntered }
        let ticket = try await next.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { ticket.completion.cancel() }
        try await wait { await service.localPreparationWaiters > 0 }
        inspecting.on = true
        let revoke = Task { try await old.revoke("TV", permit: binding.permit) { _ in } }
        addTeardownBlock { revoke.cancel(); await inspection.release() }
        try await wait { await inspection.hasEntered }
        latestWaiting.on = true
        let newest = try await next.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { newest.completion.cancel() }
        inspecting.on = false; await inspection.release(); repairing.on = false; await local.release()
        _ = try await repair.value
        guard case .superseded = try await ticket.value() else { return XCTFail("Yielded candidate did not resolve as superseded") }
        do { try await revoke.value }
        catch { XCTAssertTrue(error.localizedDescription.contains("Target local recovery is still preparing")) }
        // The separately gated local phase can outlive the revocation caller.
        // Finish its remaining replay before admitting the newest preparation.
        try await old.replay()
        latestWaiting.on = false; await latestPreparation.release()
        _ = try await accepted(newest)
    }
    func testCancelledReadCannotReplaceANewerAcceptedTrustedWrite() async throws {
        let service = try await fixture()
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = backend.coordinator(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let first = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))), reads = backend.reads
        backend.gateReads(gate)
        let cancelled = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { cancelled.completion.cancel() }
        try await wait { gate.entered }; cancelled.completion.cancel()
        do { _ = try await cancelled.value(); XCTFail("Cancelled inspection accepted") } catch is CancellationError {}
        try await wait { await authority.observation.preparingGeneration == nil }
        try await authority.revoke("TV", permit: first.permit) { _ in }
        XCTAssertEqual(backend.writes, 2)
        let latest = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { latest.completion.cancel() }
        try await wait { await authority.observation.rawReadSubscribers == 1 }
        backend.gateReads(nil); gate.release(); _ = try await accepted(latest)
        XCTAssertEqual(backend.reads, reads + 2) // Discard the obsolete read, then inspect current bytes.
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).approvals.isEmpty)
        let state = await authority.observation
        XCTAssertEqual(state.rawReadFlights, 0); XCTAssertEqual(state.rawReadSubscribers, 0)
        XCTAssertEqual(state.revocationCompletionTasks, 0); XCTAssertEqual(state.automaticValidationTasks, 0)
    }
    func testObsoleteReadFailureCannotInvalidateANewerTrustedWrite() async throws {
        let service = try await fixture(), gate = TrustedReadGate(), failOne = InspectionSwitch()
        addTeardownBlock { gate.release() }
        let backend = TrustedBackendFixture(try TrustedTVApprovals(approvals: [.init(id: "TV", name: "TV", tokenHash: "old")]).encoded())
        let authority = TrustedApprovalsCoordinator(read: {
            if failOne.on { failOne.on = false; gate.wait(); throw POSIXError(.EIO) }
            return try backend.checkedRead()
        }, write: { try backend.write($0) })
        let first = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service)))
        failOne.on = true
        let cancelled = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { cancelled.completion.cancel() }
        try await wait { gate.entered }; cancelled.completion.cancel()
        do { _ = try await cancelled.value(); XCTFail("Cancelled inspection accepted") } catch is CancellationError {}
        try await wait { await authority.observation.preparingGeneration == nil }
        try await authority.revoke("TV", permit: first.permit) { _ in }
        let owner = TrustedOwnerRecorder(), latest = try await authority.register(owner.owner(service: service))
        addTeardownBlock { latest.completion.cancel() }
        try await wait { await authority.observation.rawReadSubscribers == 1 }
        gate.release(); _ = try await accepted(latest)
        let diagnostic = await owner.snapshot?.diagnostic; XCTAssertNil(diagnostic)
        XCTAssertEqual(backend.writes, 2)
    }
    func testRawReadAndSubscriptionsStayBoundedAcrossCancelledRegistrations() async throws {
        let service = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service)))
        let reads = backend.reads, start = ContinuousClock.now
        backend.gateReads(gate)
        for _ in 0..<40 {
            let ticket = try await authority.register(TrustedOwnerRecorder().owner(service: service))
            addTeardownBlock { ticket.completion.cancel() }
            try await wait { await authority.observation.rawReadSubscribers == 1 }
            ticket.completion.cancel()
            do { _ = try await ticket.value(); XCTFail("Cancelled registration accepted") } catch is CancellationError {}
            try await wait { let state = await authority.observation; return state.preparingGeneration == nil && state.rawReadSubscribers == 0 }
            let state = await authority.observation
            XCTAssertEqual(state.rawReadFlights, 1); XCTAssertEqual(state.encodings, 0); XCTAssertEqual(state.writes, 0)
        }
        let latest = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { latest.completion.cancel() }
        try await wait { await authority.observation.rawReadSubscribers == 1 }
        backend.gateReads(nil); gate.release(); _ = try await accepted(latest)
        XCTAssertEqual(backend.reads, reads + 1)
        let final = await authority.observation
        XCTAssertEqual(final.rawReadFlights, 0); XCTAssertEqual(final.rawReadSubscribers, 0)
        if ProcessInfo.processInfo.environment["HOLODECK_TRUSTED_PROFILE"] == "1" {
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("READ_CONTENTION_PROFILE commands=40 seconds=\(seconds) reads=\(backend.reads - reads) encodings=\(final.encodings) writes=\(final.writes) flights=\(final.rawReadFlights) subscribers=\(final.rawReadSubscribers) resumes=\(final.admissionResumes)")
        }
    }
    func testCancelledReadDoesNotPublishAndNewestRegistrationSharesRawFlight() async throws {
        let service = try await fixture(), backend = TrustedBackendFixture(nil), authority = backend.coordinator(), gate = TrustedReadGate()
        addTeardownBlock { gate.release() }
        let first = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service)))
        let reads = backend.reads
        backend.gateReads(gate)
        let owner = TrustedOwnerRecorder(), cancelled = try await authority.register(owner.owner(service: service))
        addTeardownBlock { cancelled.completion.cancel() }
        try await wait { gate.entered }; cancelled.completion.cancel()
        do { _ = try await cancelled.value(); XCTFail("Cancelled read accepted") } catch is CancellationError {}
        try await wait { await authority.observation.preparingGeneration == nil }
        XCTAssertTrue(first.permit.isCurrent)
        let latest = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { latest.completion.cancel() }
        try await wait { await authority.observation.rawReadSubscribers == 1 }
        backend.gateReads(nil); gate.release()
        _ = try await accepted(latest)
        XCTAssertEqual(backend.reads, reads + 1)
        let abandoned = await owner.binding; XCTAssertNil(abandoned)
    }
}
@MainActor private final class InspectionResult<Value: Sendable> { var value: Result<Value, Error>? }
private final class InspectionSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
