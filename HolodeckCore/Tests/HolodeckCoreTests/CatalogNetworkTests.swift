import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class CatalogNetworkTests: XCTestCase {
    private func network() -> CatalogNetwork {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        return .session(configuration: configuration)
    }

    private func stub(status: Int = 200, length: Int? = nil, chunks: [Data] = [],
                      started: XCTestExpectation? = nil, stopped: XCTestExpectation? = nil) -> URL {
        let url = URL(string: "https://catalog.test/" + UUID().uuidString)!
        CatalogProtocol.registry.set(url, response: .init(status: status, length: length, chunks: chunks,
                                                         started: started, stopped: stopped))
        addTeardownBlock { CatalogProtocol.registry.remove(url) }
        return url
    }

    func testChunksWithKnownAndUnknownLengthsAcceptExactLimit() async throws {
        let network = network()
        for length in [Int?.none, 8] {
            let url = stub(length: length, chunks: [Data(repeating: 1, count: 3), Data(repeating: 2, count: 5)])
            let result = try await network.get(url, 8)
            XCTAssertEqual(result, Data(repeating: 1, count: 3) + Data(repeating: 2, count: 5))
        }
        let empty = try await network.get(stub(length: 0), 0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testDeclaredAndStreamingOversizeAreRejected() async {
        let network = network()
        for url in [stub(length: 100), stub(chunks: [Data(repeating: 1, count: 4), Data(repeating: 2, count: 5)])] {
            do { _ = try await network.get(url, 8); XCTFail("Oversize must fail") }
            catch CatalogError.oversizedResponse {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testHTTPFailuresRejectBeforeAcceptingBody() async {
        let network = network()
        for status in [403, 404, 500] {
            do { _ = try await network.get(stub(status: status, chunks: [Data([1])]), 8); XCTFail("Bad status must fail") }
            catch CatalogError.invalidResponse {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationStopsRequestAndCompletesOnce() async {
        let started = expectation(description: "Request starts")
        let stopped = expectation(description: "Request is cancelled")
        let url = stub(started: started, stopped: stopped)
        let network = network()
        let task = Task { try await network.get(url, 8) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must fail") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testAlreadyCancelledRequestDoesNotStart() async {
        let started = expectation(description: "Cancelled request never starts")
        started.isInverted = true
        let url = stub(started: started)
        let network = network()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await network.get(url, 8)
        }
        do { _ = try await task.value; XCTFail("Cancelled task must fail") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [started], timeout: 0.1)
    }

    func testConcurrentCompletionsDoNotMixResponseData() async throws {
        let network = network()
        let cases = (0..<24).map { value in
            let bytes = Data(repeating: UInt8(value), count: 1024)
            return (stub(length: bytes.count, chunks: [bytes.prefix(300), bytes.dropFirst(300)]), bytes)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (url, expected) in cases {
                group.addTask {
                    let data = try await network.get(url, 1024)
                    XCTAssertEqual(data, expected)
                }
            }
            try await group.waitForAll()
        }
    }
}

nonisolated final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let length: Int?
        let chunks: [Data]
        let started: XCTestExpectation?
        let stopped: XCTestExpectation?
    }
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [URL: Response] = [:]
        func set(_ url: URL, response: Response) { lock.withLock { responses[url] = response } }
        func get(_ url: URL) -> Response? { lock.withLock { responses[url] } }
        func remove(_ url: URL) { _ = lock.withLock { responses.removeValue(forKey: url) } }
    }
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "catalog.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = Self.registry.get(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        response.started?.fulfill()
        // A held request lets cancellation happen before any response callback.
        guard response.started == nil else { return }
        let headers = response.length.map { ["Content-Length": String($0)] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let url = request.url { Self.registry.get(url)?.stopped?.fulfill() }
    }
}
