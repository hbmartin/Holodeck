#if os(macOS)
import Foundation

/// A local host owns dispatch eligibility; releasing it never cancels an admitted execution.
nonisolated public final class RequestServiceOwnerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable () -> Void)?
    init(_ finish: @escaping @Sendable () -> Void) { self.finish = finish }
    public func release() {
        let action = lock.withLock { let value = finish; finish = nil; return value }
        action?()
    }
    deinit { release() }
}
nonisolated final class RequestServiceOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var managed = false
    private var leases: Set<UUID> = []
    var mayDispatch: Bool { lock.withLock { !managed || !leases.isEmpty } }
    func acquire() -> UUID { lock.withLock { managed = true; let id = UUID(); leases.insert(id); return id } }
    func release(_ id: UUID) { lock.withLock { _ = leases.remove(id) } }
}
nonisolated final class WeakRequestService: @unchecked Sendable {
    weak var value: ShaderRequestService?
    init(_ value: ShaderRequestService?) { self.value = value }
}

nonisolated final class TrustedApprovalEligibility: @unchecked Sendable {
    private enum State { case eligible, admitted, closed }
    private let lock = NSLock()
    private var state: State = .eligible
    private let withinDeadline: @Sendable () -> Bool
    init(withinDeadline: @escaping @Sendable () -> Bool = { true }) { self.withinDeadline = withinDeadline }
    func check() throws {
        try lock.withLock {
            guard state == .eligible, withinDeadline() else { throw LocalCatalogError.disconnected }
        }
    }
    func beginWrite() throws {
        try lock.withLock {
            guard state == .eligible, withinDeadline() else { throw LocalCatalogError.disconnected }
            state = .admitted
        }
    }
    var canIssue: Bool { lock.withLock { state == .admitted && withinDeadline() } }
    func close() { lock.withLock { state = .closed } }
}
nonisolated struct CommittedApprovalDeliveryError: LocalizedError, Sendable {
    var errorDescription: String? { "The TV approval was saved, but its pairing connection closed before the token could be issued. Pair this TV again; the saved approval has not been rolled back." }
}
/// Live servers share an authority by the actual Keychain service/account pair.
/// Weak entries do not own idle hosts. Only unresolved evidence receives a strong pin.
nonisolated final class TrustedAuthorityRegistry: @unchecked Sendable {
    static let shared = TrustedAuthorityRegistry()
    private struct Key: Hashable { let service: String; let account: String }
    private final class Entry {
        weak var value: TrustedApprovalsCoordinator?
        var evidence: TrustedApprovalsCoordinator?
        init(_ value: TrustedApprovalsCoordinator) { self.value = value }
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    func authority(account: String) -> TrustedApprovalsCoordinator {
        lock.withLock {
            entries = entries.filter { $0.value.value != nil }
            let key = Key(service: LocalSecrets.service, account: account)
            if let value = entries[key]?.value { return value }
            let value = TrustedApprovalsCoordinator(read: { try LocalSecrets.read(account) }, write: { try LocalSecrets.write($0, account: account) },
                retainEvidence: { [weak self] value, retain in self?.retain(value, for: key, evidence: retain) })
            entries[key] = Entry(value); return value
        }
    }
    private func retain(_ value: TrustedApprovalsCoordinator, for key: Key, evidence: Bool) {
        lock.withLock {
            guard entries[key]?.value === value else { return }
            entries[key]?.evidence = evidence ? value : nil
        }
    }
    var count: Int { lock.withLock { entries = entries.filter { $0.value.value != nil }; return entries.count } }
}
#endif
