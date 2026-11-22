#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedActivationBoundaryTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }, initialized: Bool = true) async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr52-activation-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile)
        await service.suspend()
        if initialized { try await service.initialize(configuration: .init(repository: root.path, enabled: true)) }
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Activation boundary backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func accepted(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        let result = ActivationResult<TrustedApprovalsCoordinator.BindingOutcome>()
        let task = Task { do { result.value = .success(try await registration.value()) } catch { result.value = .failure(error) } }
        addTeardownBlock { task.cancel(); registration.completion.cancel() }
        try await wait { result.value != nil }
        guard case .accepted(let binding) = try XCTUnwrap(result.value).get() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    func testPublishedBindingCanFenceRecoveryBeforeConfigureReturns() async throws {
        let configured = RecoveryGate(), repairing = RecoveryGate(), armed = ActivationSwitch()
        addTeardownBlock { await configured.release(); await repairing.release() }
        let service = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            afterTargetInstallation: { _ in try await configured.wait() })
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { registration.completion.cancel(); await configured.release(); await repairing.release() }
        try await wait { await configured.hasEntered }
        armed.on = true
        let local = Task { try await service.recoverDepartureLocal() }
        addTeardownBlock { local.cancel(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        let expected = await service.prepareTargetInstallation(authority: authority.id)
        armed.on = false; await repairing.release()
        let result = try await local.value
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.receipt?.authority, authority.id)
        XCTAssertEqual(result.receipt?.registrationID, expected.registration)
        let pending = await authority.observation
        XCTAssertTrue(pending.transitionActive); XCTAssertEqual(pending.targets, 1)
        XCTAssertNil(pending.acceptedGeneration)
        await configured.release(); _ = try await accepted(registration)
        XCTAssertEqual(backend.writes, 0)
    }
    func testPublishedTargetSurvivesLaterConfigurationFailure() async throws {
        let fault = ActivationSwitch(); fault.on = true
        let service = try await fixture(), backend = TrustedBackendFixture(nil)
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            afterTargetInstallation: { _ in if fault.on { throw POSIXError(.EIO) } })
        do { _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service))); XCTFail("Injected installation failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let local = try await service.recoverDepartureLocal()
        XCTAssertTrue(local.completed); XCTAssertEqual(local.receipt?.authority, authority.id)
        let retained = await authority.observation; XCTAssertEqual(retained.targets, 1)
        fault.on = false
        _ = try await accepted(authority.register(TrustedOwnerRecorder().owner(service: service)))
        XCTAssertEqual(backend.writes, 0)
    }
    func testActivationRejectsFailedLocalRepairAfterWaiting() async throws {
        let armed = ActivationSwitch(), repairing = RecoveryGate(), reading = TrustedReadGate()
        addTeardownBlock { await repairing.release(); reading.release() }
        let service = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait(); throw POSIXError(.EIO) } })
        let old = TrustedBackendFixture(nil).coordinator(), nextBackend = TrustedBackendFixture(nil), next = nextBackend.coordinator()
        let oldBinding = try await accepted(old.register(TrustedOwnerRecorder().owner(service: service)))
        nextBackend.gateReads(reading)
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: service))
        addTeardownBlock { registration.completion.cancel(); await repairing.release(); reading.release() }
        try await wait { reading.entered }
        armed.on = true
        let local = Task { try await service.recoverDepartureLocal() }
        addTeardownBlock { local.cancel(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        nextBackend.gateReads(nil); reading.release()
        try await wait { await service.localPreparationWaiters == 1 }
        await repairing.release()
        let failure = try await local.value; XCTAssertFalse(failure.completed)
        do { _ = try await accepted(registration); XCTFail("A failed repair authorized activation") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let original = await old.observation, replacement = await next.observation
        XCTAssertEqual(original.acceptedGeneration, oldBinding.permit.generation)
        XCTAssertNil(replacement.acceptedGeneration); XCTAssertEqual(replacement.targets, 0)
        let current = await service.prepareTargetInstallation(authority: old.id)
        XCTAssertEqual(current.predecessorAuthority, old.id)
        let recoveries = await service.recoveryStatuses(); XCTAssertFalse(recoveries.isEmpty)
    }
    func testEarlyHandoffReturnsSetupPendingUntilExplicitRetry() async throws {
        let service = try await fixture(initialized: false), old = TrustedBackendFixture(nil).coordinator(), nextBackend = TrustedBackendFixture(nil), next = nextBackend.coordinator()
        let original = try await accepted(old.register(TrustedOwnerRecorder().owner(service: service)))
        do { _ = try await accepted(next.register(TrustedOwnerRecorder().owner(service: service))); XCTFail("Uninspected startup authorized a handoff") }
        catch is TrustedSetupPending { }
        let retained = await old.observation, rejected = await next.observation
        XCTAssertEqual(retained.acceptedGeneration, original.permit.generation)
        XCTAssertEqual(retained.departures, 0); XCTAssertNil(rejected.acceptedGeneration)
        let before = await service.setupSnapshot(); XCTAssertNil(before.configuration)
        let journal = await service.trustedRecoveryJournal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.appendingPathComponent("preferences.json").path))
        try await service.initialize(configuration: .init(repository: journal.path, model: "captured-model", enabled: true))
        let stillRejected = await next.observation; XCTAssertNil(stillRejected.acceptedGeneration)
        _ = try await accepted(next.register(TrustedOwnerRecorder().owner(service: service)))
        let settings = await service.configurationValue(); XCTAssertEqual(settings.model, "captured-model")
        XCTAssertEqual(nextBackend.writes, 0)
    }
}
@MainActor private final class ActivationResult<Value: Sendable> { var value: Result<Value, Error>? }
private final class ActivationSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
