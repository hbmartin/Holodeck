#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

private actor PreviewTestRenderer {
    var sources: [String] = []
    var fails = false
    var hold = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(fails: Bool = false, hold: Bool = false) { self.fails = fails; self.hold = hold }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func render(_ source: String) async throws -> Data {
        sources.append(source)
        if hold { waiting = true; await withCheckedContinuation { continuation = $0 }; waiting = false }
        if fails { throw ShaderToolError("Test render failure") }
        return try ShaderPNG.gradient(colors: [[0, 0, 0], [1, 1, 1]])
    }
}

@MainActor
final class ShaderPreviewTests: XCTestCase {
    private let colors: [[Float]] = [[0, 0, 1], [1, 0, 0]]
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCacheReuseInvalidationCorruptionVersionAndPruning() async throws {
        let directory = temporary(), renderer = PreviewTestRenderer()
        let generator = ShaderPreviewGenerator(directory: directory, render: renderer.render)
        let first = try await generator.preview(source: "first", colors: colors)
        XCTAssertNil(first.diagnostic)
        let reused = try await generator.preview(source: "first", colors: colors.reversed())
        XCTAssertEqual(first.png, reused.png)
        let initial = await renderer.sources
        XCTAssertEqual(initial, ["first"])
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(first.cacheKey + ".png"))
        _ = try await generator.preview(source: "first", colors: colors)
        _ = try await generator.preview(source: "second", colors: colors)
        let changed = ShaderPreviewGenerator(directory: directory, rendererVersion: "2", render: renderer.render)
        let latest = try await changed.preview(source: "second", colors: colors)
        let rendered = await renderer.sources
        XCTAssertEqual(rendered, ["first", "first", "second", "second"])
        await changed.prune(keeping: [latest.cacheKey])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [latest.cacheKey + ".png", latest.cacheKey + ".sha256"])
    }
    func testFallbackRetriesRecoversAndReflectsMetadataColors() async throws {
        let directory = temporary(), renderer = PreviewTestRenderer()
        await renderer.configure(fails: true)
        let generator = ShaderPreviewGenerator(directory: directory, render: renderer.render)
        let first = try await generator.preview(source: "source", colors: colors)
        let changed = try await generator.preview(source: "source", colors: colors.reversed())
        XCTAssertTrue(ShaderPNG.isValid(first.png))
        XCTAssertEqual(first.diagnostic, "Test render failure")
        XCTAssertNotEqual(first.png, changed.png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await renderer.configure()
        let recovered = try await generator.preview(source: "source", colors: colors)
        XCTAssertNil(recovered.diagnostic)
        let rendered = await renderer.sources
        XCTAssertEqual(rendered.count, 3)
    }
    func testCacheStorageFailureIsNotHiddenByGradient() async throws {
        let directory = temporary(), renderer = PreviewTestRenderer()
        try Data("file".utf8).write(to: directory)
        let generator = ShaderPreviewGenerator(directory: directory, render: renderer.render)
        do { _ = try await generator.preview(source: "source", colors: colors); XCTFail("Storage error hidden") }
        catch { XCTAssertNotEqual(error.localizedDescription, "Test render failure") }
    }
    func testFolderReloadWarningsAndServingContinueWhileGenerationWaits() async throws {
        let base = temporary(), root = base.appendingPathComponent("authoring")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        let shader = root.appendingPathComponent("shaders/plasma")
        try FileManager.default.createDirectory(at: shader, withIntermediateDirectories: true)
        for part in ["common", "fragment"] { try Data().write(to: root.appendingPathComponent("shared/\(part).metal")) }
        let metadata: [String: Any] = ["id": "plasma", "name": "Plasma", "category": "PROCEDURAL", "description": "Test",
            "colors": colors, "shared": ["common", "fragment"]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: shader.appendingPathComponent("metadata.json"))
        try JSONSerialization.data(withJSONObject: ["shaders": ["plasma"], "defaultShaderID": "plasma"])
            .write(to: root.appendingPathComponent("index.json"))
        try Data("first".utf8).write(to: shader.appendingPathComponent("body.metal"))
        let renderer = PreviewTestRenderer()
        let generator = ShaderPreviewGenerator(directory: base.appendingPathComponent("cache"), render: renderer.render)
        let catalog = DirectoryCatalog(directory: base.appendingPathComponent("publications"), previewGenerator: generator)
        let initial = try await catalog.reload(from: root)
        XCTAssertTrue(initial.previewWarnings.isEmpty)
        await renderer.configure(fails: true, hold: true)
        try Data("second".utf8).write(to: shader.appendingPathComponent("body.metal"))
        let reload = Task { try await catalog.reload(from: root) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await renderer.waiting), ContinuousClock.now < deadline { await Task.yield() }
        let waiting = await renderer.waiting
        XCTAssertTrue(waiting)
        let head = try JSONDecoder().decode(CatalogHead.self, from: await catalog.get(.head, limit: 65_536))
        XCTAssertEqual(head.revision, initial.catalog.publicationRevision)
        let another = Task { try await catalog.reload(from: root) }
        await renderer.release()
        let fallback = try await reload.value
        XCTAssertEqual(fallback.previewWarnings.map(\.shaderID), ["plasma"])
        let serialized = try await another.value
        XCTAssertEqual(serialized.catalog.publicationRevision, fallback.catalog.publicationRevision)
        await renderer.configure()
        let recovery = try await catalog.reload(from: root)
        XCTAssertTrue(recovery.previewWarnings.isEmpty)
        XCTAssertNotEqual(recovery.catalog.publicationRevision, fallback.catalog.publicationRevision)
    }
}
#endif
