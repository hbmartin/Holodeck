#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRecoveryOwnershipTests: XCTestCase {
    private func fixture(reconcile: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> ShaderRequestService {
        let root = URL(fileURLWithPath: "/private/tmp/pr51-ownership-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
            directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: reconcile)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return service
    }
    private func accept(_ registration: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await completed({ try await registration.value() }) else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Recovery ownership backstop") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func completed<Value: Sendable>(_ body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let result = RecoveryOwnershipCompletion<Value>()
        let task = Task {
            do { result.value = .success(try await body()) }
            catch { result.value = .failure(error) }
        }
        addTeardownBlock { task.cancel() }
        try await wait { result.value != nil }
        return try XCTUnwrap(result.value).get()
    }
    func testLocalPreparationStartsWhileRegistrationHoldsTrustedRead() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate(), read = TrustedReadGate()
        addTeardownBlock { read.release(); await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } }), b = try await fixture()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        backend.gateReads(read)
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: b))
        addTeardownBlock { registration.completion.cancel(); read.release() }
        try await wait { read.entered }; armed.on = true
        let recovery = Task { try await a.retryReconciliation() }
        addTeardownBlock { recovery.cancel(); read.release(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        XCTAssertTrue(read.entered)
        let held = await authority.observation
        XCTAssertTrue(held.transitionActive)
        armed.on = false; await repairing.release(); read.release(); backend.gateReads(nil)
        _ = try await accept(registration); try await completed { try await recovery.value }
        XCTAssertEqual(backend.writes, 0)
    }
    func testHandoffWaitsForMetadataButNotTrustedResultHold() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate()
        addTeardownBlock { await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let old = TrustedBackendFixture(nil).coordinator(), next = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a)))
        armed.on = true; let pass = UUID()
        let local = Task { try await a.trustedRecoveryOutcome(pass: pass) }
        addTeardownBlock { local.cancel(); await repairing.release(); await a.finishTrustedRecovery(pass: pass) }
        try await wait { await repairing.hasEntered }
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel(); await repairing.release() }
        try await wait { await a.localPreparationWaiters == 1 }
        let pending = await next.observation; XCTAssertNil(pending.acceptedGeneration)
        armed.on = false; await repairing.release()
        let outcome = try await completed { try await local.value }
        XCTAssertEqual(outcome.receipt?.authority, old.id)
        _ = try await accept(registration)
        let checked = await a.validateTrustedRecovery(outcome)
        XCTAssertFalse(checked.completed)
        let accepted = await next.observation; XCTAssertEqual(accepted.targets, 1)
        await a.finishTrustedRecovery(pass: pass)
    }
    func testCancelledRegistrationLeavesLocalPreparationWaitPromptly() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate()
        addTeardownBlock { await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let old = TrustedBackendFixture(nil).coordinator(), next = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a)))
        armed.on = true
        let local = Task { try await a.trustedRecoveryOutcome() }
        addTeardownBlock { local.cancel(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel() }
        try await wait { await a.localPreparationWaiters == 1 }
        registration.completion.cancel()
        try await wait { await a.localPreparationWaiters == 0 }
        try await wait { await old.observation.departures == 0 }
        do { _ = try await registration.value(); XCTFail("Cancelled registration accepted") } catch is CancellationError {}
        armed.on = false; await repairing.release(); _ = try await completed { try await local.value }
    }
    func testCancelledRegistrationLeavesInspectionWaitWithoutCancellingInspection() async throws {
        let a = try await fixture(), b = try await fixture(), armed = RecoveryOwnershipSwitch()
        let gate = RecoveryGate(), reading = TrustedReadGate(), backend = TrustedBackendFixture(nil)
        addTeardownBlock { reading.release(); await gate.release() }
        let old = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeTargetInspection: { id in if id == a.runtimeID && armed.on { try await gate.wait() } })
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: a)))
        _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: b)))
        let destination = TrustedBackendFixture(nil), next = destination.coordinator(); destination.gateReads(reading)
        let registration = try await next.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel() }
        try await wait { reading.entered }; armed.on = true
        let recovery = Task { try await b.retryReconciliation() }
        addTeardownBlock { recovery.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }; destination.gateReads(nil); reading.release()
        try await wait { await old.observation.departureInspectionWaiters == 1 }
        registration.completion.cancel()
        try await wait { await old.observation.departureInspectionWaiters == 0 }
        do { _ = try await registration.value(); XCTFail("Cancelled inspection wait accepted") } catch is CancellationError {}
        armed.on = false; await gate.release(); try await completed { try await recovery.value }
        try await wait { await old.observation.departures == 0 }
    }
    func testWithdrawalPreventsInitialAndSameAuthorityAdmission() async throws {
        for initial in [true, false] {
            let a = try await fixture(), gate = RecoveryGate(), armed = RecoveryOwnershipSwitch(), backend = TrustedBackendFixture(nil)
            addTeardownBlock { await gate.release() }
            let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
                beforeAuthorityPreparation: { _ in if armed.on { try await gate.wait() } })
            if !initial { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a))) }
            armed.on = true
            let owner = TrustedOwnerRecorder().owner(service: a), registration = try await authority.register(owner)
            addTeardownBlock { registration.completion.cancel(); await gate.release() }
            try await wait { await gate.hasEntered }
            await authority.withdraw(serverID: owner.serverID, eligibility: owner.eligibility)
            armed.on = false; await gate.release()
            guard case .superseded = try await completed({ try await registration.value() }) else { return XCTFail("Withdrawn candidate accepted") }
        }
    }
    func testInitialBindingAlsoWaitsForUnboundLocalPreparation() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate()
        addTeardownBlock { await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } }), authority = TrustedBackendFixture(nil).coordinator()
        armed.on = true
        let local = Task { try await a.trustedRecoveryOutcome() }
        addTeardownBlock { local.cancel(); await repairing.release() }
        try await wait { await repairing.hasEntered }
        let registration = try await authority.register(TrustedOwnerRecorder().owner(service: a))
        addTeardownBlock { registration.completion.cancel(); await repairing.release() }
        try await wait { await a.localPreparationWaiters == 1 }
        armed.on = false; await repairing.release()
        let outcome = try await completed { try await local.value }
        XCTAssertNil(outcome.receipt?.authority)
        _ = try await accept(registration)
        let checked = await a.validateTrustedRecovery(outcome); XCTAssertFalse(checked.completed)
    }
    func testAdmittedRemovalCompletesBeforeTargetMetadataPreparation() async throws {
        let armed = RecoveryOwnershipSwitch(), repairing = RecoveryGate(), writing = TrustedReadGate()
        addTeardownBlock { writing.release(); await repairing.release() }
        let a = try await fixture(reconcile: { _ in if armed.on { try await repairing.wait() } })
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded())
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { data in writing.wait(); try backend.write(data) })
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let replay = Task { try await authority.replay() }
        addTeardownBlock { replay.cancel(); writing.release() }
        try await wait { writing.entered }; armed.on = true
        let before = await a.localRecoveryPhaseCount
        let local = Task { try await a.recoverDepartureLocal() }
        addTeardownBlock { local.cancel(); writing.release(); await repairing.release() }
        try await wait { await a.localRecoveryPhaseCount == before + 1 }
        let started = await repairing.hasEntered; XCTAssertFalse(started)
        writing.release(); try await completed { try await replay.value }
        try await wait { await repairing.hasEntered }
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        armed.on = false; await repairing.release()
        let outcome = try await completed { try await local.value }; XCTAssertTrue(outcome.completed)
        XCTAssertEqual(backend.writes, 1)
    }
    func testDepartureReusesOwnedLocalOutcomeIncludingFailure() async throws {
        for fail in [false, true] {
            let armed = RecoveryOwnershipSwitch(), callback = RecoveryGate()
            addTeardownBlock { await callback.release() }
            let a = try await fixture(reconcile: { _ in if fail && armed.on { throw POSIXError(.EIO) } })
            _ = await a.registerRevocationCoordinator(id: UUID(), recovery: { _ in try await callback.wait() })
            armed.on = true
            let requester = Task { try await a.retryReconciliation() }
            addTeardownBlock { requester.cancel(); await callback.release() }
            try await wait { await callback.hasEntered }
            let original = try await a.trustedRecoveryOutcome(), phases = await a.localRecoveryPhaseCount
            let departure = try await a.recoverDepartureLocal()
            let validated = await a.validateTrustedRecovery(original)
            XCTAssertEqual(departure.receipt?.attemptID, original.receipt?.attemptID)
            XCTAssertEqual(departure.completed, !fail); XCTAssertEqual(validated.completed, !fail)
            let after = await a.localRecoveryPhaseCount; XCTAssertEqual(after, phases)
            await callback.release()
            if fail {
                do { try await completed { try await requester.value }; XCTFail("Failed local outcome lost") }
                catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
            } else { try await completed { try await requester.value } }
        }
    }
    func testLocalOnlyCompletionDoesNotLeavePreparingApplicationBlocker() async throws {
        let a = try await fixture(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        let local = try await a.recoverDepartureLocal(); XCTAssertTrue(local.completed)
        try await authority.replay()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
        let observation = await authority.observation
        XCTAssertEqual(observation.obligations, 0); XCTAssertEqual(backend.writes, 1)
    }
    func testLocalOnlyCompletionPreservesIndependentApplicationFailure() async throws {
        let a = try await fixture(), intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        let backend = TrustedBackendFixture(try TrustedTVApprovals(revocations: [intent]).encoded()), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a, beforeReplay: { _ in throw POSIXError(.EIO) })))
        do { try await authority.replay(); XCTFail("Injected failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        let local = try await a.recoverDepartureLocal(); XCTAssertTrue(local.completed)
        do { try await authority.replay(); XCTFail("Unrelated failure was cleared") }
        catch { XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription)) }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        try await a.retryReconciliation()
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testCancelledLateOutcomeIsRecoveredByAnotherRequester() async throws {
        let a = try await fixture(), b = try await fixture(), requester = try await fixture()
        let gate = RecoveryOwnershipApplicationGate(), backend = TrustedBackendFixture(nil)
        addTeardownBlock { await gate.release() }
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) },
            beforeReplayApplication: { try await gate.call($0) })
        for target in [a, b, requester] { _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: target))) }
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        let first = Task { try await requester.retryReconciliation() }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await wait { await gate.serviceID != nil }
        let selected = await gate.serviceID
        let lateTarget = selected == a.runtimeID ? b : a
        let late = Task { try await lateTarget.retryReconciliation() }
        addTeardownBlock { late.cancel(); await gate.release() }
        try await wait { await authority.observation.successorParticipants == 1 }
        late.cancel()
        do { try await completed { try await late.value }; XCTFail("Cancelled successor succeeded") } catch is CancellationError {}
        try await wait { await authority.observation.successorParticipants == 0 }
        await gate.release()
        do { try await completed { try await first.value }; XCTFail("Old pass accepted the unadmitted outcome") } catch is TrustedPartialRecovery {}
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
        let phases = await lateTarget.localRecoveryPhaseCount
        try await requester.retryReconciliation()
        let after = await lateTarget.localRecoveryPhaseCount
        XCTAssertEqual(after, phases + 1)
        XCTAssertTrue(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations.isEmpty)
    }
    func testFreshRetryDoesNotAdoptUnownedDepartureFailure() async throws {
        let fault = RecoveryOwnershipSwitch()
        let service = try await fixture(reconcile: { _ in if fault.on { throw POSIXError(.EIO) } })
        fault.on = true
        let failed = try await service.recoverDepartureLocal()
        XCTAssertFalse(failed.completed)
        let phases = await service.localRecoveryPhaseCount
        fault.on = false
        try await service.retryReconciliation()
        let after = await service.localRecoveryPhaseCount
        XCTAssertEqual(after, phases + 1)
        let remaining = await service.recoveryStatuses()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testGenericTrustedFailureKeepsVerifiedLocalCompletion() async throws {
        let service = try await fixture()
        _ = await service.registerRevocationCoordinator(id: UUID(), recovery: { _ in throw POSIXError(.EIO) })
        do { try await service.retryReconciliation(); XCTFail("Injected coordinator error ignored") }
        catch let error as TrustedPartialRecovery {
            XCTAssertEqual(error.completedServices, [service.runtimeID])
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
        }
    }
    func testAbortedPassKeepsStoppingErrorAtDiagnosticCapacity() {
        let ticket = TrustedDepartureRecoveryKey(authority: UUID(), ticket: UUID())
        let prior = (1...12).map { "Prior failure \($0)" }
        let failure = TrustedPartialRecovery(completedServices: [], otherFailures: prior,
            attemptedDepartures: [ticket], abortedPasses: [.init(error: POSIXError(.EBUSY), evaluatedAttempts: [])])
        XCTAssertEqual(failure.remaining, [POSIXError(.EBUSY).localizedDescription] + Array(prior.prefix(8)))
        XCTAssertEqual(failure.attemptedDepartures, [ticket])
        XCTAssertFalse(failure.localizedDescription.contains("completed phases were committed"))
    }

    func testAbortedPassDoesNotCountAStaleOrExcludedLocalAttempt() async throws {
        for reviewed in [true, false] {
            let service = try await fixture()
            _ = await service.registerRevocationCoordinator(id: UUID(), recovery: { [weak service] local in
                let service = try XCTUnwrap(service)
                let receipt = try XCTUnwrap(local.receipt)
                XCTAssertTrue(local.completed)
                if !reviewed {
                    _ = await service.registerRevocationCoordinator(id: UUID(), {})
                    let validated = await service.validateTrustedRecovery(local)
                    XCTAssertFalse(validated.completed)
                }
                throw TrustedPartialRecovery(completedServices: [], otherFailures: [],
                    abortedPasses: [.init(error: POSIXError(.EBUSY), evaluatedAttempts: reviewed ? [receipt.attemptID] : [])])
            })
            do { try await service.retryReconciliation(); XCTFail("Aborted pass reported success") }
            catch let error as TrustedPartialRecovery {
                XCTAssertTrue(error.completedServices.isEmpty)
                XCTAssertEqual(error.remaining.first, POSIXError(.EBUSY).localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("completed phases were committed"))
            }
        }
    }

    func testAbortCountsOnlyAnUnevaluatedReplacementReceiptFromItsPass() async throws {
        for evaluated in [false, true] {
            let service = try await fixture()
            _ = await service.registerRevocationCoordinator(id: UUID(), recovery: { [weak service] local in
                let service = try XCTUnwrap(service), original = try XCTUnwrap(local.receipt)
                let authority = UUID(), pass = UUID()
                let registration = await service.registerRevocationCoordinator(id: authority, {})
                let binding = TrustedTargetInstallation(serviceID: service.runtimeID, authority: authority,
                    predecessorAuthority: authority, predecessorRegistration: registration)
                let fresh = try await service.recoverAfterTrustedBinding(pass: pass, installation: binding)
                let receipt = try XCTUnwrap(fresh.receipt)
                XCTAssertTrue(fresh.completed)
                XCTAssertNotEqual(original.attemptID, receipt.attemptID)
                await service.finishTrustedRecovery(pass: pass)
                throw TrustedPartialRecovery(completedServices: [], otherFailures: [],
                    abortedPasses: [.init(error: POSIXError(.EBUSY), evaluatedAttempts: evaluated ? [receipt.attemptID] : [],
                                          replacements: [original.attemptID: fresh])])
            })
            do { try await service.retryReconciliation(); XCTFail("Aborted pass reported success") }
            catch let error as TrustedPartialRecovery {
                XCTAssertEqual(error.completedServices, evaluated ? [] : [service.runtimeID])
                XCTAssertEqual(error.abortedPasses.count, 1)
            }
        }
    }

    func testOnlyCommittedDeparturesCountAsPartialProgress() {
        let ticket = TrustedDepartureRecoveryKey(authority: UUID(), ticket: UUID())
        let attempted = TrustedPartialRecovery(completedServices: [], otherFailures: ["Other recovery failed"],
            attemptedDepartures: [ticket])
        let committed = TrustedPartialRecovery(completedServices: [], otherFailures: ["Other recovery failed"],
            attemptedDepartures: [ticket], committedDepartures: [ticket])
        XCTAssertFalse(attempted.localizedDescription.contains("completed phases were committed"))
        XCTAssertTrue(committed.localizedDescription.contains("completed phases were committed"))
    }

    func testIndependentAbortKeepsItsErrorWithoutReversingRequesterExclusion() async throws {
        let service = try await fixture(), authority = UUID()
        let prior = (1...9).map { "Primary pass failure \($0)" }
        _ = await service.registerRevocationCoordinator(id: UUID(), recovery: { local in
            let receipt = try XCTUnwrap(local.receipt)
            throw TrustedPartialRecovery(completedServices: [], otherFailures: prior,
                abortedPasses: [.init(error: POSIXError(.EDEADLK), evaluatedAttempts: [receipt.attemptID])])
        })
        let registration = TrustedFailedRegistration(authority: authority, generation: 1, server: UUID(), lifetime: .init())
        let ticket = TrustedDepartureRecoveryKey(authority: authority, ticket: UUID())
        await service.rememberFailedRegistration(registration, error: POSIXError(.EIO)) { local in
            XCTAssertTrue(local.completed)
            throw TrustedPartialRecovery(completedServices: [], otherFailures: [],
                attemptedDepartures: [ticket], abortedPasses: [.init(error: POSIXError(.EBUSY), evaluatedAttempts: [])])
        }
        do { try await service.retryReconciliation(); XCTFail("Independent abort reported success") }
        catch let error as TrustedPartialRecovery {
            XCTAssertTrue(error.completedServices.isEmpty)
            XCTAssertEqual(error.remaining, [POSIXError(.EDEADLK).localizedDescription,
                                             POSIXError(.EBUSY).localizedDescription] + Array(prior.prefix(7)))
            XCTAssertEqual(error.abortedPasses.count, 2)
            XCTAssertEqual(error.attemptedDepartures, [ticket])
        }
    }
    func testFailedRequesterKeepsOtherVerifiedCompletions() async throws {
        let fault = RecoveryOwnershipSwitch()
        let a = try await fixture(reconcile: { _ in if fault.on { throw POSIXError(.EIO) } }), b = try await fixture()
        let backend = TrustedBackendFixture(nil), authority = backend.coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b, beforeReplay: { _ in throw POSIXError(.EIO) })))
        let intent = RequestRevocationIntent(operationID: UUID(), deviceID: "TV")
        try backend.write(TrustedTVApprovals(revocations: [intent]).encoded())
        do { try await b.retryReconciliation(); XCTFail("Injected replay failure ignored") } catch is TrustedPartialRecovery {}
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        fault.on = true
        do { try await a.retryReconciliation(); XCTFail("Local requester fault ignored") }
        catch let error as TrustedPartialRecovery {
            XCTAssertFalse(error.completedServices.contains(a.runtimeID))
            XCTAssertTrue(error.completedServices.contains(b.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
        }
        XCTAssertEqual(try TrustedTVApprovals.decode(XCTUnwrap(backend.read())).revocations, [intent])
    }
    func testCompatibilityRegistrationDoesNotRetainIdleService() async throws {
        for withOutcome in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/pr52-weak-service-" + UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            weak var retained: ShaderRequestService?
            do {
                let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
                    directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
                await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
                if withOutcome { _ = await service.registerRevocationCoordinator(id: UUID(), recovery: { _ in }) }
                else { _ = await service.registerRevocationCoordinator(id: UUID(), {}) }
                retained = service
            }
            try await wait { retained == nil }
        }
    }
    func testSuccessfulAuthoritySummarySurvivesRequesterLocalFailure() async throws {
        let fault = RecoveryOwnershipSwitch()
        let a = try await fixture(reconcile: { _ in if fault.on { throw POSIXError(.EIO) } }), b = try await fixture()
        let authority = TrustedBackendFixture(nil).coordinator()
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: a)))
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: b)))
        let other = try await b.recoverDepartureLocal(); XCTAssertTrue(other.completed)
        // A successful typed authority result can include another repaired target
        // even when the requester has no applicable cancellation obligation.
        _ = try await a.installRevocationCoordinator(authority: authority, recovery: { _ in
            let valid = await b.validateTrustedRecovery(other)
            return .init(completedServices: valid.completed ? [b.runtimeID] : [])
        })
        fault.on = true
        do { try await a.retryReconciliation(); XCTFail("Requester local failure was lost") }
        catch let error as TrustedPartialRecovery {
            XCTAssertEqual(error.completedServices, [b.runtimeID])
            XCTAssertTrue(error.remaining.joined().contains(POSIXError(.EIO).localizedDescription))
        }
    }
    func testCompatibilityHandoffAdapterDoesNotRetainIdleService() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/pr52-weak-handoff-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        weak var retained: ShaderRequestService?
        do {
            let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")),
                directory: root, workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
            await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
            let old = TrustedBackendFixture(nil).coordinator(), next = TrustedBackendFixture(nil).coordinator()
            _ = try await accept(old.register(TrustedOwnerRecorder().owner(service: service)))
            let proposed = try await service.prepareTrustedAuthority(id: next.id)
            let transfer = try XCTUnwrap(proposed)
            _ = try await service.installTrustedAuthority(transfer, id: next.id, intents: [],
                revision: .init(coordinator: next.id, sequence: 0), coordinator: { _ in }, authority: next)
            await service.finishTrustedAuthority(transfer, authority: next)
            retained = service
        }
        try await wait { retained == nil }
    }
    func testRequesterDoesNotReintroduceExcludedTrustedCompletion() async throws {
        let a = try await fixture()
        _ = await a.registerRevocationCoordinator(id: UUID(), recovery: { _ in
            throw TrustedPartialRecovery(completedServices: [], otherFailures: ["The requester epoch was superseded."])
        })
        do { try await a.retryReconciliation(); XCTFail("Partial result ignored") }
        catch let error as TrustedPartialRecovery {
            XCTAssertFalse(error.completedServices.contains(a.runtimeID))
            XCTAssertTrue(error.remaining.joined().contains("epoch was superseded"))
        }
    }

}
private actor RecoveryOwnershipApplicationGate {
    private(set) var serviceID: UUID?
    private let completion = TrustedCompletionSignal()
    func call(_ service: UUID) async throws {
        guard serviceID == nil else { return }
        serviceID = service; try await completion.wait()
    }
    func release() { completion.finish() }
}
@MainActor private final class RecoveryOwnershipCompletion<Value: Sendable> { var value: Result<Value, Error>? }
private final class RecoveryOwnershipSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
