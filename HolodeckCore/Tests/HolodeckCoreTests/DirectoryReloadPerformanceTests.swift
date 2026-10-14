#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
final class DirectoryReloadPerformanceTests: XCTestCase {
    func testUnchangedReloadServingLatency() async throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_PROFILE"] == "1" else {
            throw XCTSkip("Set HOLODECK_PROFILE=1 and use -c release to profile directory reloads.")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("authoring")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        for part in ["common", "fragment"] {
            try Data().write(to: root.appendingPathComponent("shared/\(part).metal"))
        }
        let ids = (0..<256).map { "scene-\($0)" }
        for id in ids {
            let folder = root.appendingPathComponent("shaders/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["id": id, "name": id, "category": "PROCEDURAL",
                "description": "Reload profile", "colors": [[0, 0, 0], [1, 1, 1]], "shared": ["common", "fragment"]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
            try Data("SOURCE \(id)".utf8).write(to: folder.appendingPathComponent("body.metal"))
        }
        try JSONSerialization.data(withJSONObject: ["shaders": ids, "defaultShaderID": ids[0]])
            .write(to: root.appendingPathComponent("index.json"))
        var png = try ShaderPNG.gradient(colors: [[0, 0, 0], [1, 1, 1]])
        png.append(Data(repeating: 0, count: max(0, 1_048_576 - png.count)))
        XCTAssertTrue(ShaderPNG.isValid(png))
        let preview = png
        let generator = ShaderPreviewGenerator(directory: base.appendingPathComponent("preview-cache")) { _ in preview }
        let store = DirectoryCatalog(directory: base.appendingPathComponent("publications"), previewGenerator: generator)
        _ = try await store.reload(from: root)
        let clock = ContinuousClock()
        var idle: [Double] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = try await store.get(.head, limit: 65_536)
            idle.append(Self.milliseconds(start.duration(to: clock.now)))
        }
        let samples = ReloadProfileSamples()
        let sampler = Task {
            while await samples.running {
                let start = clock.now
                _ = try await store.get(.head, limit: 65_536)
                await samples.record(Self.milliseconds(start.duration(to: clock.now)))
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampler.cancel() }
        var reloads: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            _ = try await store.reload(from: root)
            reloads.append(Self.milliseconds(start.duration(to: clock.now)))
        }
        let reloadLatencies = await samples.drain()
        var restorations: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            _ = try await store.cached()
            restorations.append(Self.milliseconds(start.duration(to: clock.now)))
        }
        await samples.stop()
        try await sampler.value
        let latencies = await samples.values
        XCTAssertFalse(latencies.isEmpty)
        print("Directory reload profile: 256 scenes, 1 MiB previews, 3 warm reloads; reload ms \(reloads); idle head p50/p95/max ms \(Self.percentiles(idle)); reload head p50/p95/max ms \(Self.percentiles(reloadLatencies)); disk restoration ms \(restorations); restoration head p50/p95/max ms \(Self.percentiles(latencies)); samples \(reloadLatencies.count)/\(latencies.count)")
        let storage = CatalogStorage.disk(at: base.appendingPathComponent("viewer"))
        _ = try await CatalogService(source: store.source, storage: storage).refresh()
        var coldLoads: [Double] = [], coldQueries: [Double] = []
        for _ in 0..<3 {
            let service = CatalogService(source: store.source, storage: storage, enabled: false)
            let start = clock.now
            let load = Task { await service.current() }
            await Task.yield()
            let queryStart = clock.now
            _ = await service.previewFailureCount
            coldQueries.append(Self.milliseconds(queryStart.duration(to: clock.now)))
            let restored = await load.value
            XCTAssertEqual(restored?.shaders.count, 256)
            coldLoads.append(Self.milliseconds(start.duration(to: clock.now)))
        }
        print("Viewer cold-load profile: load ms \(coldLoads); concurrent actor query ms \(coldQueries)")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private static func percentiles(_ values: [Double]) -> [Double] {
        let sorted = values.sorted()
        return [sorted[(sorted.count - 1) / 2], sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], sorted.last!]
    }
}

private actor ReloadProfileSamples {
    var running = true
    var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
    func stop() { running = false }
    func drain() -> [Double] { defer { values.removeAll() }; return values }
}
#endif
