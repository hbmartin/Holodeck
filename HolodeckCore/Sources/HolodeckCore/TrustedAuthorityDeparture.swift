#if os(macOS)
import Foundation

/// Bridges the two authority actors without holding either mutation lane across
/// the other's awaits. Only the service's synchronous binding switch admits it.
nonisolated final class TrustedAuthorityDeparture: @unchecked Sendable {
    let id: UUID
    let serviceID: UUID
    let registrationID: UUID
    private enum Phase { case preparing, ready, activated, closed }
    private let lock = NSLock()
    private var phase = Phase.preparing
    init(id: UUID, serviceID: UUID, registrationID: UUID) {
        self.id = id; self.serviceID = serviceID; self.registrationID = registrationID
    }
    var activated: Bool { lock.withLock { phase == .activated } }
    func invalidatePreparation() { lock.withLock { if phase == .ready { phase = .preparing } } }
    func prepared() { lock.withLock { if phase == .preparing { phase = .ready } } }
    func activate<T>(_ change: () throws -> T) throws -> T {
        try lock.withLock {
            guard phase == .ready else {
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
