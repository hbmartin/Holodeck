#if os(macOS)
import Foundation

struct TrustedDepartureInspectionPending: Error, Sendable {
    let departure: TrustedAuthorityDeparture
}
/// Bridges authority actors without holding either lane while inspection waits.
nonisolated final class TrustedAuthorityDeparture: @unchecked Sendable {
    let id: UUID
    let serviceID: UUID
    let registrationID: UUID
    struct Evidence: Equatable, Sendable {
        let baseline: UInt64
        let registration: UUID
        let obligations: Set<UUID>
    }
    private enum Phase { case preparing, ready(Evidence), activated, closed }
    private let lock = NSLock()
    private var phase = Phase.preparing
    private var inspections: Set<UUID> = []
    private var inspectionWaiters: [UUID: RequestPersistence.CommitTicket<Void>] = [:]
    init(id: UUID, serviceID: UUID, registrationID: UUID) {
        self.id = id; self.serviceID = serviceID; self.registrationID = registrationID
    }
    var inspectionWaiterCount: Int { lock.withLock { inspectionWaiters.count } }
    var activated: Bool { lock.withLock { if case .activated = phase { return true }; return false } }
    func invalidatePreparation() { lock.withLock { if case .ready = phase { phase = .preparing } } }
    func advanceBaseline(from previous: UInt64, to current: UInt64) {
        lock.withLock {
            if case .ready(let evidence) = phase, evidence.baseline == previous {
                phase = .ready(.init(baseline: current, registration: evidence.registration, obligations: evidence.obligations))
            }
        }
    }
    /// Admission and activation share the lock. An inspection begun before
    /// activation must settle before the binding can consume prepared evidence.
    func beginInspection() -> UUID? {
        lock.withLock {
            switch phase { case .activated, .closed: return nil; default: break }
            let permit = UUID(); inspections.insert(permit); return permit
        }
    }
    func finishInspection(_ permit: UUID, succeeded: Bool) {
        let waiters = lock.withLock { () -> [RequestPersistence.CommitTicket<Void>] in
            guard inspections.remove(permit) != nil else { return [] }
            if !succeeded, case .ready = phase { phase = .preparing }
            guard inspections.isEmpty else { return [] }
            let values = Array(inspectionWaiters.values); inspectionWaiters.removeAll(); return values
        }
        waiters.forEach { $0.complete(.success(())) }
    }
    func waitForInspection() async throws {
        let id = UUID(), receipt = RequestPersistence.CommitTicket<Void>()
        lock.withLock {
            if inspections.isEmpty { receipt.complete(.success(())) }
            else { inspectionWaiters[id] = receipt }
        }
        defer { lock.withLock { _ = inspectionWaiters.removeValue(forKey: id) } }
        try await receipt.value()
    }
    func prepared(_ evidence: Evidence) {
        lock.withLock { if case .preparing = phase, evidence.registration == registrationID, evidence.obligations.isEmpty { phase = .ready(evidence) } }
    }
    func validate(_ evidence: Evidence) {
        lock.withLock { if case .ready(let prepared) = phase, prepared != evidence { phase = .preparing } }
    }
    func activate<T>(_ change: () throws -> T) throws -> T {
        try lock.withLock {
            guard inspections.isEmpty else { throw TrustedDepartureInspectionPending(departure: self) }
            guard case .ready(let evidence) = phase, evidence.registration == registrationID, evidence.obligations.isEmpty else {
                throw ShaderRequestError.unavailable("Previous TV approval inspection changed during handoff. Retain the accepted authority and retry.")
            }
            let result = try change(); phase = .activated; return result
        }
    }
    func close() {
        let waiters = lock.withLock {
            phase = .closed; inspections.removeAll()
            let result = Array(inspectionWaiters.values); inspectionWaiters.removeAll(); return result
        }
        waiters.forEach { $0.complete(.success(())) }
    }
}
#endif
