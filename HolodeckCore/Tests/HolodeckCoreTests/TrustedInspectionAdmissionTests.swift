#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedInspectionAdmissionTests: XCTestCase {
    private func fixture() async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr55-inspection-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
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
        try await wait { await authority.observation.preparingGeneration == latest.generation }
        backend.gateReads(nil); gate.release()
        _ = try await accepted(latest)
        XCTAssertEqual(backend.reads, reads + 1)
        let abandoned = await owner.binding; XCTAssertNil(abandoned)
    }
}
@MainActor private final class InspectionResult<Value: Sendable> { var value: Result<Value, Error>? }
#endif
