import Foundation

/// One reusable session with bounded chunk accumulation. All mutable request state is locked.
nonisolated final class CatalogDownloader: @unchecked Sendable {
    private final class Pending {
        let limit: Int
        let continuation: CheckedContinuation<Data, Error>
        var data = Data()
        init(limit: Int, continuation: CheckedContinuation<Data, Error>) {
            self.limit = limit; self.continuation = continuation
        }
    }
    private let lock = NSLock()
    private var requests: [Int: Pending] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        let delegate = Delegate()
        delegate.owner = self
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func get(_ url: URL, limit: Int) async throws -> Data {
        guard limit >= 0 else { throw CatalogError.oversizedResponse }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.setValue("Holodeck", forHTTPHeaderField: "User-Agent")
                if url.host == "api.github.com" {
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                }
                let task = session.dataTask(with: request)
                lock.withLock { requests[task.taskIdentifier] = Pending(limit: limit, continuation: continuation) }
                let cancel: @Sendable () -> Void = { [self] in
                    task.cancel()
                    finish(task.taskIdentifier, result: .failure(CancellationError()))
                }
                if cancellation.install(cancel) { task.resume() } else { cancel() }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        let pending = lock.withLock { requests.removeValue(forKey: id) }
        pending?.continuation.resume(with: result)
    }

    private func receive(_ response: URLResponse, task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            finish(task.taskIdentifier, result: .failure(CatalogError.invalidResponse))
            return .cancel
        }
        let limit = lock.withLock { requests[task.taskIdentifier]?.limit }
        guard let limit else { return .cancel }
        if response.expectedContentLength > Int64(limit) {
            finish(task.taskIdentifier, result: .failure(CatalogError.oversizedResponse))
            return .cancel
        }
        return .allow
    }

    private func receive(_ data: Data, task: URLSessionDataTask) {
        let overflow = lock.withLock {
            guard let pending = requests[task.taskIdentifier] else { return false }
            guard data.count <= pending.limit - pending.data.count else { return true }
            pending.data.append(data)
            return false
        }
        if overflow {
            finish(task.taskIdentifier, result: .failure(CatalogError.oversizedResponse))
            task.cancel()
        }
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        // Removal and completion happen together, so cancellation cannot resume this twice.
        let pending = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
        guard let pending else { return }
        if let error { pending.continuation.resume(throwing: error) }
        else { pending.continuation.resume(returning: pending.data) }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: CatalogDownloader?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            completionHandler(owner?.receive(response, task: dataTask) ?? .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.receive(data, task: dataTask)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.complete(task, error: error)
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var action: (@Sendable () -> Void)?
        func install(_ action: @escaping @Sendable () -> Void) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.action = action
                return true
            }
        }
        func cancel() {
            let action = lock.withLock {
                cancelled = true
                defer { self.action = nil }
                return self.action
            }
            action?()
        }
    }
}
