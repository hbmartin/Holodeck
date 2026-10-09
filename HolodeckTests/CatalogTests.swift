import XCTest
import Metal
import UIKit
@testable import Holodeck
@testable import HolodeckCore

@MainActor
final class CatalogTests: XCTestCase {
    func testReusedCardIgnoresLatePreviewCompletion() async throws {
        let gate = PreviewRequestGate()
        let service = CatalogService(
                                     network: CatalogNetwork { url, _ in await gate.image(url.lastPathComponent) },
                                     storage: TestCatalog.storage)
        var old = TestCatalog.shaders[0]
        var new = TestCatalog.shaders[1]
        func data(for shader: ShaderDefinition, suffix: String) throws -> Data {
            var bytes = try TestCatalog.preview(named: "preview-" + shader.preview!.hash + ".png")
            bytes.append(Data(suffix.utf8))
            return bytes
        }
        let oldData = try data(for: old, suffix: "old")
        let newData = try data(for: new, suffix: "new")
        let revision = TestCatalog.snapshot.publicationRevision
        old.preview = ShaderPreview(path: "previews/old.png", hash: CatalogHash.sha256(oldData), publicationRevision: revision)
        new.preview = ShaderPreview(path: "previews/new.png", hash: CatalogHash.sha256(newData), publicationRevision: revision)
        let cell = ShaderCardCell(frame: CGRect(x: 0, y: 0, width: 320, height: 232))
        cell.configure(shader: old, active: false, loading: false, catalogService: service)
        let oldTask = try XCTUnwrap(cell.previewTask)
        await gate.waitForRequest("old.png")
        cell.prepareForReuse()
        cell.configure(shader: new, active: false, loading: false, catalogService: service)
        let newTask = try XCTUnwrap(cell.previewTask)
        await gate.waitForRequest("new.png")
        await gate.complete("old.png", data: oldData)
        await oldTask.value
        let imageView = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertNil(imageView.image)
        await gate.complete("new.png", data: newData)
        await newTask.value
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.image?.pngData(), UIImage(data: newData)?.pngData())
        XCTAssertEqual(cell.accessibilityIdentifier, "shader-aurora")
    }

    func testCardReuseClearsPreviewAndShowsLocalizedDate() async throws {
        let service = CatalogService(storage: TestCatalog.storage, enabled: false)
        let cell = ShaderCardCell(frame: CGRect(x: 0, y: 0, width: 320, height: 232))
        let first = TestCatalog.shaders[0]
        cell.configure(shader: first, active: false, loading: false, catalogService: service)
        let image = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in image.image != nil }, object: nil)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertTrue(cell.accessibilityLabel?.contains("Updated " + first.updatedAt!.formatted(date: .abbreviated, time: .omitted)) == true)
        cell.prepareForReuse()
        XCTAssertNil(image.image)
        let missing = ShaderDefinition(id: "missing", title: "Missing", category: .procedural,
                                       description: "Unavailable preview", colors: first.colors, source: first.source,
                                       preview: ShaderPreview(path: "previews/missing.png", hash: String(repeating: "b", count: 64), publicationRevision: TestCatalog.snapshot.publicationRevision))
        cell.configure(shader: missing, active: false, loading: false, catalogService: service)
        XCTAssertNil(image.image)
        XCTAssertFalse(cell.accessibilityLabel?.contains("Updated") == true)
    }


}

private actor PreviewRequestGate {
    private var requests: [String: CheckedContinuation<Data, Never>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func image(_ path: String) async -> Data {
        await withCheckedContinuation { continuation in
            requests[path] = continuation
            observers.removeValue(forKey: path)?.resume()
        }
    }
    func waitForRequest(_ path: String) async {
        if requests[path] != nil { return }
        await withCheckedContinuation { observers[path] = $0 }
    }
    func complete(_ path: String, data: Data) {
        requests.removeValue(forKey: path)?.resume(returning: data)
    }
}
