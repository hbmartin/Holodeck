import Foundation

actor RecoveryGate {
    private var open = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var hasEntered = false
    func wait() async throws {
        hasEntered = true
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if open { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        open = true; let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
}
