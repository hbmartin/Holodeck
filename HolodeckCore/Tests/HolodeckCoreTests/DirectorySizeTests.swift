#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor
extension DirectoryCatalogTests {
    private func assertSizeReloadRejected(_ root: URL, store: DirectoryCatalog, path: String,
                                          fragments: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let cached = try await store.cached()
        let previous = try XCTUnwrap(cached, file: file, line: line)
        let shader = try XCTUnwrap(previous.shaders.first, file: file, line: line)
        let request = CatalogRequest.asset(revision: previous.publicationRevision, path: "sources/\(shader.id).metal")
        let bytes = try await store.get(request, limit: CatalogLimits.sourceBytes)
        do {
            _ = try await store.reload(from: root)
            XCTFail("Invalid authoring candidate installed", file: file, line: line)
        } catch LocalCatalogError.invalidFile(let actualPath, let reason) {
            XCTAssertEqual(actualPath, path, file: file, line: line)
            for fragment in fragments { XCTAssertTrue(reason.contains(fragment), reason, file: file, line: line) }
            XCTAssertFalse(reason.hasPrefix(path + ":"), reason, file: file, line: line)
        }
        let restored = try await store.cached()
        XCTAssertEqual(restored?.publicationRevision, previous.publicationRevision, file: file, line: line)
        let served = try await store.get(request, limit: CatalogLimits.sourceBytes)
        XCTAssertEqual(served, bytes, file: file, line: line)
        let directory = root.deletingLastPathComponent().appendingPathComponent("head")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("stage-") }, file: file, line: line)
    }

    func testAssembledSourceBoundaryIncludesSharedBytesAndPreservesPreviousPublication() async throws {
        let (root, store) = try fixture()
        let common = try Data(contentsOf: root.appendingPathComponent("shared/common.metal"))
        let fragment = try Data(contentsOf: root.appendingPathComponent("shared/fragment.metal"))
        let body = root.appendingPathComponent("shaders/plasma/body.metal")
        let bodySize = CatalogLimits.sourceBytes - common.count - fragment.count
        try Data(repeating: 0x20, count: bodySize).write(to: body)
        let accepted = try await store.reload(from: root).catalog
        XCTAssertEqual(accepted.shaders[0].source.utf8.count, CatalogLimits.sourceBytes)
        try Data(repeating: 0x20, count: bodySize + 1).write(to: body)
        try await assertSizeReloadRejected(root, store: store, path: "shaders/plasma/body.metal",
            fragments: ["Assembled source for plasma", "1048577 bytes", "limit is 1048576 bytes"])
    }

    func testOversizedSourceComponentsNameTheFileAndActualSize() async throws {
        for path in ["shared/common.metal", "shared/fragment.metal", "shaders/plasma/body.metal"] {
            let (root, store) = try fixture()
            _ = try await store.reload(from: root)
            try Data(repeating: 0x20, count: CatalogLimits.sourceBytes + 1).write(to: root.appendingPathComponent(path))
            try await assertSizeReloadRejected(root, store: store, path: path,
                fragments: ["File is 1048577 bytes", "limit is 1048576 bytes"])
        }
    }

    func testAuthoringJSONFileBoundariesDoNotDuplicateThePath() async throws {
        for path in ["index.json", "shaders/plasma/metadata.json"] {
            let (root, store) = try fixture()
            let url = root.appendingPathComponent(path)
            var bytes = try Data(contentsOf: url)
            bytes.append(Data(repeating: 0x20, count: CatalogLimits.manifestBytes - bytes.count))
            try bytes.write(to: url)
            _ = try await store.reload(from: root)
            bytes.append(0x20)
            try bytes.write(to: url)
            try await assertSizeReloadRejected(root, store: store, path: path,
                fragments: ["File is 2097153 bytes", "limit is 2097152 bytes"])
        }
    }

    private func writeSizeShader(_ id: String, root: URL, metadata: [String: Any], bodySize: Int) throws {
        let directory = root.appendingPathComponent("shaders/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var value = metadata; value["id"] = id
        try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("metadata.json"))
        try Data(repeating: 0x20, count: bodySize).write(to: directory.appendingPathComponent("body.metal"))
    }

    private func writeSizeIndex(_ ids: [String], root: URL) throws {
        try JSONSerialization.data(withJSONObject: ["shaders": ids, "defaultShaderID": ids[0]])
            .write(to: root.appendingPathComponent("index.json"))
    }

    func testAggregateSourceBoundaryCountsSharedBytesForEveryShader() async throws {
        let (root, store) = try fixture()
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("shaders/plasma/metadata.json"))) as? [String: Any])
        try Data([0x20]).write(to: root.appendingPathComponent("shared/common.metal"))
        try Data().write(to: root.appendingPathComponent("shared/fragment.metal"))
        let ids = (0..<16).map { "large-\($0)" }
        for id in ids { try writeSizeShader(id, root: root, metadata: metadata, bodySize: CatalogLimits.sourceBytes - 1) }
        try writeSizeIndex(ids, root: root)
        let accepted = try await store.reload(from: root).catalog
        XCTAssertEqual(accepted.shaders.reduce(0) { $0 + $1.source.utf8.count }, CatalogLimits.totalSourceBytes)
        try writeSizeShader("overflow", root: root, metadata: metadata, bodySize: 0)
        try writeSizeIndex(ids + ["overflow"], root: root)
        try await assertSizeReloadRejected(root, store: store, path: "index.json",
            fragments: ["Catalog source total after shader overflow", "16777217 bytes", "limit is 16777216 bytes"])
    }

    func testEmptyAndInvalidUTF8SourcesHaveSeparateDiagnostics() async throws {
        for invalidPath in ["shared/common.metal", "shared/fragment.metal", "shaders/plasma/body.metal", "empty"] {
            let (root, store) = try fixture()
            _ = try await store.reload(from: root)
            let reason: String
            if invalidPath == "empty" {
                for path in ["shared/common.metal", "shared/fragment.metal", "shaders/plasma/body.metal"] {
                    try Data().write(to: root.appendingPathComponent(path))
                }
                reason = "Assembled source for plasma is empty."
            } else {
                try Data([0xff]).write(to: root.appendingPathComponent(invalidPath))
                reason = "Assembled source for plasma is not valid UTF-8."
            }
            try await assertSizeReloadRejected(root, store: store, path: "shaders/plasma/body.metal", fragments: [reason])
        }
    }

    func testOversizedGeneratedManifestReportsBytesAndRetainsPreviousPublication() async throws {
        let (root, store) = try fixture()
        _ = try await store.reload(from: root)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("shaders/plasma/metadata.json"))) as? [String: Any])
        metadata["description"] = String(repeating: "x", count: 2000)
        metadata["discovery"] = ["tags": (0..<32).map { String(repeating: "x", count: 97) + String($0) },
                                 "moods": ["calm"], "motion": "slow"]
        let ids = (0..<500).map { "manifest-\($0)" }
        for id in ids { try writeSizeShader(id, root: root, metadata: metadata, bodySize: 1) }
        try writeSizeIndex(ids, root: root)
        try await assertSizeReloadRejected(root, store: store, path: "index.json",
            fragments: ["Catalog manifest is", "bytes; limit is 2097152 bytes"])
    }

    func testEncodedManifestAcceptsExactLimitAndRejectsOneMoreByte() throws {
        var manifest = TestCatalog.snapshot.manifest
        let original = manifest.shaders[0]
        manifest.shaders = (0..<500).map { number in
            var entry = original
            entry.id = "manifest-\(number)"; entry.sourcePath = "sources/\(entry.id).metal"
            entry.previewPath = "previews/\(entry.id).png"; entry.description = "a"
            entry.discovery = SceneDiscovery(tags: (0..<24).map { String(repeating: "x", count: 97) + String($0) },
                                             moods: ["calm"], motion: "slow")
            return entry
        }
        manifest.defaultShaderID = manifest.shaders[0].id; manifest.collections = nil
        let base = try CatalogPublication.encodedManifest(manifest).count
        var remaining = CatalogLimits.manifestBytes - base
        for index in manifest.shaders.indices {
            let padding = min(1999, remaining)
            manifest.shaders[index].description += String(repeating: "x", count: padding)
            remaining -= padding
        }
        XCTAssertEqual(remaining, 0)
        try manifest.validate()
        XCTAssertEqual(try CatalogPublication.encodedManifest(manifest).count, CatalogLimits.manifestBytes)
        manifest.shaders[499].description += "x"
        XCTAssertThrowsError(try CatalogPublication.encodedManifest(manifest)) { error in
            XCTAssertEqual(error.localizedDescription, "index.json: Catalog manifest is 2097153 bytes; limit is 2097152 bytes.")
        }
    }
}
#endif
