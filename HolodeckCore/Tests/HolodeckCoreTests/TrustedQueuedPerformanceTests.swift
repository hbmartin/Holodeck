#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedQueuedPerformanceTests: XCTestCase {
    private func fixture() async throws -> (ShaderRequestService, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pr48-contention-" + UUID().uuidString)
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
            workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        addTeardownBlock { await service.suspend(); try? FileManager.default.removeItem(at: root) }
        return (service, root)
    }
    private func accept(_ receipt: TrustedApprovalsCoordinator.Registration) async throws -> TrustedApprovalsCoordinator.Binding {
        guard case .accepted(let binding) = try await receipt.value() else { throw ShaderRequestError.invalidRequest }
        return binding
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ShaderRequestError.unavailable("Contention backstop") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func testQueuedRevocationAdmissionHasLinearStructuralWork() async throws {
        let profiling = ProcessInfo.processInfo.environment["HOLODECK_TRUSTED_PROFILE"] == "1"
        let counts = profiling ? [50, 100, 200] : [4, 12]
        for count in counts { try await workload(count: count, cancelled: []) }
    }
    func testCancelledHeadAndMiddleDoNotWakeOrAdmitOtherWaitingClients() async throws {
        try await workload(count: 8, cancelled: [0, 3, 7])
    }
    private func workload(count: Int, cancelled: Set<Int>) async throws {
        let (moving, _) = try await fixture(), (remaining, _) = try await fixture()
        let bytes = try TrustedTVApprovals(approvals: (0..<count).map { ApprovedTV(id: "TV-\($0)", name: "TV", tokenHash: "token") }).encoded()
        let backend = TrustedBackendFixture(bytes), gate = RecoveryGate(), armed = QueuedWriteSwitch()
        let authority = TrustedApprovalsCoordinator(read: { try backend.checkedRead() }, write: { try backend.write($0) }, beforeTrustedWrite: {
            if armed.on { try await gate.wait() }
        })
        addTeardownBlock { await gate.release() }
        _ = try await accept(authority.register(TrustedOwnerRecorder().owner(service: moving)))
        let binding = try await accept(authority.register(TrustedOwnerRecorder().owner(service: remaining)))
        // Hold an admitted trusted write. A destination read is deliberately no
        // longer a queue gate: revocations must now preempt that preparation.
        armed.on = true
        let blocker = Task { try await authority.approve(binding.permit) {
            .init(record: .init(id: "TV-0", name: "TV", tokenHash: "token"), token: "token", eligibility: .init())
        } }
        addTeardownBlock { blocker.cancel(); await gate.release() }
        try await wait { await gate.hasEntered }
        let initial = await authority.observation, started = ProcessInfo.processInfo.systemUptime
        var tasks: [Task<Void, Error>] = []
        for index in 0..<count {
            tasks.append(Task { try await authority.revoke("TV-\(index)", permit: binding.permit) { _ in } })
            try await wait { await authority.observation.queuedRevocations == index + 1 }
        }
        let pendingTasks = tasks
        addTeardownBlock { pendingTasks.forEach { $0.cancel() }; await gate.release() }
        let reads = backend.reads
        for index in cancelled {
            tasks[index].cancel()
            do { try await tasks[index].value; XCTFail("Cancelled action ran") } catch is CancellationError {}
        }
        let queued = await authority.observation
        XCTAssertEqual(queued.queuedRevocations, count - cancelled.count)
        XCTAssertEqual(queued.admissionResumes, initial.admissionResumes)
        XCTAssertEqual(backend.writes, 0); XCTAssertEqual(queued.encodings, initial.encodings); XCTAssertEqual(backend.read(), bytes)
        let querying = ProcessInfo.processInfo.systemUptime
        for _ in 0..<32 {
            let status = try await remaining.control(operation: "requestStatus", payload: .init(), deviceID: "unrelated")
            XCTAssertTrue(status.enabled)
        }
        let responsiveness = ProcessInfo.processInfo.systemUptime - querying
        XCTAssertEqual(backend.reads, reads)
        let draining = ProcessInfo.processInfo.systemUptime
        armed.on = false; await gate.release(); _ = try await blocker.value
        let completed = QueuedCompletion()
        let drain = Task {
            do {
                for (index, task) in tasks.enumerated() where !cancelled.contains(index) { try await task.value }
                completed.finish(nil)
            } catch { completed.finish(error) }
        }
        addTeardownBlock { drain.cancel() }
        try await wait { completed.finished }; try completed.check()
        let final = await authority.observation, expected = count - cancelled.count
        XCTAssertEqual(backend.writes - 1, expected * 2); XCTAssertEqual(final.encodings - initial.encodings, expected * 2)
        XCTAssertEqual(final.queuedRevocations, 0); XCTAssertEqual(final.obligations, 0); XCTAssertEqual(final.departures, 0)
        XCTAssertEqual(final.targets, 2); XCTAssertEqual(final.recoverySubscriptions, 2)
        let resumes = final.admissionResumes - initial.admissionResumes
        let advances = final.admissionAdvances - initial.admissionAdvances
        // Each target contributes application/verification/finalization progress.
        XCTAssertLessThanOrEqual(resumes, count * (initial.targets * 3 + 2) + 20)
        XCTAssertLessThanOrEqual(advances, count * (initial.targets * 6 + 2) + 40)
        let stored = try TrustedTVApprovals.decode(XCTUnwrap(backend.read()))
        XCTAssertEqual(Set(stored.approvals.map(\.id)), Set(cancelled.map { "TV-\($0)" })); XCTAssertTrue(stored.revocations.isEmpty)
        print("QUEUED_PROFILE commands=\(count) cancelled=\(cancelled.count) reads=\(backend.reads) writes=\(backend.writes - 1) encodings=\(final.encodings - initial.encodings) resumes=\(resumes) advances=\(advances) queries=32 response=\(responsiveness) drain=\(ProcessInfo.processInfo.systemUptime - draining) elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
    }
}
@MainActor private final class QueuedCompletion {
    private(set) var finished = false
    private var error: Error?
    func finish(_ error: Error?) { self.error = error; finished = true }
    func check() throws { if let error { throw error } }
}
private final class QueuedWriteSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
#endif
