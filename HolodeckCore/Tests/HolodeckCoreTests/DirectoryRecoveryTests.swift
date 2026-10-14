#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
extension DirectoryCatalogTests {
    func testManifestSourceRevisionMustMatchMarkerBeforeRestoration() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let manifestURL = directory.appendingPathComponent(first.publicationRevision).appendingPathComponent("catalog.json")
        var manifest = first.snapshot.manifest; manifest.sourceRevision = String(repeating: "f", count: 64)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let restarted = DirectoryCatalog(directory: directory)
        do { _ = try await restarted.cached(); XCTFail("Incorrect manifest source revision restored") }
        catch CatalogError.invalidManifest {}
        do { _ = try await restarted.get(.head, limit: 65_536); XCTFail("Rejected publication became current") }
        catch CatalogError.invalidResponse {}
    }

    func testNormalizedManifestGrowthRejectsReloadAndPreservesPublication() async throws {
        let (root, store) = try fixture()
        let first = try await store.reload(from: root).catalog
        let base = root.deletingLastPathComponent(), directory = base.appendingPathComponent("head")
        let marker = try Data(contentsOf: directory.appendingPathComponent("current.json"))
        let ids = (0..<500).map { "scene-\($0)" }
        for id in ids {
            let folder = root.appendingPathComponent("shaders/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tags = (0..<14).map { "tag-\($0)-" + String(repeating: "İ", count: 90) }
            let metadata: [String: Any] = ["id": id, "name": "Shader", "category": "PROCEDURAL", "description": "Test",
                "colors": [[0, 0, 0], [1, 1, 1]], "shared": ["common", "fragment"],
                "discovery": ["tags": tags, "moods": ["calm"], "motion": "slow"]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
            try Data("BODY\n".utf8).write(to: folder.appendingPathComponent("body.metal"))
        }
        try JSONSerialization.data(withJSONObject: ["shaders": ids, "defaultShaderID": ids[0]])
            .write(to: root.appendingPathComponent("index.json"))
        let png = try ShaderPNG.gradient(colors: [[0, 0, 0], [1, 1, 1]])
        let generator = ShaderPreviewGenerator(directory: base.appendingPathComponent("size-previews")) { _ in png }
        let restarted = DirectoryCatalog(directory: directory, previewGenerator: generator)
        _ = try await restarted.cached()
        do { _ = try await restarted.reload(from: root); XCTFail("Final oversized manifest installed") }
        catch LocalCatalogError.invalidFile(let path, let reason) {
            XCTAssertEqual(path, "index.json"); XCTAssertTrue(reason.contains("2 MiB"))
        }
        let head = try JSONDecoder().decode(CatalogHead.self, from: await restarted.get(.head, limit: 65_536))
        XCTAssertEqual(head.revision, first.publicationRevision)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("current.json")), marker)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("stage-") })
    }

    func testVerificationServesCurrentAndRetainsCandidateUntilSuccessOrCancellation() async throws {
        for cancel in [false, true] {
            let (root, store) = try fixture()
            let original = try await store.reload(from: root).catalog, connection = UUID()
            await store.pin(original.publicationRevision, for: connection)
            let base = root.deletingLastPathComponent(), directory = base.appendingPathComponent("head")
            let other = base.appendingPathComponent("other")
            try FileManager.default.copyItem(at: root, to: other)
            var current = original
            for value in ["SECOND", "THIRD", "FOURTH"] {
                try Data(value.utf8).write(to: other.appendingPathComponent("shaders/plasma/body.metal"))
                current = try await store.reload(from: other).catalog
            }
            let gate = DirectoryVerificationGate()
            defer { gate.release() }
            var files = DirectoryCatalogFileOperations(); files.beforeVerification = { gate.hold() }
            let png = try ShaderPNG.gradient(colors: original.snapshot.manifest.shaders[0].colors)
            let generator = ShaderPreviewGenerator(directory: base.appendingPathComponent("worker-previews")) { _ in png }
            let restarted = DirectoryCatalog(directory: directory, files: files, previewGenerator: generator)
            _ = try await restarted.cached()
            let reload = Task { try await restarted.reload(from: root) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !gate.entered {
                guard ContinuousClock.now < deadline else { throw LocalCatalogError.timeout }
                await Task.yield()
            }
            await restarted.release(UUID()) // Trimming must not remove the unleased candidate.
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.publicationRevision).path))
            let head = try JSONDecoder().decode(CatalogHead.self, from: await restarted.get(.head, limit: 65_536))
            XCTAssertEqual(head.revision, current.publicationRevision)
            let served = try await restarted.get(.asset(revision: current.publicationRevision, path: "sources/plasma.metal"), limit: 1_048_576)
            XCTAssertEqual(String(decoding: served, as: UTF8.self), current.shaders[0].source)
            if cancel { reload.cancel() }
            gate.release()
            if cancel {
                do { _ = try await reload.value; XCTFail("Cancelled reload activated") } catch is CancellationError {}
                await restarted.release(UUID())
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.publicationRevision).path))
            } else {
                let restored = try await reload.value.catalog
                XCTAssertEqual(restored.publicationRevision, original.publicationRevision)
            }
            XCTAssertFalse(gate.timedOut)
        }
    }

    func testOrphanStagesAreReclaimedAndDeletionFailuresRetry() async throws {
        let (root, store) = try fixture(); let first = try await store.reload(from: root).catalog
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let orphan = directory.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
        let unrelated = directory.appendingPathComponent("stage-custom", isDirectory: true)
        for url in [orphan, unrelated] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("abandoned".utf8).write(to: orphan.appendingPathComponent("asset"))
        let removal = StageRemovalFailure()
        var files = DirectoryCatalogFileOperations(); files.removeStage = { try removal.remove($0) }
        let restarted = DirectoryCatalog(directory: directory, files: files)
        await restarted.maintainStages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        removal.allowRemoval()
        await restarted.maintainStages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.publicationRevision).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("preview-cache").path))
    }

    func testMaintenancePreservesActiveStageWhilePreviewGenerationWaits() async throws {
        let (root, _) = try fixture(), gate = DirectoryPreviewGate()
        let directory = root.deletingLastPathComponent().appendingPathComponent("active-publications")
        let png = try ShaderPNG.gradient(colors: [[0, 0, 0], [1, 1, 1]])
        let generator = ShaderPreviewGenerator(directory: directory.appendingPathComponent("preview-cache")) { _ in
            await gate.hold(); return png
        }
        let store = DirectoryCatalog(directory: directory, previewGenerator: generator)
        let reload = Task { try await store.reload(from: root) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { await gate.release(); throw LocalCatalogError.timeout }
            await Task.yield()
        }
        await store.maintainStages()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("stage-") })
        await gate.release(); _ = try await reload.value
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("stage-") })
    }
}

private final class DirectoryVerificationGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var holding = false, expired = false
    var entered: Bool { lock.withLock { holding } }
    var timedOut: Bool { lock.withLock { expired } }
    func hold() {
        lock.withLock { holding = true }
        if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
    }
    func release() { semaphore.signal() }
}
private final class StageRemovalFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true
    func allowRemoval() { lock.withLock { fails = false } }
    func remove(_ url: URL) throws {
        if lock.withLock({ fails }) { throw POSIXError(.EACCES) }
        try FileManager.default.removeItem(at: url)
    }
}
private actor DirectoryPreviewGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
