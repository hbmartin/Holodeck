import Foundation
import Clocks
import XCTest
@testable import HolodeckCore

@MainActor
enum CatalogTestFixtures {
    static func candidate(ninth: Bool = false) -> CatalogSnapshot {
        var snapshot = TestCatalog.snapshot
        snapshot.publicationRevision = String(repeating: "a", count: 40)
        if ninth {
            var entry = snapshot.manifest.shaders[0]
            entry.id = "ninth-shader"
            entry.name = "Ninth Shader"
            entry.sourcePath = "sources/ninth-shader.metal"
            entry.previewPath = "previews/ninth-shader.png"
            snapshot.manifest.shaders.append(entry)
            snapshot.sources[entry.id] = snapshot.sources["plasma"]
        }
        return snapshot
    }

    static func makeService(_ candidate: CatalogSnapshot, box: CatalogTestBox = CatalogTestBox(), cached: Bool = true) throws -> CatalogService {
        var responses: [String: Data] = [
            "/git/ref/heads/published": Data("{\"object\":{\"sha\":\"\(candidate.publicationRevision)\"}}".utf8),
            "/catalog.json": try JSONEncoder().encode(candidate.manifest)
        ]
        for entry in candidate.manifest.shaders {
            responses["/\(entry.sourcePath)"] = candidate.sources[entry.id].map { Data($0.utf8) }
        }
        box.setResponses(responses)
        let storage = CatalogStorage(read: { name in
            if let value = try box.storage.read(name) { return value }
            return cached && name == "snapshot.json" ? TestCatalog.data : nil
        }, write: box.storage.write)
        return CatalogService(network: box.network, storage: storage, clock: box.clock)
    }
}

nonisolated final class CatalogTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var responses: [String: Data] = [:]
    private var requests: [URL] = []
    private var reads: [String] = []
    private var writes: [String] = []
    private var readOnMain = false
    let clock = TestClock()
    private var failing = false
    var files: [String: Data] { lock.withLock { stored } }
    var responseFiles: [String: Data] { lock.withLock { responses } }
    var urls: [URL] { lock.withLock { requests } }
    var storageReads: [String] { lock.withLock { reads } }
    var storageWrites: [String] { lock.withLock { writes } }
    var storageReadOnMain: Bool { lock.withLock { readOnMain } }
    var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func setResponses(_ values: [String: Data]) { lock.withLock { responses = values } }
    var network: CatalogNetwork {
        CatalogNetwork { [self] url, _ in
            try lock.withLock {
                requests.append(url)
                let path = url.host == "raw.githubusercontent.com"
                    ? "/" + url.path.split(separator: "/").dropFirst(3).joined(separator: "/")
                    : url.path.replacingOccurrences(of: "/repos/hbmartin/HolodeckShaders", with: "")
                guard let response = responses[path] else { throw CatalogError.invalidResponse }
                return response
            }
        }
    }
    var storage: CatalogStorage {
        CatalogStorage(read: { [self] name in lock.withLock {
            reads.append(name)
            readOnMain = readOnMain || Thread.isMainThread
            return stored[name]
        } }, write: { [self] name, data in
            try lock.withLock {
                if failing { throw CatalogError.invalidResponse }
                stored[name] = data
                writes.append(name)
            }
        })
    }
}

actor RefreshGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    init(started: XCTestExpectation) { self.started = started }
    func hold() async {
        started.fulfill()
        guard !open else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}
