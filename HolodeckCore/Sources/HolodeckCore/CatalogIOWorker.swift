import Foundation

/// Blocking catalog work is bounded to one job at a time per owner.
nonisolated final class CatalogIOWorker: Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try autoreleasepool(invoking: work)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
