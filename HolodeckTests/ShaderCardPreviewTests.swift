import XCTest
import UIKit
import Clocks
import ConcurrencyExtras
@testable import Holodeck
@testable import HolodeckCore

@MainActor
final class ShaderCardPreviewTests: XCTestCase {
    func testTransportCancellationDoesNotSuppressCurrentCellRecovery() async throws {
        for urlCancellation in [false, true] {
            let network = CellPreviewNetwork(cancels: true, urlCancellation: urlCancellation)
            let service = CatalogService(network: CatalogNetwork { _, _ in try await network.get() }, storage: .disabled)
            let cell = cell(service: service)
            defer { cell.prepareForReuse() }
            try await waitUntil { cell.previewTask == nil }
            XCTAssertNil(image(in: cell))
            let failures = await service.previewFailureCount
            XCTAssertEqual(failures, 0)
            await network.setResponse(try previewData())
            cell.configure(shader: TestCatalog.initialShader, active: false, loading: false, catalogService: service)
            try await waitUntil { cell.previewTask == nil }
            XCTAssertNotNil(image(in: cell))
            let attempts = await network.attempts
            XCTAssertEqual(attempts, 2)
        }
    }

    func testLayoutsKeepOneWaitingRequestAndTransientFailureRecovers() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            let network = CellPreviewNetwork()
            let service = CatalogService(network: CatalogNetwork { _, _ in try await network.get() }, storage: .disabled, clock: clock)
            let cell = cell(service: service)
            defer { cell.prepareForReuse() }
            try await waitUntil { await service.previewRetryWaiterCount == 1 }
            let id = cell.requestID
            XCTAssertNotNil(cell.previewTask)
            for _ in 0..<100 { cell.setNeedsLayout(); cell.layoutIfNeeded() }
            XCTAssertEqual(cell.requestID, id)
            await clock.advance(by: .seconds(29))
            let attempts = await network.attempts
            XCTAssertEqual(attempts, 1)
            await network.setResponse(try previewData())
            await clock.advance(by: .seconds(1))
            try await waitUntil { cell.previewTask == nil }
            let recoveredAttempts = await network.attempts
            XCTAssertEqual(recoveredAttempts, 2)
            XCTAssertEqual(cell.requestID, id)
            XCTAssertNotNil(image(in: cell))
        }
    }

    func testPermanentFailureIgnoresLayoutsButNewPublicationRetriesSameHash() async throws {
        let network = CellPreviewNetwork(response: Data("invalid".utf8))
        let service = CatalogService(network: CatalogNetwork { _, _ in try await network.get() }, storage: .disabled)
        let cell = cell(service: service)
        defer { cell.prepareForReuse() }
        try await waitUntil { cell.previewTask == nil }
        let id = cell.requestID
        for _ in 0..<100 { cell.setNeedsLayout(); cell.layoutIfNeeded() }
        XCTAssertEqual(cell.requestID, id)
        let attempts = await network.attempts
        XCTAssertEqual(attempts, 1)
        var shader = TestCatalog.initialShader
        let previous = try XCTUnwrap(shader.preview)
        shader.preview = ShaderPreview(path: previous.path, hash: previous.hash, publicationRevision: String(repeating: "c", count: 40))
        await network.setResponse(try previewData())
        cell.configure(shader: shader, active: false, loading: false, catalogService: service)
        try await waitUntil { cell.previewTask == nil }
        let newAttempts = await network.attempts
        XCTAssertEqual(newAttempts, 2)
        XCTAssertNotNil(image(in: cell))
    }

    func testServiceReplacementClearsTerminalFailure() async throws {
        let network = CellPreviewNetwork(response: Data("invalid".utf8))
        let old = CatalogService(network: CatalogNetwork { _, _ in try await network.get() }, storage: .disabled)
        let cell = cell(service: old)
        defer { cell.prepareForReuse() }
        try await waitUntil { cell.previewTask == nil }
        cell.configure(shader: TestCatalog.initialShader, active: false, loading: false,
                       catalogService: .offline(storage: TestCatalog.storage))
        try await waitUntil { cell.previewTask == nil }
        XCTAssertNotNil(image(in: cell))
    }

    func testReuseCancelsCooldownAndCannotInstallOldImage() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            let network = CellPreviewNetwork()
            let service = CatalogService(network: CatalogNetwork { _, _ in try await network.get() }, storage: .disabled, clock: clock)
            let cell = cell(service: service)
            try await waitUntil { await service.previewRetryWaiterCount == 1 }
            let waiting = try XCTUnwrap(cell.previewTask)
            cell.prepareForReuse()
            await waiting.value
            await network.setResponse(try previewData())
            await clock.advance(by: .seconds(300))
            let attempts = await network.attempts
            XCTAssertEqual(attempts, 1)
            XCTAssertNil(cell.previewTask)
            XCTAssertNil(image(in: cell))
        }
    }

    private func cell(service: CatalogService) -> ShaderCardCell {
        let cell = ShaderCardCell(frame: CGRect(x: 0, y: 0, width: 320, height: 232))
        cell.layoutIfNeeded()
        cell.configure(shader: TestCatalog.initialShader, active: false, loading: false, catalogService: service)
        return cell
    }

    private func image(in cell: ShaderCardCell) -> UIImage? {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    private func previewData() throws -> Data {
        try TestCatalog.preview(named: "preview-\(TestCatalog.initialShader.preview!.hash).png")
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Preview state timed out"); throw CellPreviewTestError.timedOut }
            await Task.yield()
        }
    }
}

private enum CellPreviewTestError: Error { case timedOut }

private actor CellPreviewNetwork {
    private var response: Data?
    private var cancels: Bool
    private let urlCancellation: Bool
    private(set) var attempts = 0
    init(response: Data? = nil, cancels: Bool = false, urlCancellation: Bool = false) {
        self.response = response
        self.cancels = cancels
        self.urlCancellation = urlCancellation
    }
    func setResponse(_ response: Data) { self.response = response; cancels = false }
    func get() throws -> Data {
        attempts += 1
        if cancels {
            if urlCancellation { throw URLError(.cancelled) }
            throw CancellationError()
        }
        guard let response else { throw CatalogError.invalidResponse }
        return response
    }
}
