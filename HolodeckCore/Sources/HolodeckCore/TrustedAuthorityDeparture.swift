#if os(macOS)
import Foundation

/// Bridges the two authority actors without holding either mutation lane across
/// the other's awaits. Only the service's synchronous binding switch admits it.
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
    init(id: UUID, serviceID: UUID, registrationID: UUID) {
        self.id = id; self.serviceID = serviceID; self.registrationID = registrationID
    }
    var activated: Bool { lock.withLock { if case .activated = phase { return true }; return false } }
    func invalidatePreparation() { lock.withLock { if case .ready = phase { phase = .preparing } } }
    func prepared(_ evidence: Evidence) {
        lock.withLock { if case .preparing = phase, evidence.registration == registrationID, evidence.obligations.isEmpty { phase = .ready(evidence) } }
    }
    func validate(_ evidence: Evidence) {
        lock.withLock { if case .ready(let prepared) = phase, prepared != evidence { phase = .preparing } }
    }
    func activate<T>(_ change: () throws -> T) throws -> T {
        try lock.withLock {
            guard case .ready(let evidence) = phase, evidence.registration == registrationID, evidence.obligations.isEmpty else {
                throw ShaderRequestError.unavailable("Previous TV approval inspection changed during handoff. Retain the accepted authority and retry.")
            }
            let result = try change()
            phase = .activated
            return result
        }
    }
    func close() { lock.withLock { phase = .closed } }
}
#endif
