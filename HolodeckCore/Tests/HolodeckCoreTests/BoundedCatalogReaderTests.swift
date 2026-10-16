#if os(macOS)
import Foundation
import Darwin
import XCTest
@testable import HolodeckCore

@MainActor final class BoundedCatalogReaderTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testBoundsAreEnforcedBeforeAndDuringRead() throws {
        let root = try folder(), file = root.appendingPathComponent("source")
        try Data(repeating: 1, count: 32).write(to: file)
        let reader = try BoundedCatalogReader(root: root)
        XCTAssertEqual(try reader.read("source", limit: 32).bytes.count, 32)
        XCTAssertThrowsError(try reader.read("source", limit: 31)) { XCTAssertTrue($0.localizedDescription.contains("32 bytes; limit is 31")) }
        XCTAssertThrowsError(try reader.read("source", limit: 32, afterMetadata: {
            // Grow the existing inode after fstat, without replacing the descriptor.
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 2, count: 100_000)); try handle.close()
        })) { XCTAssertTrue($0.localizedDescription.contains("33 bytes; limit is 32")) }
    }
    func testRejectsRootIntermediateFinalLinksAndSpecialFiles() async throws {
        let root = try folder(), outside = try folder()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("body"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("body"), withDestinationURL: outside.appendingPathComponent("body"))
        let reader = try BoundedCatalogReader(root: root)
        XCTAssertEqual(try BoundedCatalogReader(root: root.appendingPathComponent("linked")).read("body", limit: 100).bytes, Data("outside".utf8))
        XCTAssertThrowsError(try reader.read("linked/body", limit: 100))
        XCTAssertThrowsError(try reader.read("body", limit: 100))
        XCTAssertThrowsError(try reader.read("../body", limit: 100))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let done = expectation(description: "FIFO is rejected without waiting for a writer")
        DispatchQueue.global().async {
            do { _ = try BoundedCatalogReader(root: root).read("fifo", limit: 100); XCTFail("FIFO accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("regular file")) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }
    func testReadUsesOpenedFileWhenPathIsReplaced() throws {
        let root = try folder(), outside = try folder(), path = root.appendingPathComponent("body")
        try Data("approved".utf8).write(to: path)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("body"))
        let bytes = try BoundedCatalogReader(root: root).read("body", limit: 100, afterMetadata: {
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside.appendingPathComponent("body"))
        }).bytes
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "approved")
    }
}
#endif

#if os(macOS)
@MainActor extension DirectoryCatalogTests {
    func testFailedColdRestorationCannotTrimDurableMarkerRevision() async throws {
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let publication = directory.appendingPathComponent(catalog.publicationRevision)
        let source = publication.appendingPathComponent("sources/plasma.metal")
        let original = try Data(contentsOf: source)
        try Data("corrupted".utf8).write(to: source)
        let cold = DirectoryCatalog(directory: directory)
        do { _ = try await cold.cached(); XCTFail("Corrupt publication restored") } catch CatalogError.invalidSource {}
        await cold.release(UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.path))
        try original.write(to: source)
        let restored = try await cold.cached()
        XCTAssertEqual(restored?.publicationRevision, catalog.publicationRevision)
    }
    func testCancelledColdRestorationKeepsMarkerAndCopiedAssets() async throws {
        let (root, store) = try fixture()
        let catalog = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let gate = ColdRestorationGate()
        var files = DirectoryCatalogFileOperations(); files.beforeVerification = { gate.hold() }
        let cold = DirectoryCatalog(directory: directory, files: files)
        let task = Task { try await cold.cached() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.entered {
            guard ContinuousClock.now < deadline else { gate.release(); throw LocalCatalogError.timeout }
            await Task.yield()
        }
        task.cancel(); gate.release()
        do { _ = try await task.value; XCTFail("Cancelled restoration activated") } catch is CancellationError {}
        await cold.release(UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(catalog.publicationRevision).path))
        let head = try JSONDecoder().decode(CatalogHead.self, from: Data(contentsOf: directory.appendingPathComponent("current.json")))
        XCTAssertEqual(head.revision, catalog.publicationRevision)
    }
    func testServingRejectsIntermediatePublicationSymlink() async throws {
        let (root, store) = try fixture(), result = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let sources = directory.appendingPathComponent(result.publicationRevision).appendingPathComponent("sources")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-sources")
        try FileManager.default.moveItem(at: sources, to: outside)
        try FileManager.default.createSymbolicLink(at: sources, withDestinationURL: outside)
        do { _ = try await store.get(.asset(revision: result.publicationRevision, path: "sources/plasma.metal"), limit: CatalogLimits.sourceBytes); XCTFail("Intermediate link followed") }
        catch LocalCatalogError.invalidFile {}
    }
}
private nonisolated final class ColdRestorationGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var holding = false
    var entered: Bool { lock.withLock { holding } }
    func hold() { lock.withLock { holding = true }; _ = semaphore.wait(timeout: .now() + 3) }
    func release() { semaphore.signal() }
}
#endif
